// glinlandui browser shim — the browser-side peer of `mac/shim.m`: the page's
// half of the ABI, and one of exactly two JavaScript files in this project (the
// other is `gpu.js`, which owns the GPU contexts).
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
//     Clay commands -> vertices+segments  src/web/gpu.zig     (the GPU geometry)
//     which backend, and the CPU fallback src/web/renderer.zig
//
// That is the same division of labour `mac/shim.m` has, and it is the whole
// reason the shim is short: anything that could be got subtly wrong — a swapped
// red and blue, a mirrored y axis, a dropped keycode — is on the other side of
// the boundary, where a test can reach it. `src/web/shim.h` is the contract; this
// file only calls it.
//
// ## The things this file DOES own
//
// 1. **`memory.grow()` detaches views.** A `TypedArray` over wasm memory becomes
//    unusable (zero-length) after any allocation that grows the heap, and a
//    frame can grow the heap at any moment — a Clay arena resize, a glyph
//    bitmap. So the surface view is rebuilt whenever the memory BUFFER IDENTITY
//    or the surface POINTER changes, and never cached on the assumption that it
//    will not. Getting this wrong produces a UI that renders fine and then
//    presents as blank, intermittently.
//
// 2. **The GPU context and its draw calls.** `getContext("webgpu")` and
//    `getContext("webgl2")` are page-only APIs, so `web/gpu.js` owns them — and
//    owning the context means owning the ORDER (WebGPU, then WebGL2, then the CPU),
//    because a canvas hands out one kind of context for its lifetime. Everything
//    that ends up on screen is still decided in Zig: `web/gpu.js` uploads the
//    vertex buffer `src/web/gpu.zig` built and samples the atlas it packed, and it
//    makes no choices about what to draw.
//
// 3. **`requestAnimationFrame`.** The toolkit cannot own an event loop in a
//    browser, so this file runs the loop and asks `glin_web_needs_frame()` first.
//    An idle UI therefore costs one integer read per animation frame: no layout,
//    no rasterization, no pixel copy.
//
// ## Not a module graph, not a bundler
//
// Plain ES modules with one relative import (`./gpu.js`), no package manager, no
// build step. `zig build web` produces `zig-out/web/` and that directory is the
// whole application.

// The GPU backends live in their own module: plain ESM, relative path, still no
// bundler and no build step. `shim.js` keeps the decisions; `gpu.js` makes the
// API calls a page cannot delegate to Zig.
import { createBackend } from "./gpu.js";
// The page's IndexedDB half of the persistence ABI: one string in, one string out.
import { createStore } from "./store.js";

/**
 * Every application `zig build web` installs, and the module each one runs.
 *
 * One library, six wasm modules, one page: `?app=<id>` picks the file, exactly as
 * the native builds are one library and six executables. The apps are separate
 * modules rather than one module with a switch because each has its own `pub fn
 * main` on the desktop; the browser entry (`examples/<name>/web.zig`) binds the
 * same app type to the same ABI, so the page needs no per-app code at all.
 *
 * Keep this list in step with `zig build web`: `web/smoke.mjs` boots every module
 * named here, and a name with no file is a page that 404s. An app that lives in
 * its OWN repository is not in this list — it ships an `apps.json` beside its
 * module instead, and `loadApps` below merges the two.
 */
const BUILT_IN_APPS = {
  demo: { file: "glinlandui.wasm", label: "demo" },
  calculator: { file: "glinlandui-calculator.wasm", label: "calculator" },
  todo: { file: "glinlandui-todo.wasm", label: "todo (MVVM)" },
  catalog: { file: "glinlandui-catalog.wasm", label: "component catalog" },
  "file-dialog": { file: "glinlandui-file-dialog.wasm", label: "file dialog" },
  "lazy-scroll": { file: "glinlandui-lazy-scroll.wasm", label: "10,000 rows" },
};

/**
 * The apps this PAGE serves: exactly the ones `apps.json` beside the module
 * names, or the built-in list when it does not.
 *
 * A page that names its apps names ALL of them. Merging would hand every page the
 * toolkit's six, on a machine where five of the files do not exist — a menu that
 * 404s, and a `?app=` typo that boots an unrelated app because the demo happened
 * to be first. So `apps.json` REPLACES the list: an app in its own repository gets
 * a page that serves its module and nothing else, and the toolkit's own page (no
 * `apps.json`, six modules installed) keeps all six.
 *
 * A file that cannot be read, or that names no valid entry, leaves the built-ins
 * in place: a page that cannot parse one line of its menu should still boot the
 * apps it carries.
 */
