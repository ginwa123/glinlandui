// glinlandui browser shim — the browser-side peer of `mac/shim.m`, and the ONLY
// JavaScript in this project.
//
// ## This file makes no decisions
//
// Every translation lives in pure Zig, in `src/web/`, and every one of those
// modules is in the cross-platform test suite:
//
//     KeyboardEvent.code  -> evdev        src/web/keymap.zig
//     MouseEvent.button   -> evdev        src/web/input.zig
//     deltaMode + deltas  -> px scroll    src/web/adapter.zig
//     CSS px              -> backing px   src/web/present.zig
//     resize storms       -> one resize   src/web/adapter.zig
//     RGBA8 -> ImageData                  src/web/present.zig  (the identity)
//
// That is the same division of labour `mac/shim.m` has, and it is the whole
// reason the shim is short: anything that could be got subtly wrong — a swapped
// red and blue, a mirrored y axis, a dropped keycode — is on the other side of
// the boundary, where a test can reach it. `src/web/shim.h` is the contract; this
// file only calls it.
//
// ## The two things this file DOES own
//
// 1. **`memory.grow()` detaches views.** A `TypedArray` over wasm memory becomes
//    unusable (zero-length) after any allocation that grows the heap, and a
//    frame can grow the heap at any moment — a Clay arena resize, a glyph
//    bitmap. So the surface view is rebuilt whenever the memory BUFFER IDENTITY
//    or the surface POINTER changes, and never cached on the assumption that it
//    will not. Getting this wrong produces a UI that renders fine and then
//    presents as blank, intermittently.
//
// 2. **`requestAnimationFrame`.** The toolkit cannot own an event loop in a
//    browser, so this file runs the loop and asks `glin_web_needs_frame()` first.
//    An idle UI therefore costs one integer read per animation frame: no layout,
//    no rasterization, no pixel copy.
//
// ## Not a module graph, not a bundler
//
// Plain ES module, no imports, no build step. `zig build web` produces
// `zig-out/web/` and that directory is the whole application.

const WASM_URL = "glinlandui.wasm";
const WASM_URL_CALCULATOR = "glinlandui-calculator.wasm";

/**
 * Which application to load.
 *
 * `?app=calculator` loads the calculator; anything else loads the demo. Both are
 * separate wasm modules built from separate entry points (`src/web_main.zig` and
 * `src/web_calculator_main.zig`), sharing this page, this shim and the library —
 * which is exactly the relationship the two native executables have.
 *
 * The choice is a URL parameter rather than a second HTML file because the page
 * is identical: one canvas, one status line, one set of event handlers. A second
 * file would be a copy that drifts.
 */
const APP = new URLSearchParams(location.search).get("app") ?? "demo";
const WASM_FILE = APP === "calculator" ? WASM_URL_CALCULATOR : WASM_URL;

// Mirrors `present.max_device_scale`. Clamped here as well as in Zig so the
// canvas element is never sized absurdly to begin with; the Zig side is the
// authority and `toBackingPoint` uses the same ceiling.
const MAX_DEVICE_SCALE = 4;

const statusEl = document.getElementById("status");
const canvas = document.getElementById("canvas");

/** @param {string} message */
function log(message) {
  if (statusEl) statusEl.textContent = message;
}

/** @param {string} message @param {unknown} [cause] */
function fail(message, cause) {
  if (statusEl) {
    statusEl.innerHTML = "";
    const p = document.createElement("p");
    p.className = "error";
    p.textContent = message;
    statusEl.appendChild(p);
  }
  console.error("glinlandui:", message, cause ?? "");
}

/** The DOM's device pixel ratio, clamped to the toolkit's ceiling. */
function deviceScale() {
  const raw = window.devicePixelRatio || 1;
  if (!Number.isFinite(raw) || raw <= 0) return 1;
  return Math.min(raw, MAX_DEVICE_SCALE);
}

/**
 * The canvas's backing-store size: its CSS box scaled by the device ratio.
 *
 * Rounded up, because a fractional ratio (1.25, 1.5) otherwise leaves the canvas
 * a fraction short and shows a stripe of page background down two edges. The Zig
 * side has the same rounding in `present.canvasSize`, which is the one the tests
 * pin; this is the same arithmetic on the other side of the boundary.
 */
