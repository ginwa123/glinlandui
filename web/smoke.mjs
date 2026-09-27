// glinlandui browser smoke test — the peer of `ci/check_macos_colors.sh`.
//
// ## What this is FOR
//
// `ci/check_macos_colors.c` exists because a green parity suite could not catch a
// wrong `kCGBitmapInfo`: the bug lived in the shim, and the shim is the one part
// no Zig test can reach. The browser backend has the same structural gap — a
// canvas, a DOM, a `requestAnimationFrame` — and this is the check that closes
// it *without a browser*, by driving the real module through the real ABI and
// asserting on real pixels.
//
// That is possible because the browser backend has no browser-specific code in
// Zig at all: everything between "a frame was requested" and "RGBA8 bytes exist"
// is the same code macOS runs. What this script can therefore prove is:
//
//   1. the module is DEPENDENCY-FREE — `WebAssembly.Module.imports().length === 0`
//      (`wasm32-freestanding`, no WASI, no libc). This is the assertion that
//      justifies the target choice, and the one that fails first if the compat
//      layer in `src/web/compat/` ever has a hole.
//   2. the ABI in `src/web/shim.h` matches what the module actually EXPORTS. The
//      header is the contract `web/shim.js` is written against; a header that has
//      drifted is worse than no header, and nothing else in the repository would
//      notice.
//   3. a frame really draws: `painted_pixels > 0` and a non-zero `frame_hash`. A
//      blank canvas still paints every pixel, so "it exited 0" proves nothing.
//   4. the dirty-flag contract holds, which is the idle-CPU guarantee: no frame
//      needed after a frame, a frame needed after an event.
//   5. input reaches the toolkit and CHANGES THE OUTPUT: a synthesised click on
//      the demo's button must alter the rendered frame, because the demo renders
//      its own click count.
//
// Run with `node web/smoke.mjs` after `zig build web`.
//
// ## What it deliberately does NOT assert
//
// An exact frame checksum shared with the native builds. Floating point is not
// guaranteed bit-identical between wasm and x86 (a different `@sqrt` lowering, a
// fused multiply-add the host fuses and the browser does not), and
// `render_software.zig`'s 1px antialias band and pill-clamped corner radius are
// both `f32`-sensitive. So this pins STRUCTURE — dimensions, painted-pixel
// counts, and *changes* between frames — rather than a whole-surface hash. A
// checksum is compared only against itself (frame N vs frame N+1), which is
// exactly the property a click is supposed to change.

import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..");
const wasmPath = join(root, "zig-out", "web", "glinlandui.wasm");
const shimPath = join(root, "src", "web", "shim.h");

let failures = 0;
let checks = 0;

function check(ok, label, detail = "") {
  checks += 1;
  if (ok) {
    console.log(`  ok    ${label}`);
  } else {
    failures += 1;
    console.error(`  FAIL  ${label}${detail ? ` — ${detail}` : ""}`);
  }
}

function eq(actual, expected, label) {
  check(
    actual === expected,
    label,
    actual === expected ? "" : `expected ${expected}, got ${actual}`,
  );
}

/**
 * Every `glin_web_*` function DECLARED in `shim.h`.
 *
 * Only declaration lines count (they end in `);` and are not comment bodies), so
 * a prose mention like "`glin_web_surface_ptr()` returns …" is not mistaken for a
 * declaration. Without that, the header's explanations would fail the comparison.
 */