async function loadApps() {
  let declared = null;
  try {
    const response = await fetch("apps.json", { cache: "no-cache" });
    if (response.ok) declared = await response.json();
  } catch {
    declared = null;
  }
  if (declared !== null && typeof declared === "object") {
    const own = {};
    for (const [id, entry] of Object.entries(declared)) {
      if (!entry || typeof entry.file !== "string" || entry.file.length === 0) continue;
      own[id] = { file: entry.file, label: typeof entry.label === "string" ? entry.label : id };
    }
    if (Object.keys(own).length > 0) return own;
  }
  return BUILT_IN_APPS;
}

const APPS = await loadApps();

/**
 * The first app the page serves is its default, so a one-app page opens ITS app
 * when the URL names none, and a name the page does not serve falls back to that
 * same app rather than to something it was never given.
 */
const DEFAULT_APP = Object.keys(APPS)[0];

/**
 * Which application to load.
 *
 * An unknown `?app=` falls back to the demo rather than failing the page: a typo
 * in a URL is not an error worth a blank canvas, and this is the one place the
 * page has to be forgiving.
 *
 * The choice is a URL parameter rather than a second HTML file because the page is
 * identical: one canvas, one status line, one set of event handlers. A second file
 * would be a copy that drifts.
 */
const APP = (new URLSearchParams(location.search).get("app") ?? DEFAULT_APP).toLowerCase();
const ENTRY = APPS[APP] ?? APPS[DEFAULT_APP];
const WASM_FILE = ENTRY.file;

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

/**
 * Report a failure the reader can see.
 *
 * The page is the window, so the status line is for the accessibility tree and
 * not for the eye; a failure is the one thing allowed to cover the app. The panel
 * is created on demand, so a page that works has no overlay at all.
 *
 * @param {string} message
 * @param {unknown} [cause]
 */
function fail(message, cause) {
  console.error("glinlandui:", message, cause ?? "");
  const text = cause && cause.message ? `${message} — ${cause.message}` : message;
  let panel = document.getElementById("error");
  if (!panel) {
    panel = document.createElement("p");
    panel.id = "error";
    panel.className = "error-panel";
    panel.setAttribute("role", "alert");
    document.body.appendChild(panel);
  }
  panel.textContent = text;
  log(text);
}

/**
 * A window size to pin, from `?w=360&h=430`.
 *
 * The canvas fills the viewport by default — a maximised window, which is what a
 * flexible layout wants. A fixed-size screen (the calculator is designed for
 * 360x430) reads better at its own size, so this pins the canvas to it and the
 * page centres it, exactly as a desktop window sits on a desktop. Absent or
 * nonsense values keep the full-bleed default.
 */
function pinnedSize() {
  const params = new URLSearchParams(location.search);
  const w = Number.parseInt(params.get("w") ?? "", 10);
  const h = Number.parseInt(params.get("h") ?? "", 10);
  if (!Number.isFinite(w) || !Number.isFinite(h) || w <= 0 || h <= 0) return null;
  return { w: Math.min(w, 4096), h: Math.min(h, 4096) };
}

/** The DOM's device pixel ratio, clamped to the toolkit's ceiling. */
function deviceScale() {
  const raw = window.devicePixelRatio || 1;
  if (!Number.isFinite(raw) || raw <= 0) return 1;
  return Math.min(raw, MAX_DEVICE_SCALE);
}

/**
 * Which backends the page may try, from `?gpu=`.
 *
 * `auto` (the default) is WebGPU, then WebGL2, then the CPU rasterizer. The other
 * values exist so the three paths can be compared on one machine without touching
 * the file — the browser's peer of `GLIN_NO_METAL` on macOS, and how the CPU
 * fallback is proven to still work in a browser that HAS a GPU.
 */