function backingSize() {
  const rect = canvas.getBoundingClientRect();
  const scale = deviceScale();
  return {
    w: Math.max(1, Math.ceil(rect.width * scale)),
    h: Math.max(1, Math.ceil(rect.height * scale)),
  };
}

async function main() {
  if (!canvas) throw new Error("no #canvas element in the page");
  const ctx = canvas.getContext("2d", { alpha: false });
  if (!ctx) throw new Error("canvas.getContext('2d') returned null");

  // ---- load ----
  //
  // Fetch once, compile, inspect, instantiate. Fetching the bytes up front (and
  // not using `instantiateStreaming`) buys two things that matter more than the
  // streaming optimisation on a ~1 MB module: an explicit `application/wasm`
  // MIME requirement is avoided, so `zig build serve` works on whatever python3
  // is installed, and the import section can be checked BEFORE instantiation, so
  // a hole in `src/web/compat/` is reported as a named symbol rather than as an
  // opaque `LinkError`.
  let instance;
  let module;
  try {
    const response = await fetch(WASM_FILE);
    if (!response.ok) throw new Error(`GET ${WASM_FILE} -> ${response.status} ${response.statusText}`);
    module = await WebAssembly.compile(await response.arrayBuffer());
  } catch (err) {
    fail(
      `Could not load ${WASM_FILE}. It must be served over http(s) — a file:// page cannot fetch a module.`,
      err,
    );
    return;
  }

  // THE structural assertion. This module is built for `wasm32-freestanding`, so
  // it should need NOTHING from its host: no libc, no WASI, no environment. A
  // non-empty import section means the compat layer in `src/web/compat/` has a
  // hole, and the fix is to add the symbol there — not to stub an import here.
  const imports = WebAssembly.Module.imports(module);
  if (imports.length !== 0) {
    fail(
      `expected a dependency-free module, but it imports ${imports.length}: ` +
        imports.map((i) => `${i.module}.${i.name}`).join(", "),
    );
    return;
  }

  try {
    instance = await WebAssembly.instantiate(module, {});
  } catch (err) {
    fail("the module failed to instantiate", err);
    return;
  }

  const exports = instance.exports;
  const memory = exports.memory;
  if (!(memory instanceof WebAssembly.Memory)) {
    fail("the module does not export its memory, so the canvas cannot be filled");
    return;
  }

  // ---- create ----
  const first = backingSize();
  canvas.width = first.w;
  canvas.height = first.h;
  if (exports.glin_web_init(first.w, first.h, 240, 180) !== 1) {
    fail("glin_web_init failed (already initialised, or out of memory)");
    return;
  }
  if (exports.glin_web_run() !== 1) {
    fail("glin_web_run failed (no delegate, or init did not complete)");
    return;
  }

  // ---- present ----
  let cachedBuffer = null;
  let surfaceView = null;
  let surfaceImage = null;
  let surfaceKey = "";

  function blit() {
    const ptr = exports.glin_web_surface_ptr();
    const len = exports.glin_web_surface_len();
    const w = exports.glin_web_surface_width();
    const h = exports.glin_web_surface_height();
    if (ptr === 0 || len === 0 || w === 0 || h === 0) return;

    // Rebuild the view when EITHER the memory buffer or the surface pointer
    // changed. Buffer identity alone is not enough: the renderer may resize the
    // surface in place (reallocating its pixels at a new address) without the
    // heap having grown. See the note at the top of this file.
    const buffer = memory.buffer;
    const key = `${ptr}:${w}x${h}`;
    if (buffer !== cachedBuffer || surfaceKey !== key || surfaceImage === null) {
      cachedBuffer = buffer;
      surfaceKey = key;
      surfaceView = new Uint8ClampedArray(buffer, ptr, len);
      // `new ImageData(view, w, h)` WRAPS the array, it does not copy it, so the
      // frame stays in wasm memory and no bytes move per frame. The layout is
      // already right: RGBA8, row 0 = top, straight alpha — the same finding
      // `mac/present.zig` measured for CoreGraphics, and here it is not even a
      // `putImageData` transform, it is the identity.
      surfaceImage = new ImageData(surfaceView, w, h);
      if (canvas.width !== w || canvas.height !== h) {
        canvas.width = w;
        canvas.height = h;
      }
    }
    ctx.putImageData(surfaceImage, 0, 0);
  }

  // ---- size ----
  function pushSize() {
    const { w, h } = backingSize();
    exports.glin_web_resize(w, h);
    exports.glin_web_scale(deviceScale());
  }
  new ResizeObserver(pushSize).observe(canvas);
  window.addEventListener("resize", pushSize);

  // ---- input ----
  //
  // Every handler is a one-line call. `offsetX`/`offsetY` are CSS pixels relative
  // to the canvas's padding box, and the canvas has no padding (see style.css),
  // so multiplying by the device scale lands in backing-store pixels — the space
  // the toolkit lays out and hit-tests in. There is no y flip: the DOM's origin
  // is already the top-left corner that Clay uses.
  //
  // ## Why every handler DRAWS instead of just marking the frame dirty
  //
  // The first version of this only set the dirty flag and let the rAF loop pick it
  // up. That is correct but slow, and measurably so:
  //
  //   - the redraw waits for the next `requestAnimationFrame` — up to 16.7 ms at
  //     60 Hz, and the browser may schedule it later still;
  //   - a click fires on RELEASE (`components/dispatch.zig` records the press but
  //     "fires NOTHING"), so a toggle costs TWO rAF hops — up to ~33 ms;
  //   - and the whole 2.7 MB surface is re-blitted inside that callback.
  //
  // An input event IS a reason to draw, so the handler draws. The rAF loop stays
  // as the safety net for anything that does not come from an event (a coalesced
  // resize, a timer-driven app), and `needs_frame` still gates it, so an idle tab
  // still costs one integer read per animation frame.
  //
  // `drawNow` is idempotent: if the rAF loop already drew this frame, the flag is
  // clear and it does nothing. So the two paths cannot double-draw.
  function drawNow() {
    if (exports.glin_web_needs_frame() !== 1) return;
    const t0 = performance.now();
    exports.glin_web_frame();
    blit();
    const t1 = performance.now();
    // Latency instrumentation, off unless the page asks for it. `?perf` in the
    // URL turns it on, so a developer can see the real cost of a click without
    // shipping a console spam to every visitor.
    if (perf) {
      const samples = perfSamples;
      samples.push(t1 - t0);
      if (samples.length >= 20) {
        samples.sort((a, b) => a - b);
        const median = samples[samples.length >> 1];
        const worst = samples[samples.length - 1];
        console.log(
          `glinlandui: draw ${median.toFixed(1)}ms median, ${worst.toFixed(1)}ms worst ` +
            `(${samples.length} samples, ${exports.glin_web_surface_width()}x${exports.glin_web_surface_height()})`,
        );
        samples.length = 0;
      }
    }
  }

  const perf = new URLSearchParams(location.search).has("perf");
  const perfSamples = [];

  const pointer =
    (kind) =>
    (event) => {
      const scale = deviceScale();
      exports.glin_web_pointer(kind, event.button, event.offsetX * scale, event.offsetY * scale);
      drawNow();
    };

  canvas.addEventListener("pointerdown", (event) => {
    canvas.focus();
    // Capture, so a drag that leaves the canvas keeps delivering motion. Without
    // this the toolkit sees a press and then silence, and drag-scrolling stops
    // the moment the pointer crosses the border.
    canvas.setPointerCapture(event.pointerId);
    pointer(1)(event);
  });
  canvas.addEventListener("pointerup", (event) => {
    if (canvas.hasPointerCapture(event.pointerId)) canvas.releasePointerCapture(event.pointerId);
    pointer(2)(event);
  });
  canvas.addEventListener("pointermove", pointer(0));
  // The OS took the gesture over (a touch scrolled the page, the pointer left a
  // pen's range). Reported as a release so the press is not left latched.
  canvas.addEventListener("pointercancel", (event) => {
    const scale = deviceScale();
    exports.glin_web_pointer(3, 0, event.offsetX * scale, event.offsetY * scale);
    drawNow();
  });
  // The toolkit models the secondary button, so the browser menu must not
  // swallow it.
  canvas.addEventListener("contextmenu", (event) => event.preventDefault());

  canvas.addEventListener(
    "wheel",
    (event) => {
      // `passive: false` is required, not cosmetic: without it `preventDefault`
      // is ignored and the PAGE scrolls as well as the toolkit's scroll view.
      event.preventDefault();
      exports.glin_web_wheel(event.deltaX, event.deltaY, event.deltaMode);
      drawNow();
    },
    { passive: false },
  );

  // Keyboard: the toolkit decides whether it consumed the key, and only a
  // consumed key suppresses the browser's default. That keeps Tab, Space and the
  // arrows working for the toolkit's own text fields while still letting them
  // scroll or move focus when nothing wants them — and it keeps the decision in
  // Zig instead of duplicating the keymap here.
  const scratch = exports.glin_web_key_scratch();
  const scratchLen = exports.glin_web_key_scratch_len();
  const encoder = new TextEncoder();

  addEventListener("keydown", (event) => {
    const consumed = sendKey(event.code, 1);
    // Draw before deciding on `preventDefault`: the key has already been applied
    // to the toolkit's state, so the frame that shows it should not wait for the
    // next animation frame.
    drawNow();
    if (consumed) event.preventDefault();
  });
  addEventListener("keyup", (event) => {
    // Never preventDefault on release: a key that was consumed on the way down
    // may already be past the point where the default matters, and suppressing
    // it here would break the browser's own key handling.
    sendKey(event.code, 0);
    drawNow();
  });

  function sendKey(code, pressed) {
    if (scratch === 0 || scratchLen === 0) return false;
    const bytes = encoder.encode(code);
    if (bytes.length > scratchLen) return false;
    // Written into the wasm-owned scratch block, so no allocation happens per
    // keystroke. `set` cannot grow the heap, so the view taken here stays valid
    // for the duration of the call.
    new Uint8Array(memory.buffer, scratch, scratchLen).set(bytes, 0);
    return exports.glin_web_key(scratch, bytes.length, pressed) === 1;
  }

  canvas.addEventListener("blur", () => {
    exports.glin_web_blur();
    drawNow();
  });
  addEventListener("blur", () => {
    exports.glin_web_blur();
    drawNow();
  });
  addEventListener("pagehide", () => exports.glin_web_shutdown());

  // ---- the font ----
  //
  // Nothing to do. The webapp EMBEDS its font (`build.zig`'s `-Dfont` option,
  // `@embedFile` in `src/web_main.zig`), and `glin_web_init` installs it before
  // the first frame — so text is glyphs from the very first draw, with no fetch,
  // no `assets/` directory and no server configuration.
  //
  // `glin_web_font` remains in the ABI for a page that wants to supply its own
  // face at runtime (see `src/web/shim.h`), but the default path needs no JS at
  // all, which is the point: the fewer decisions here, the better.

  // The link between the two applications. Set from JS rather than hard-coded in
  // the HTML so it always points at the OTHER one, whichever is loaded.
  const switchEl = document.getElementById("switch");
  if (switchEl) {
    switchEl.href = APP === "calculator" ? "?app=demo" : "?app=calculator";
    switchEl.textContent = APP === "calculator" ? "← Back to the demo" : "Open the calculator →";
  }

  // ---- the loop ----
  let reported = false;
  function loop() {
    if (exports.glin_web_needs_frame() === 1) {
      exports.glin_web_frame();
      blit();
      reportOnce();
    }
    requestAnimationFrame(loop);
  }

  function reportOnce() {
    if (reported) return;
    reported = true;
    const painted = exports.glin_web_painted_pixels();
    const hash = exports.glin_web_frame_hash() >>> 0;
    const errors = exports.glin_web_log_errors();
    log(
      `running — ${exports.glin_web_frames()} frame(s), ` +
        `${exports.glin_web_surface_width()}x${exports.glin_web_surface_height()} backing store, ` +
        `${painted} painted pixels, checksum 0x${hash.toString(16)}, ` +
        `${errors} log error(s)`,
    );
    if (errors > 0) {
      fail(`${errors} message(s) were logged at error level; see the browser console`);
    }
  }

  requestAnimationFrame(loop);
  log("running");
}

main().catch((err) => fail("glinlandui failed to start", err));