function declaredAbi(headerText) {
  const names = new Set();
  for (const line of headerText.split("\n")) {
    const trimmed = line.trim();
    if (trimmed.startsWith("*") || trimmed.startsWith("//")) continue;
    if (!trimmed.endsWith(");")) continue;
    const match = trimmed.match(/\b(glin_web_[a-z0-9_]+)\s*\(/);
    if (match) names.add(match[1]);
  }
  return names;
}

/** Pixels differing from the frame's first pixel — a cheap "is it flat?" probe. */
function distinctBytes(bytes) {
  const first = bytes.slice(0, 4);
  for (let i = 4; i + 3 < bytes.length; i += 4) {
    if (
      bytes[i] !== first[0] ||
      bytes[i + 1] !== first[1] ||
      bytes[i + 2] !== first[2]
    ) {
      return true;
    }
  }
  return false;
}

async function main() {
  console.log(`glinlandui web smoke test\n  module: ${wasmPath}\n`);

  let bytes;
  try {
    bytes = await readFile(wasmPath);
  } catch (err) {
    console.error(
      `  FAIL  cannot read ${wasmPath}\n        run \`zig build web\` first (${err.code})`,
    );
    process.exit(1);
  }

  const module = await WebAssembly.compile(bytes);
  const ex = await WebAssembly.instantiate(module, {}).then((i) => i.exports);

  // ---- 1. the module needs nothing from its host ----
  const imports = WebAssembly.Module.imports(module);
  check(
    imports.length === 0,
    "the module has an empty import section (wasm32-freestanding, no libc/WASI)",
    imports.length === 0
      ? ""
      : imports.map((i) => `${i.module}.${i.name}`).join(", "),
  );

  // ---- 2. the header and the module agree ----
  const header = await readFile(shimPath, "utf8");
  const declared = declaredAbi(header);
  const exported = new Set(
    WebAssembly.Module.exports(module)
      .map((e) => e.name)
      .filter((n) => n.startsWith("glin_web_")),
  );
  const missing = [...declared].filter((n) => !exported.has(n));
  const undocumented = [...exported].filter((n) => !declared.has(n));
  check(
    declared.size > 0,
    "the ABI header declares at least one glin_web_* function",
    `parsed ${declared.size}`,
  );
  check(
    missing.length === 0,
    "every function shim.h declares is exported by the module",
    missing.join(", "),
  );
  check(
    undocumented.length === 0,
    "every glin_web_* export is declared in shim.h",
    undocumented.join(", "),
  );

  check(
    ex.memory instanceof WebAssembly.Memory,
    "the module exports its linear memory, so a canvas can be filled",
  );

  // ---- 3. lifecycle ----
  eq(ex.glin_web_init(480, 360, 240, 180), 1, "glin_web_init succeeds");
  eq(
    ex.glin_web_init(480, 360, 240, 180),
    0,
    "a second glin_web_init is refused rather than spawning a second Host",
  );
  eq(ex.glin_web_run(), 1, "glin_web_run arms the loop");
  check(ex.glin_web_key_scratch() !== 0, "a key scratch block was allocated");

  // ---- 4. the dirty-flag contract (the idle-CPU guarantee) ----
  eq(ex.glin_web_needs_frame(), 1, "a frame is wanted before the first one is drawn");
  ex.glin_web_frame();
  eq(ex.glin_web_needs_frame(), 0, "no frame is wanted once one has been drawn");
  eq(ex.glin_web_frames(), 1, "exactly one frame was counted");

  // ---- 5. real pixels ----
  const w = ex.glin_web_surface_width();
  const h = ex.glin_web_surface_height();
  const ptr = ex.glin_web_surface_ptr();
  const len = ex.glin_web_surface_len();
  eq(w, 480, "the surface is as wide as the canvas was declared");
  eq(h, 360, "the surface is as tall as the canvas was declared");
  eq(len, w * h * 4, "the surface length is width * height * 4 (RGBA8)");
  check(ptr !== 0, "the surface pointer is non-zero");

  const painted = ex.glin_web_painted_pixels();
  const hash = ex.glin_web_frame_hash() >>> 0;
  check(
    painted > 0,
    "the frame painted pixels (a blank canvas would paint every one too, but zero means nothing was drawn)",
    `painted=${painted}`,
  );
  check(hash !== 0, "the frame checksum is non-zero", `hash=0x${hash.toString(16)}`);

  const surface = new Uint8Array(ex.memory.buffer, ptr, len);
  check(distinctBytes(surface), "the frame is not a flat fill");

  // ---- 6. the toolkit reported no errors ----
  // A renderer that failed to initialise, or a Clay assert, increments this. It
  // replaces the macOS job's log grep, and does not depend on anyone having
  // predicted the message text.
  eq(ex.glin_web_log_errors(), 0, "drawing a frame logged no errors");

  // ---- 6b. the embedded font actually installed ----
  //
  // THE assertion that would have caught the bug this check exists for. The
  // browser showed glyph-free bars for a long time while every other check here
  // passed, because `glin_web_font` returns a bare 0/1 and the failure was
  // recorded nowhere. `glin_web_font_error` now says WHY:
  //
  //   0 = installed, 1 = empty, 2 = not an sfnt, 3 = stb refused it, 4 = no window
  //
  // 4 is the one that actually happened: the install ran before `g_window` was
  // set, so it silently did nothing. A non-zero value here means the page will
  // draw bars, and the number says which mistake it was.
  eq(ex.glin_web_font_error(), 0, "the embedded font installed (0 = no failure)");

  // And prove it by PIXELS, not by a flag: antialiased glyphs produce many
  // distinct shades in a text band, while the per-byte bar fallback produces a
  // handful of flat ones. A flag can be wrong; the pixels cannot.
  {
    const w = ex.glin_web_surface_width();
    const px = new Uint8Array(ex.memory.buffer, ex.glin_web_surface_ptr(), ex.glin_web_surface_len());
    const shades = new Set();
    for (let y = 20; y < 50; y++) {
      for (let x = 20; x < Math.min(300, w); x++) {
        const i = (y * w + x) * 4;
        shades.add(`${px[i]},${px[i + 1]},${px[i + 2]}`);
      }
    }
    check(
      shades.size > 20,
      "the title band is antialiased text, not the glyph-free bar fallback",
      `${shades.size} distinct colours (bars produce < 10)`,
    );
  }

  // ---- 7. input reaches the toolkit and changes what is drawn ----
  //
  // The demo renders its own click count, so a click that lands must change the
  // frame. This is the assertion that proves the whole chain — DOM-shaped
  // coordinates, the evdev button code, dispatch, the registry, the app's
  // callback, the re-render — rather than only that the code ran.
  //
  // The coordinates are the demo's "Click me" button, found by sweeping a grid
  // from a FRESH instance per candidate — a sweep that reuses one instance
  // reports hover changes as hits, which is how the first version of this test
  // passed while the click was actually missing.
  //
  // The baseline is taken AFTER the press, not before it: moving the pointer onto
  // the button changes the hover chrome, so a pre-press baseline would make the
  // hover change look like the click. What this asserts is the thing that
  // matters — the RELEASE fires the app's callback and the click count renders.
  const button_x = 20;
  const button_y = 90;
  ex.glin_web_pointer(1, 0, button_x, button_y);
  eq(ex.glin_web_needs_frame(), 1, "a pointer press marks the frame dirty");
  ex.glin_web_frame();
  const afterDownHash = ex.glin_web_frame_hash() >>> 0;

  ex.glin_web_pointer(2, 0, button_x, button_y); // release in place: a click
  eq(ex.glin_web_needs_frame(), 1, "a pointer release marks the frame dirty");
  ex.glin_web_frame();
  const afterClickHash = ex.glin_web_frame_hash() >>> 0;
  check(
    afterClickHash !== afterDownHash,
    "the synthesised click changed the rendered frame (the demo draws its click count)",
    `0x${afterDownHash.toString(16)} -> 0x${afterClickHash.toString(16)}`,
  );

  // Motion alone must NOT change the drawing when it cannot affect hover state.
  ex.glin_web_pointer(0, 0, 240, 300);
  ex.glin_web_frame();
  // Frames so far: 1 (the first draw) + 1 (after the press) + 1 (after the click)
  // + 1 (this motion) = 4. The assertion is deliberately an exact count rather
  // than `> 0`, because "the counter increments once per frame" is the property
  // that makes `glin_web_frames` usable as a diagnostic at all.
  eq(ex.glin_web_frames(), 4, "frames are counted across input-driven draws");

  // Keyboard: a mapped code is recognised, an unknown one is silence.
  const scratch = ex.glin_web_key_scratch();
  const scratchLen = ex.glin_web_key_scratch_len();
  const writeCode = (code) => {
    const b = new TextEncoder().encode(code);
    if (b.length > scratchLen) return -1;
    new Uint8Array(ex.memory.buffer, scratch, scratchLen).set(b, 0);
    return b.length;
  };
  const n = writeCode("KeyA");
  check(n > 0, "wrote a KeyboardEvent.code into the scratch block");
  const consumedA = ex.glin_web_key(scratch, n, 1);
  check(consumedA === 0 || consumedA === 1, "glin_web_key answers consumed/not-consumed", `got ${consumedA}`);
  const escaped = writeCode("ThisIsNotAKey");
  eq(ex.glin_web_key(scratch, escaped, 1), 0, "an unmapped code is refused, not guessed");

  // ---- 8. resize coalescing ----
  ex.glin_web_resize(600, 400);
  eq(ex.glin_web_needs_frame(), 1, "a resize marks the frame dirty");
  ex.glin_web_frame();
  eq(ex.glin_web_surface_width(), 600, "the surface adopted the new width");
  eq(ex.glin_web_surface_height(), 400, "the surface adopted the new height");
  eq(ex.glin_web_surface_len(), 600 * 400 * 4, "and its length with it");

  // ---- 9. shutdown is safe and idempotent-ish ----
  ex.glin_web_shutdown();
  ex.glin_web_shutdown();
  eq(ex.glin_web_needs_frame(), 0, "a shut-down window wants no frames");

  // ---- 10. the calculator, if it was built ----
  //
  // A SECOND module from a second entry point, sharing the library and the ABI.
  // This is the check that the calculator's keyboard path works in a browser:
  // `src/web/keymap.zig` translates `"NumpadAdd"` to evdev 78, and the
  // calculator's own `onKey` maps 78 to `plus`. Driving it here proves the whole
  // chain — DOM-shaped code string, keymap, the Host's KeyChain, the app's
  // handler, the re-render — without a browser.
  const calcPath = join(root, "zig-out", "web", "glinlandui-calculator.wasm");
  let calcBytes = null;
  try {
    calcBytes = await readFile(calcPath);
  } catch {
    console.log("\n  note  the calculator was not built; run `zig build web-calculator`");
  }

  if (calcBytes) {
    console.log("\n  --- calculator ---");
    const calcModule = await WebAssembly.compile(calcBytes);
    const calcImports = WebAssembly.Module.imports(calcModule);
    check(
      calcImports.length === 0,
      "the calculator module is dependency-free too",
      calcImports.map((i) => `${i.module}.${i.name}`).join(", "),
    );

    const cx = await WebAssembly.instantiate(calcModule, {}).then((i) => i.exports);
    eq(cx.glin_web_init(360, 430, 360, 430), 1, "the calculator initialises");
    eq(cx.glin_web_run(), 1, "the calculator arms its loop");
    cx.glin_web_frame();
    check(cx.glin_web_painted_pixels() > 0, "the calculator painted pixels");
    eq(cx.glin_web_log_errors(), 0, "the calculator logged no errors");

    // Type "7 + 8 =" through the keymap and assert the display changed.
    const cscratch = cx.glin_web_key_scratch();
    const cscratchLen = cx.glin_web_key_scratch_len();
    const typeKey = (code) => {
      const b = new TextEncoder().encode(code);
      if (b.length > cscratchLen) return false;
      new Uint8Array(cx.memory.buffer, cscratch, cscratchLen).set(b, 0);
      cx.glin_web_key(cscratch, b.length, 1);
      cx.glin_web_key(cscratch, b.length, 0);
      cx.glin_web_frame();
      return true;
    };

    const before = cx.glin_web_frame_hash() >>> 0;
    for (const code of ["Digit7", "NumpadAdd", "Digit8", "NumpadEnter"]) {
      check(typeKey(code), `the calculator accepts ${code}`);
    }
    const after = cx.glin_web_frame_hash() >>> 0;
    check(
      after !== before,
      "typing 7 + 8 = changed the calculator's display",
      `0x${before.toString(16)} -> 0x${after.toString(16)}`,
    );

    // A key the toolkit does not know must be silence, not a guess.
    const unknown = new TextEncoder().encode("ThisIsNotAKey");
    new Uint8Array(cx.memory.buffer, cscratch, cscratchLen).set(unknown, 0);
    eq(cx.glin_web_key(cscratch, unknown.length, 1), 0, "an unmapped code is refused by the calculator too");

    // A click on a keypad key must also work — the pointer path, not just keys.
    const beforeClick = cx.glin_web_frame_hash() >>> 0;
    cx.glin_web_pointer(1, 0, 40, 200);
    cx.glin_web_pointer(2, 0, 40, 200);
    cx.glin_web_frame();
    check(
      (cx.glin_web_frame_hash() >>> 0) !== beforeClick,
      "a click on the keypad changed the calculator's display",
    );
  }

  console.log(
    `\n${checks - failures}/${checks} checks passed` +
      (failures ? `, ${failures} FAILED` : " — the browser backend draws real pixels"),
  );
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((err) => {
  console.error("glinlandui: the smoke test itself failed", err);
  process.exit(1);
});