function gpuOptions() {
  const choice = (new URLSearchParams(location.search).get("gpu") ?? "auto").toLowerCase();
  const off = choice === "off" || choice === "cpu" || choice === "none";
  return {
    webgpu: !off && choice !== "webgl" && choice !== "webgl2",
    webgl2: !off && choice !== "webgpu",
  };
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
    if (!response.ok) {
      const error = new Error(`GET ${WASM_FILE} -> ${response.status} ${response.statusText}`);
      error.status = response.status;
      throw error;
    }
    module = await WebAssembly.compile(await response.arrayBuffer());
  } catch (err) {
    // Three failures that used to share one sentence, and it blamed the wrong one:
    // a page opened from disk, a module this page does not host, and a real load
    // failure. The second is what an external app hits when its `apps.json` is
    // missing or names a file it did not install, so it must say which name and
    // which file — the fix is a file, not a server.
    if (location.protocol === "file:") {
      fail("This page must be served over http(s): a file:// page cannot fetch a module.", err);
    } else if (err?.status === 404) {
      const named = Object.hasOwn(APPS, APP);
      fail(
        `The page does not host "${APP}": ${WASM_FILE} is not next to it` +
          (named ? "." : `, and no apps.json or built-in entry names "${APP}".`),
        err,
      );
    } else {
      fail(`Could not load ${WASM_FILE}.`, err);
    }
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
  // `?w=&h=` pins the canvas to an app's desktop window size; without it the canvas fills the viewport.
  const pinned = pinnedSize();
  if (pinned) {
    canvas.style.position = "relative";
    canvas.style.inset = "auto";
    canvas.style.width = `${pinned.w}px`;
    canvas.style.height = `${pinned.h}px`;
    canvas.classList.add("pinned");
    document.body.style.display = "grid";
    document.body.style.placeItems = "center";
  }
  const first = backingSize();
  canvas.width = first.w;
  canvas.height = first.h;

  // ---- the renderer: WebGPU, else WebGL2, else the CPU rasterizer ----
  //
  // Order matters, and not only for performance: a canvas hands out ONE kind of
  // context for its lifetime, so asking for `2d` first would make a WebGL2 or
  // WebGPU context impossible afterwards. The GPU is tried first, and the `2d`
  // context — the CPU path, unchanged — is only requested when neither exists.
  //
  // `?gpu=off` / `?gpu=webgl` / `?gpu=webgpu` force one backend, which is how the
  // three paths are compared without editing the file.
  let backend = await createBackend(canvas, gpuOptions());
  const ctx = backend ? null : canvas.getContext("2d", { alpha: false });
  if (!backend && !ctx) throw new Error("this canvas gave neither a GPU context nor a 2d one");

  if (exports.glin_web_init(first.w, first.h, 240, 180) !== 1) {
    fail("glin_web_init failed (already initialised, or out of memory)");
    return;
  }
  // Tell the toolkit which backend will draw. 1 = WebGPU, 2 = WebGL2, 0 = CPU:
  // for the first two it builds a vertex buffer instead of pixels from now on,
  // and `glin_web_surface_ptr()` returns 0, which is how `blit()` knows to stop.
  exports.glin_web_gpu_ready(backend ? backend.kind : 0);
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
    if (!ctx) return;
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

  // ---- present ----
  //
  // The frame is already built by the time this runs: `glin_web_frame` laid it out
  // and either rasterized it (CPU) or filled the vertex buffer (GPU). Both views
  // are rebuilt per frame, because a frame can grow the heap and `memory.grow()`
  // detaches every TypedArray over it — the rule at the top of this file.
  const EMPTY = new Uint8Array(0);

  function gpuValues() {
    const clear = exports.glin_web_gpu_clear_rgba() >>> 0;
    return {
      clear: [
        (clear & 0xff) / 255,
        ((clear >>> 8) & 0xff) / 255,
        ((clear >>> 16) & 0xff) / 255,
        ((clear >>> 24) & 0xff) / 255,
      ],
      vertexStride: exports.glin_web_gpu_vertex_stride(),
      segmentStride: exports.glin_web_gpu_segment_stride(),
      width: exports.glin_web_gpu_width(),
      height: exports.glin_web_gpu_height(),
      atlasW: exports.glin_web_gpu_atlas_width(),
      atlasH: exports.glin_web_gpu_atlas_height(),
      atlasVersion: exports.glin_web_gpu_atlas_version(),
    };
  }

  function gpuFrame() {
    const v = gpuValues();
    const vptr = exports.glin_web_gpu_verts_ptr();
    const vlen = exports.glin_web_gpu_verts_len();
    const sptr = exports.glin_web_gpu_segs_ptr();
    const segCount = exports.glin_web_gpu_segs_count();
    const aptr = exports.glin_web_gpu_atlas_ptr();
    const alen = exports.glin_web_gpu_atlas_len();
    const buffer = memory.buffer;
    const segmentBytes = segCount * v.segmentStride;
    // The image textures this frame names, decoded by the engine from the bytes the build embedded.
    const images = [];
    for (let i = 0, n = exports.glin_web_gpu_image_count(); i < n; i++) {
      const len = exports.glin_web_gpu_image_len(i);
      images.push({
        id: exports.glin_web_gpu_image_id(i),
        version: exports.glin_web_gpu_image_version(i),
        width: exports.glin_web_gpu_image_width(i),
        height: exports.glin_web_gpu_image_height(i),
        bytes: len ? new Uint8Array(buffer, exports.glin_web_gpu_image_ptr(i), len) : EMPTY,
      });
    }
    return {
      images,
      verts: vptr && vlen ? new Uint8Array(buffer, vptr, vlen) : EMPTY,
      segs: sptr && segmentBytes ? new Uint8Array(buffer, sptr, segmentBytes) : EMPTY,
      segCount: segmentBytes ? segCount : 0,
      atlas: aptr && alen ? new Uint8Array(buffer, aptr, alen) : null,
      ...v,
    };
  }

  // ---- the cursor ----
  //
  // The toolkit resolves the hover cursor itself (`core/frame.zig`'s
  // `hoverCursorShape`, fed by the click registry — the same function macOS and
  // Windows answer their OS with), so this half makes NO choice: it decodes the
  // CSS keyword the module published and assigns it. Writing `cursor: pointer`
  // from a guess here would be a second, untested opinion about what is
  // clickable, and it would be wrong the moment a component registers a resize
  // or I-beam cursor instead.
  //
  // The version is what makes it cheap. It moves only when the keyword changed,
  // so hovering one button is 60 frames of one integer read and exactly one DOM
  // write. The bytes are decoded per change and never cached: a frame can grow
  // the heap, and `memory.grow()` detaches every view over it — the rule at the
  // top of this file.
  let cursorVersion = -1;
  const cursorDecoder = new TextDecoder();

  function applyCursor() {
    const version = exports.glin_web_cursor_version() >>> 0;
    if (version === cursorVersion) return;
    cursorVersion = version;
    const ptr = exports.glin_web_cursor_ptr();
    const len = exports.glin_web_cursor_len();
    canvas.style.cursor =
      ptr && len ? cursorDecoder.decode(new Uint8Array(memory.buffer, ptr, len)) : "default";
  }

  function present() {
    // Before either path draws: the GPU's early return must not skip the hand over a button.
    applyCursor();
    if (backend) {
      try {
        if (backend.draw(gpuFrame())) return;
      } catch (err) {
        // A context that dies cannot be replaced on this canvas, so say what
        // happened once and stop: the last GPU frame stays on screen.
        fail("the GPU backend failed; reload to fall back to the CPU rasterizer", err);
        backend.destroy();
        backend = null;
        exports.glin_web_gpu_ready(0);
        return;
      }
    }
    blit();
  }

  // ---- the text mirror ----
  //
  // A canvas has pixels and no text, so the browser's find-in-page sees an empty
  // document: `Ctrl+F  text` reads 0/0 over a screen full of words. The mirror is
  // the fix — one transparent `<span>` per run the frame drew, at the box it drew
  // it in — and it is also what makes `window.find()` and text selection work.
  //
  // The runs arrive in CONTENT coordinates (`src/web/shim.h`), so scrolling the
  // app does not move a span: only the mirror's own `scrollTop` follows the page.
  // That is what lets find scroll the mirror, and `glin_web_find_scroll` carry the
  // landing position back into the app.
  const TEXT_HEAD = 24; // x, y, w, h, len, flags — the bytes before `chars`
  const TEXT_SCROLLS = 1; // entry flag: the run scrolls with the page, so its box is a content box

  const textLayer = document.createElement("div");
  textLayer.className = "text-layer";
  textLayer.id = "text-layer";
  textLayer.setAttribute("aria-hidden", "true");
  const textContent = document.createElement("div");
  textContent.className = "text-layer-content";
  textLayer.appendChild(textContent);
  document.body.appendChild(textLayer);

  const textFixed = document.createElement("div");
  textFixed.className = "text-layer-fixed";
  textFixed.id = "text-layer-fixed";
  textFixed.setAttribute("aria-hidden", "true");
  document.body.appendChild(textFixed);

  const textDecoder = new TextDecoder();
  let textSpans = [];
  let textVersion = 0;
  let mirroredScroll = 0;

  function rebuildText(ptr, count, stride) {
    const buffer = memory.buffer;
    const view = new DataView(buffer, ptr, count * stride);
    const scale = deviceScale();
    for (let i = 0; i < count; i++) {
      const at = i * stride;
      const len = view.getUint32(at + 16, true);
      const text = textDecoder.decode(new Uint8Array(buffer, ptr + at + TEXT_HEAD, len));
      // A run inside the page's scroller moves with it; the app's own chrome (a sidebar,
      // a title bar) does not, so it goes in the layer that never scrolls.
      const flags = view.getUint32(at + 20, true);
      const host = (flags & TEXT_SCROLLS) === TEXT_SCROLLS ? textContent : textFixed;
      let span = textSpans[i];
      if (!span) {
        span = document.createElement("span");
        textSpans.push(span);
      }
      if (span.parentNode !== host) host.appendChild(span);
      if (span.textContent !== text) span.textContent = text;
      const h = Math.max(1, Math.round(view.getFloat32(at + 12, true) / scale));
      span.style.left = `${Math.round(view.getFloat32(at, true) / scale)}px`;
      span.style.top = `${Math.round(view.getFloat32(at + 4, true) / scale)}px`;
      span.style.height = `${h}px`;
      span.style.lineHeight = `${h}px`;
      span.style.fontSize = `${Math.max(1, Math.round(h * 0.78))}px`;
    }
    for (let i = count; i < textSpans.length; i++) textSpans[i].remove();
    if (textSpans.length > count) textSpans.length = count;
  }

  function syncText() {
    const rect = canvas.getBoundingClientRect();
    const scale = deviceScale();
    for (const box of [textLayer, textFixed]) {
      box.style.left = `${rect.left}px`;
      box.style.top = `${rect.top}px`;
      box.style.width = `${rect.width}px`;
      box.style.height = `${rect.height}px`;
    }

    const count = exports.glin_web_text_len();
    const version = exports.glin_web_text_version();
    const ptr = exports.glin_web_text_ptr();
    if (version !== textVersion) {
      textVersion = version;
      if (ptr !== 0 && count > 0) rebuildText(ptr, count, exports.glin_web_text_stride());
      else rebuildText(0, 0, 0);
    }

    const reach = exports.glin_web_text_page_max() / scale;
    const height = Math.round(rect.height + reach);
    if (textContent.style.height !== `${height}px`) textContent.style.height = `${height}px`;

    const offset = exports.glin_web_text_page_offset() / scale;
    if (Math.abs(offset - mirroredScroll) > 0.5) {
      mirroredScroll = offset;
      textLayer.scrollTop = offset;
    }
  }

  // Find landed on a match inside the mirror, so the app's page must go there. The
  // guard is the app's own offset: a `scrollTop` this file wrote itself is not a
  // request, and answering it would fight the frame that just set it.
  textLayer.addEventListener(
    "scroll",
    () => {
      const scale = deviceScale();
      const target = textLayer.scrollTop * scale;
      if (Math.abs(target - exports.glin_web_text_page_offset()) <= 0.5) return;
      exports.glin_web_find_scroll(target);
      drawNow();
    },
    { passive: true },
  );

  // ---- size ----
  function pushSize() {
    const { w, h } = backingSize();
    exports.glin_web_resize(w, h);
    exports.glin_web_scale(deviceScale());
  }
  new ResizeObserver(pushSize).observe(canvas);
  window.addEventListener("resize", pushSize);

  // Zooming the page changes `devicePixelRatio`. `resize` usually fires with it, but a PINNED canvas
  // (`?w=&h=`) keeps the same CSS box, so the resize observer stays quiet and the toolkit would keep
  // hit-testing at the old scale — which is exactly the "clicks only work at 100%" report. A
  // `matchMedia` on the current resolution fires on every zoom step, so this re-arms itself each time.
  function watchDevicePixelRatio() {
    const query = matchMedia(`(resolution: ${devicePixelRatio}dppx)`);
    const onChange = () => {
      pushSize();
      watchDevicePixelRatio();
    };
    if (query.addEventListener) query.addEventListener("change", onChange, { once: true });
    else query.addListener(onChange);
  }
  watchDevicePixelRatio();

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
  //
  // ## The one handler that does NOT draw: the wheel
  //
  // A trackpad delivers SEVERAL wheel events per display refresh, and a
  // non-passive wheel listener is not coalesced by the browser (it cannot be —
  // each event is allowed to call `preventDefault`). Drawing inside the handler
  // therefore rasterizes and presents two or three whole surfaces for one
  // displayed frame, outside `requestAnimationFrame`, so the presents are not
  // vsync-aligned and only the last one is ever seen. That is measured, not
  // theoretical: on a 2880x1800 canvas three events per refresh cost 1.45 frames
  // and 1.45 presents per refresh — 45% of it thrown away — and 75% of the main
  // thread. The wheel handler below therefore only tells the toolkit, and the rAF
  // loop draws once with whatever the burst accumulated, which is what a desktop
  // backend already does (`mac/window.zig` marks the frame dirty and invalidates;
  // AppKit repaints at the next display refresh).
  function drawNow() {
    if (exports.glin_web_needs_frame() !== 1) return;
    const t0 = performance.now();
    exports.glin_web_frame();
    present();
    syncRoute();
    syncStore();
    syncText();
    const t1 = performance.now();
    // Latency instrumentation, off unless the page asks for it. `?perf` in the
    // URL turns it on, so a developer can see the real cost of a click without
    // shipping a console spam to every visitor.
    if (perf) {
      const samples = perfSamples;
      const onGpu = exports.glin_web_gpu_kind() !== 0;
      const w = onGpu ? exports.glin_web_gpu_width() : exports.glin_web_surface_width();
      const h = onGpu ? exports.glin_web_gpu_height() : exports.glin_web_surface_height();
      samples.push(t1 - t0);
      if (samples.length >= 20) {
        samples.sort((a, b) => a - b);
        const median = samples[samples.length >> 1];
        const worst = samples[samples.length - 1];
        console.log(
          `glinlandui: draw ${median.toFixed(1)}ms median, ${worst.toFixed(1)}ms worst ` +
            `(${samples.length} samples, ${w}x${h})`,
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

  // ---- persistence ----
  //
  // The app keeps a document of its own settings (`src/core/storage.zig`); the
  // page keeps the bytes of it in IndexedDB. Three calls, and the app owns every
  // decision behind them:
  //
  //   boot    read the stored string, hand it to `glin_web_store_adopt`, and the
  //           app applies it on the frame that adopt requests.
  //   change  the app marks its document dirty and stages it, so
  //           `glin_web_store_dirty()` says a write is owed.
  //   write   read the staged bytes, `glin_web_store_clean()`, and persist them
  //           DEBOUNCED — a slider drag is one write, not one per pixel.
  //
  // The whole block is declared before the first `await` below, so an event that
  // arrives while the store is opening cannot reach an uninitialised `syncStore`.
  const store = createStore({ name: "glinlandui", storeName: "state" });
  const storeScratch = exports.glin_web_store_scratch();
  const storeScratchLen = exports.glin_web_store_scratch_len();
  const storeDecoder = new TextDecoder();
  let storeTimer = 0;
  // The write the page still owes. It is kept until a save COMMITS, so a reload
  // inside the debounce window, or a write that failed on a quota, is retried
  // rather than lost — the module has already stopped owing it.
  let storePending = null;

  /** Write the pending document now: the debounce expiring, or the page going away. */
  function flushStore() {
    clearTimeout(storeTimer);
    storeTimer = 0;
    if (storePending === null) return;
    const text = storePending;
    storePending = null;
    void store.save(APP, text).then((ok) => {
      if (!ok && storePending === null) storePending = text;
    });
  }

  /** The stored document, handed to the module. Absent is normal, not an error. */
  async function adoptStored() {
    if (!store.available || storeScratch === 0 || storeScratchLen === 0) return;
    const text = await store.load(APP);
    if (typeof text !== "string" || text.length === 0) return;
    const bytes = encoder.encode(text);
    // A document larger than the module's slot is refused rather than truncated:
    // the module answers a half-read document by ignoring it anyway.
    if (bytes.length > storeScratchLen) return;
    new Uint8Array(memory.buffer, storeScratch, storeScratchLen).set(bytes, 0);
    exports.glin_web_store_adopt(storeScratch, bytes.length);
    drawNow();
  }

  /** Take the document the app staged, and write it once the reader stops moving. */
  function syncStore() {
    if (exports.glin_web_store_dirty() !== 1) return;
    const len = exports.glin_web_store_len();
    const ptr = exports.glin_web_store_ptr();
    // Decoded into a JS string BEFORE `clean`, because the module is free to
    // overwrite the block the moment it stops owing a write.
    const text = len === 0 ? "" : storeDecoder.decode(new Uint8Array(memory.buffer, ptr, len));
    exports.glin_web_store_clean();
    if (!store.available) return;
    storePending = text;
    clearTimeout(storeTimer);
    storeTimer = setTimeout(flushStore, 250);
  }

  // ---- the network ----
  //
  // The app stages ONE request at a time (`src/core/net.zig`), and this block
  // moves it: read the bytes, tell the module it may stage the next, `fetch`,
  // then write the status, the two delta-sync headers and the body back. Every
  // decision — a retry, a `304`, a `422` — stays in Zig, where it is tested.
  // What is here is the parse of a format the module wrote and the call into
  // `fetch`; nothing else.
  const netMetaScratch = exports.glin_web_net_meta_scratch();
  const netMetaScratchLen = exports.glin_web_net_meta_scratch_len();
  const netBodyScratch = exports.glin_web_net_body_scratch();
  const netBodyScratchLen = exports.glin_web_net_body_scratch_len();
  const netDecoder = new TextDecoder();

  /** Hand one answer back: the meta block, the body, then the call that applies it. */
  function settleNet(ticket, status, etag, version, body) {
    if (netMetaScratch === 0 || netBodyScratch === 0) return;
    const meta = encoder.encode(`${status}\n${etag}\n${version}\n`);
    const bodyBytes = encoder.encode(body);
    new Uint8Array(memory.buffer, netMetaScratch, netMetaScratchLen).set(meta, 0);
    // A body longer than the block is NOT truncated here: the true length is
    // reported and the module settles the answer as truncated itself, because
    // "a half-read body is worse than none" is its decision, not this page's.
    new Uint8Array(memory.buffer, netBodyScratch, netBodyScratchLen).set(
      bodyBytes.subarray(0, netBodyScratchLen),
      0,
    );
    exports.glin_web_net_reply(ticket, meta.length, bodyBytes.length);
    drawNow();
  }

  /** Turn one staged request into a `fetch`, and settle whatever comes back. */
  async function sendRequest(text) {
    const split = text.indexOf("\n\n");
    const head = split < 0 ? text : text.slice(0, split);
    const body = split < 0 ? "" : text.slice(split + 2);
    const lines = head.split("\n");
    const [ticketText, method, url] = (lines[0] ?? "").split(" ");
    const ticket = Number(ticketText);
    if (!Number.isInteger(ticket) || !method || !url) return;
    const headers = {};
    for (const line of lines.slice(1)) {
      const at = line.indexOf(":");
      if (at <= 0) continue;
      headers[line.slice(0, at).trim()] = line.slice(at + 1).trim();
    }
    const init = { method, headers, mode: "cors", credentials: "omit" };
    if (body.length > 0) init.body = body;
    try {
      const response = await fetch(url, init);
      // The two headers a delta sync needs are read verbatim; the module decides
      // what a `304` or a `422` means.
      settleNet(
        ticket,
        response.status,
        response.headers.get("etag") ?? "",
        response.headers.get("x-schema-version") ?? "",
        await response.text(),
      );
    } catch {
      // A transport failure is `status 0`: the module decides whether to retry.
      settleNet(ticket, 0, "", "", "");
    }
  }

  /** Read the request the app owes, free the slot, and send it. */
  function syncNet() {
    const len = exports.glin_web_net_request_len();
    if (len === 0) return;
    const ptr = exports.glin_web_net_request_ptr();
    // Decoded before `clean`, for the same reason the stored document is: the
    // module may overwrite the block the moment it stops owing a request.
    const text = netDecoder.decode(new Uint8Array(memory.buffer, ptr, len));
    exports.glin_web_net_request_clean();
    void sendRequest(text);
  }

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
  // A write still inside the debounce window is flushed on the way out: the timer
  // dies with the page, and the module has already stopped owing the document.
  addEventListener("pagehide", () => {
    flushStore();
    exports.glin_web_shutdown();
  });

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

  // The app switcher, built from `APPS` rather than hard-coded in the HTML, so the
  // page and the build can never disagree about what exists. It sits at the top
  // edge and stays hidden until the pointer or the keyboard reaches it, the way a
  // desktop app's menu bar does — the app itself has the whole window. The current
  // app is marked and not linked, and `?gpu=` is carried across so an A/B of the
  // renderer does not reset when you switch app.
  const nav = document.getElementById("apps");
  if (nav) {
    const gpu = new URLSearchParams(location.search).get("gpu");
    nav.textContent = "";
    for (const [id, entry] of Object.entries(APPS)) {
      const link = document.createElement("a");
      link.href = gpu ? `?app=${id}&gpu=${gpu}` : `?app=${id}`;
      link.textContent = entry.label;
      if (id === APP) {
        link.setAttribute("aria-current", "page");
        link.href = "#";
      }
      nav.appendChild(link);
      nav.appendChild(document.createTextNode(" "));
    }
  }

  // ---- routing ----
  //
  // The app's own address is `location.hash`; the page owns `?app=` (which module
  // to load) and the app owns the fragment (which screen). The toolkit keeps the
  // route, so this block makes no decisions: it copies the router's address into
  // the URL, and the URL's address back into the router. That is the whole of the
  // browser's half — the same navigation code runs on the desktop, where there is
  // no URL to mirror and `route.back()` is the history instead.
  //
  // `?app=catalog#buttons` is therefore a deep link, the browser's Back button
  // walks the app's own history, and an app that never navigates never touches
  // `history` at all.
  const routeScratch = exports.glin_web_route_scratch();
  const routeScratchLen = exports.glin_web_route_scratch_len();
  const routeDecoder = new TextDecoder();
  // The generation whose address the URL already shows: an address the page just
  // adopted is not pushed straight back into the history, which is what keeps Back
  // from skipping two entries at a time.
  let mirroredRoute = -1;

  /** Take the URL's address into the router (`popstate`, `hashchange`, deep link). */
  function adoptLocation() {
    const path = location.hash.replace(/^#/, "");
    const bytes = encoder.encode(path);
    if (bytes.length === 0) {
      mirroredRoute = exports.glin_web_location(0, 0);
      return;
    }
    if (routeScratch === 0 || routeScratchLen === 0 || bytes.length > routeScratchLen) {
      mirroredRoute = exports.glin_web_location(0, 0);
      return;
    }
    // The wasm-owned scratch block, exactly as a keystroke uses the key scratch:
    // no allocation, so no heap growth and no detached view.
    new Uint8Array(memory.buffer, routeScratch, routeScratchLen).set(bytes, 0);
    mirroredRoute = exports.glin_web_location(routeScratch, bytes.length);
  }

  /** Write the router's address into the URL, once per generation it has not seen. */
  function syncRoute() {
    const generation = exports.glin_web_route_generation();
    if (generation === mirroredRoute) return;
    mirroredRoute = generation;
    const len = exports.glin_web_route_len();
    const ptr = exports.glin_web_route_ptr();
    const path = len === 0 ? "" : routeDecoder.decode(new Uint8Array(memory.buffer, ptr, len));
    // A hash-only URL keeps `?app=`, so switching app and going back both keep working.
    const url = path === "" ? `${location.pathname}${location.search}` : `#${path}`;
    history.pushState({ route: path }, "", url);
  }

  addEventListener("popstate", () => {
    adoptLocation();
    drawNow();
  });
  addEventListener("hashchange", () => {
    adoptLocation();
    drawNow();
  });

  // The boot deep link, before the first frame: an app that declares from the
  // route must see the address the URL carried.
  adoptLocation();

  // Then the app's own document, also before the first frame, so a reload draws
  // the restored screen once instead of drawing the default one and flipping.
  await adoptStored();

  // The API origin: `?api=` when the page carries one, else the app's own
  // default. The app composes every address from it, so this is a string and no
  // decision; a page served next to its backend passes nothing at all.
  const netOriginScratch = exports.glin_web_net_origin_scratch();
  const netOriginScratchLen = exports.glin_web_net_origin_scratch_len();
  const apiOrigin = new URLSearchParams(location.search).get("api");
  if (apiOrigin && netOriginScratch !== 0 && netOriginScratchLen !== 0) {
    const bytes = encoder.encode(apiOrigin);
    if (bytes.length <= netOriginScratchLen) {
      new Uint8Array(memory.buffer, netOriginScratch, netOriginScratchLen).set(bytes, 0);
      exports.glin_web_net_origin(netOriginScratch, bytes.length);
    }
  }

  // ---- the loop ----
  let reported = false;
  function loop() {
    if (exports.glin_web_needs_frame() === 1) {
      exports.glin_web_frame();
      present();
      syncRoute();
      syncText();
      reportOnce();
    }
    // OUTSIDE the frame guard, both of them: an answer is applied INSIDE a frame,
    // and the request or the write that answer starts has to leave on this tick.
    // Waiting for the next frame looks harmless and is not — a load that drew what
    // it already had marks nothing dirty, so the request would sit staged forever
    // while the app waited for an answer it never asked for.
    syncStore();
    syncNet();
    requestAnimationFrame(loop);
  }

  function reportOnce() {
    if (reported) return;
    reported = true;
    const errors = exports.glin_web_log_errors();
    const kind = exports.glin_web_gpu_kind();
    // A GPU frame has no CPU pixels to count or checksum, so it reports the work
    // it actually did instead: the backend, the frame size and the vertex count.
    const backendName = kind === 1 ? "WebGPU" : kind === 2 ? "WebGL2" : "CPU rasterizer";
    const width = kind === 0 ? exports.glin_web_surface_width() : exports.glin_web_gpu_width();
    const height = kind === 0 ? exports.glin_web_surface_height() : exports.glin_web_gpu_height();
    let detail;
    if (kind === 0) {
      const hash = exports.glin_web_frame_hash() >>> 0;
      detail = `${exports.glin_web_painted_pixels()} painted pixels, checksum 0x${hash.toString(16)}`;
    } else {
      const stride = exports.glin_web_gpu_vertex_stride() || 1;
      const vertices = Math.round(exports.glin_web_gpu_verts_len() / stride);
      detail = `${vertices} vertices, ${exports.glin_web_gpu_segs_count()} segment(s)`;
    }
    log(
      `running — ${exports.glin_web_frames()} frame(s), ${backendName}, ` +
        `${width}x${height} backing store, ${detail}, ${errors} log error(s)`,
    );
    if (errors > 0) {
      fail(`${errors} message(s) were logged at error level; see the browser console`);
    }
  }

  requestAnimationFrame(loop);
  log("running");
}

main().catch((err) => fail("glinlandui failed to start", err));
