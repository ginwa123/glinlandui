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
//      its own click count — and a pointer over that button publishes the CSS
//      `cursor` keyword the page assigns, then the arrow again when it leaves.
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

/** The frame's text runs, decoded out of the module: what `web/shim.js` mirrors into the DOM. */
function textRuns(ex) {
  const count = ex.glin_web_text_len();
  const stride = ex.glin_web_text_stride();
  const ptr = ex.glin_web_text_ptr();
  const runs = [];
  if (!ptr || !count || !stride) return runs;
  const decoder = new TextDecoder();
  const view = new DataView(ex.memory.buffer, ptr, count * stride);
  for (let i = 0; i < count; i++) {
    const at = i * stride;
    const len = view.getUint32(at + 16, true);
    runs.push({
      x: view.getFloat32(at, true),
      y: view.getFloat32(at + 4, true),
      w: view.getFloat32(at + 8, true),
      h: view.getFloat32(at + 12, true),
      flags: view.getUint32(at + 20, true),
      text: decoder.decode(new Uint8Array(ex.memory.buffer, ptr + at + 24, len)),
    });
  }
  return runs;
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

  // ---- routing ----
  //
  // The app owns its address and the page mirrors it into `location.hash`; what the
  // MODULE must provide is the address itself, a generation that moves only when it
  // moves, and the page's way in (`glin_web_location`). This is the ABI half of the
  // router — the desktop half is the same code, driven by `core/route.zig`'s tests.
  eq(ex.glin_web_route_len(), 0, `a fresh window has no address of its own`);
  const routeScratch = ex.glin_web_route_scratch();
  const routeScratchLen = ex.glin_web_route_scratch_len();
  check(routeScratch !== 0 && routeScratchLen >= 32, `there is a scratch block for an address`, `${routeScratchLen} bytes`);
  const genBefore = ex.glin_web_route_generation();
  new Uint8Array(ex.memory.buffer, routeScratch, routeScratchLen).set(new TextEncoder().encode("buttons"), 0);
  const genAfter = ex.glin_web_location(routeScratch, 7);
  check(genAfter !== genBefore, `adopting the page's address moves the generation`);
  eq(ex.glin_web_route_len(), 7, `and the address is what the page said`);
  eq(
    new TextDecoder().decode(new Uint8Array(ex.memory.buffer, ex.glin_web_route_ptr(), 7)),
    "buttons",
    `and it reads back byte for byte`,
  );
  eq(ex.glin_web_location(routeScratch, 7), genAfter, `the same address again is not a change`);


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

  // ---- persistence ----
  //
  // IndexedDB is page-only and asynchronous, and this module imports NOTHING, so the two sides
  // exchange BYTES: the page writes a stored document into a wasm-owned scratch block and adopts
  // it, and reads back whatever the app stages. `node` has no `indexedDB`, so what this proves is
  // the ABI contract — a revision that moves on adopt, a dirty flag that is clear until something
  // is owed, and a scratch block big enough to hold a document. The round trip through the app's
  // own model is `examples/catalog/app.zig`'s tests, and the database itself is `web/store.js`,
  // whose absence-in-Node path this same check exercises by never touching it.
  eq(ex.glin_web_store_dirty(), 0, "a fresh window owes the page no write");
  eq(ex.glin_web_store_len(), 0, "and stages no document");
  const storeScratch = ex.glin_web_store_scratch();
  const storeScratchLen = ex.glin_web_store_scratch_len();
  check(storeScratch !== 0 && storeScratchLen >= 1024, "there is a scratch block for a stored document", `${storeScratchLen} bytes`);
  const storeRevBefore = ex.glin_web_store_revision();
  const storedDocument = new TextEncoder().encode('{"v":2,"e":{"dense":"1","route":"buttons"}}');
  check(storedDocument.length <= storeScratchLen, "a document fits the block");
  new Uint8Array(ex.memory.buffer, storeScratch, storeScratchLen).set(storedDocument, 0);
  const storeRevAfter = ex.glin_web_store_adopt(storeScratch, storedDocument.length);
  check(storeRevAfter !== storeRevBefore, "adopting a stored document moves the revision");
  eq(ex.glin_web_store_adopt(0, 0), storeRevAfter, "an empty adopt is `nothing stored`, not a new document");
  // The adopt asks for a frame, because a page's load lands between frames and the loop is idle.
  eq(ex.glin_web_needs_frame(), 1, "adopting a document asks for the frame that draws it");
  ex.glin_web_frame();
  eq(ex.glin_web_log_errors(), 0, "applying a document logged no errors");

  // ---- 7a. the network, as bytes ----
  //
  // The same shape as persistence and for the same reason: `fetch` is page-only
  // and asynchronous, and the module imports NOTHING, so the two sides exchange
  // BYTES. Node has no page driver, so what this proves is the contract the
  // driver relies on: nothing is owed before the app asks, one request is in
  // flight at a time, an answer moves the revision and asks for the frame that
  // applies it, and a meta block that is not a status is refused rather than
  // read as "no answer". What the app DOES with an answer is
  // `examples/fokus`'s tests; the driver itself is `web/shim.js`.
  eq(ex.glin_web_net_request_len(), 0, "a fresh window owes the page no request");
  const netOrigin = ex.glin_web_net_origin_scratch();
  const netOriginLen = ex.glin_web_net_origin_scratch_len();
  const netMeta = ex.glin_web_net_meta_scratch();
  const netMetaLen = ex.glin_web_net_meta_scratch_len();
  const netBody = ex.glin_web_net_body_scratch();
  const netBodyLen = ex.glin_web_net_body_scratch_len();
  check(netOrigin !== 0 && netOriginLen >= 32, "there is a scratch block for an API origin", `${netOriginLen} bytes`);
  check(netMeta !== 0 && netMetaLen >= 64, "there is a scratch block for a reply's status and tags", `${netMetaLen} bytes`);
  check(netBody !== 0 && netBodyLen >= 4096, "there is a scratch block for a reply's body", `${netBodyLen} bytes`);
  const netEncoder = new TextEncoder();
  const netMetaBytes = netEncoder.encode('200\n"0123456789abcdef"\nabc123\n');
  new Uint8Array(ex.memory.buffer, netMeta, netMetaLen).set(netMetaBytes, 0);
  const netBodyBytes = netEncoder.encode('{"companies":[]}');
  new Uint8Array(ex.memory.buffer, netBody, netBodyLen).set(netBodyBytes, 0);
  const netRevBefore = ex.glin_web_net_revision();
  const netRevAfter = ex.glin_web_net_reply(1, netMetaBytes.length, netBodyBytes.length);
  check(netRevAfter !== netRevBefore, "settling an answer moves the revision");
  eq(ex.glin_web_needs_frame(), 1, "a settled answer asks for the frame that applies it");
  ex.glin_web_frame();
  eq(ex.glin_web_log_errors(), 0, "applying an answer logged no errors");
  const heldRevision = ex.glin_web_net_revision();
  eq(
    ex.glin_web_net_reply(2, 0, 0),
    heldRevision,
    "a meta block that is not a status is refused, not applied",
  );
  check(
    !/uint64_t\s+glin_web_frame_hash/.test(header),
    "the frame hash is declared at the width the module exports",
  );

  // ---- 7b. the hover cursor reaches the page as a CSS keyword ----
  //
  // A native backend answers the OS with a cursor SHAPE (`glin_cocoa_set_cursor`,
  // `glin_win_set_cursor`). A browser has no such call, only a stylesheet, so the
  // same resolved shape has to arrive as a `canvas.style.cursor` keyword — and
  // this is where the browser was silent for a long time: every click, toggle and
  // slider worked, and the pointer never became a hand. The choice is NOT the
  // page's (`web/shim.js` only assigns the bytes decoded here), so what this pins
  // is the keyword the toolkit publishes.
  const decoder = new TextDecoder();
  const cursorKeyword = () => {
    const ptr = ex.glin_web_cursor_ptr();
    const len = ex.glin_web_cursor_len();
    return ptr && len ? decoder.decode(new Uint8Array(ex.memory.buffer, ptr, len)) : "";
  };
  check(cursorKeyword().length > 0, "the module publishes a CSS cursor keyword", cursorKeyword());
  // The pointer was last moved to (240, 300), where the demo has nothing clickable.
  eq(cursorKeyword(), "default", "a pointer over empty space leaves the arrow in place");

  // Onto the demo's button — the coordinate the click above landed on.
  ex.glin_web_pointer(0, 0, button_x, button_y);
  ex.glin_web_frame();
  eq(cursorKeyword(), "pointer", "hovering the button publishes the hand");

  // The change-only gate. Without it, a hover would be one DOM write per frame —
  // 60 a second for a pointer that has not moved off the button.
  const hoverVersion = ex.glin_web_cursor_version();
  ex.glin_web_pointer(0, 0, button_x + 2, button_y + 2);
  ex.glin_web_frame();
  eq(cursorKeyword(), "pointer", "moving around ON the button keeps the hand");
  eq(
    ex.glin_web_cursor_version(),
    hoverVersion,
    "a hover that resolves the same shape does not re-publish the keyword",
  );

  // And away again: an arrow that never comes back reads as a stuck cursor.
  ex.glin_web_pointer(0, 0, 460, 340);
  ex.glin_web_frame();
  eq(cursorKeyword(), "default", "leaving the button puts the arrow back");
  check(
    ex.glin_web_cursor_version() !== hoverVersion,
    "leaving the button bumped the version, so the page is told",
  );

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

  // ---- 8b. the GPU geometry path, exercised without a GPU ----
  //
  // A browser with WebGPU or WebGL2 gets a vertex buffer instead of pixels, and
  // Node has neither — which is exactly what makes this the right place to test
  // the ZIG half of that path: `glin_web_gpu_ready(1)` switches the renderer with
  // no device in sight, and the assertions below are the contract `web/gpu.js`
  // consumes. What cannot be checked here is the draw call itself; `web/README.md`
  // is explicit about that gap, and about what would close it.
  eq(ex.glin_web_gpu_kind(), 0, "no page has claimed a GPU backend, so the CPU rasterizer drew every frame so far");
  eq(ex.glin_web_gpu_vertex_stride(), 68, "a vertex is 17 floats: the same layout the Vulkan and Metal backends use");
  eq(ex.glin_web_gpu_segment_stride(), 36, "a segment is 9 int32: start/count, scissor, texture, kind");

  ex.glin_web_gpu_ready(1);
  eq(ex.glin_web_gpu_kind(), 1, "the page claimed WebGPU");
  eq(ex.glin_web_needs_frame(), 1, "switching the backend marks the frame dirty");
  // A hover change, so the frame command digest differs from the last one: the
  // frame memo skips an identical frame, and this test wants a real geometry build.
  ex.glin_web_pointer(0, 0, 120, 300);
  ex.glin_web_frame();

  const gverts = ex.glin_web_gpu_verts_len();
  const gsegs = ex.glin_web_gpu_segs_count();
  const vstride = ex.glin_web_gpu_vertex_stride();
  const sstride = ex.glin_web_gpu_segment_stride();
  check(gverts > 0, "the GPU path built vertices for a real frame", `verts=${gverts}`);
  check(gsegs > 0, "and at least one segment to draw them with", `segs=${gsegs}`);
  eq(gverts % vstride, 0, "the vertex buffer is a whole number of vertices");
  eq(gverts / vstride % 6, 0, "and a whole number of quads (6 vertices each)");
  eq(ex.glin_web_surface_ptr(), 0, "with a GPU there is no CPU surface, so `putImageData` cannot run");
  eq(ex.glin_web_gpu_width(), 600, "the GPU frame is the backing store's width");
  eq(ex.glin_web_gpu_height(), 400, "and its height");
  check(ex.glin_web_gpu_atlas_version() > 0, "text put glyphs in the atlas, so there is something to sample");
  eq(
    ex.glin_web_gpu_atlas_len(),
    ex.glin_web_gpu_atlas_width() * ex.glin_web_gpu_atlas_height(),
    "the atlas is width*height coverage bytes",
  );

  // The segments must cover every vertex exactly once: a gap is a shape the page
  // never draws, and an overlap is a shape drawn twice.
  const segBase = ex.glin_web_gpu_segs_ptr();
  check(segBase !== 0, "the segment buffer has an address");
  const segView = new DataView(ex.memory.buffer, segBase, gsegs * sstride);
  let covered = 0;
  let clipped = 0;
  for (let i = 0; i < gsegs; i++) {
    covered += segView.getInt32(i * sstride + 4, true);
    if (segView.getInt32(i * sstride + 8, true) !== 0) clipped += 1;
  }
  eq(covered, gverts / vstride, "the segments cover every vertex exactly once");
  check(clipped >= 0, "clipped segments are reported, not dropped silently", `${clipped} with a scissor`);

  // ---- 8c. and back to the CPU, which must still work ----
  //
  // This is the fallback a browser WITHOUT either GPU API takes, driven through
  // the same export the page calls. It is the browser's peer of the GDI blit on
  // Windows and the CoreGraphics blit on macOS: the same pixels, no device.
  ex.glin_web_gpu_ready(0);
  eq(ex.glin_web_gpu_kind(), 0, "the page handed the frame back to the CPU rasterizer");
  ex.glin_web_pointer(0, 0, 200, 320);
  ex.glin_web_frame();
  check(ex.glin_web_surface_ptr() !== 0, "the CPU surface is back, so `putImageData` works again");
  check(ex.glin_web_painted_pixels() > 0, "the CPU fallback still paints pixels");
  eq(ex.glin_web_surface_len(), ex.glin_web_surface_width() * ex.glin_web_surface_height() * 4, "and its length matches its size");

  // An unknown backend number is refused rather than trusted: a page cannot
  // switch the renderer to a pipeline that does not exist.
  ex.glin_web_gpu_ready(9);
  eq(ex.glin_web_gpu_kind(), 0, "an out-of-range backend id falls back to the CPU rasterizer");

  // ---- 9. shutdown is safe and idempotent-ish ----
  ex.glin_web_shutdown();
  ex.glin_web_shutdown();
  eq(ex.glin_web_needs_frame(), 0, "a shut-down window wants no frames");

  // ---- 10. every app `zig build web` installs ----
  //
  // ONE wasm module per app, from one library and one page: `?app=<id>` picks the
  // file. Booting each here is the browser's half of "the examples all still
  // work": a module that traps on init, logs an error or paints nothing fails the
  // run, and the frame hash proves the picture is not a flat clear.
  //
  // The size is the window each app's native `main.zig` opens with. A browser gets
  // its size from the canvas, so these are just sane boxes for the assertions.
  const apps = [
    { id: "calculator", file: "glinlandui-calculator.wasm", w: 360, h: 430 },
    { id: "todo", file: "glinlandui-todo.wasm", w: 720, h: 640 },
    { id: "catalog", file: "glinlandui-catalog.wasm", w: 960, h: 760 },
    { id: "file-dialog", file: "glinlandui-file-dialog.wasm", w: 520, h: 300 },
    { id: "lazy-scroll", file: "glinlandui-lazy-scroll.wasm", w: 900, h: 640 },
  ];

  for (const app of apps) {
    const path = join(root, "zig-out", "web", app.file);
    let bytes = null;
    try {
      bytes = await readFile(path);
    } catch {
      console.log(`\n  note  ${app.id} was not built; run \`zig build web\``);
      continue;
    }

    console.log(`\n  --- ${app.id} ---`);
    const m = await WebAssembly.compile(bytes);
    check(
      WebAssembly.Module.imports(m).length === 0,
      `${app.id}: dependency-free like the demo module`,
      WebAssembly.Module.imports(m).map((i) => `${i.module}.${i.name}`).join(", "),
    );

    const ex = await WebAssembly.instantiate(m, {}).then((i) => i.exports);
    eq(ex.glin_web_init(app.w, app.h, 240, 180), 1, `${app.id}: initialises`);
    eq(ex.glin_web_run(), 1, `${app.id}: arms its loop`);
    ex.glin_web_frame();
    check(ex.glin_web_painted_pixels() > 0, `${app.id}: painted pixels`, `painted=${ex.glin_web_painted_pixels()}`);
    check((ex.glin_web_frame_hash() >>> 0) !== 0, `${app.id}: the frame is not a flat clear`);
    eq(ex.glin_web_log_errors(), 0, `${app.id}: logged no errors`);
    eq(ex.glin_web_font_error(), 0, `${app.id}: the embedded font installed`);

    // The same module must also accept a GPU frame: `?gpu=webgl` switches the
    // renderer for every app, not only for the demo.
    ex.glin_web_gpu_ready(2);
    ex.glin_web_pointer(0, 0, app.w >> 1, app.h >> 1);
    ex.glin_web_frame();
    check(ex.glin_web_gpu_verts_len() > 0, `${app.id}: builds GPU geometry too`, `verts=${ex.glin_web_gpu_verts_len()}`);
    check(ex.glin_web_gpu_segs_count() > 0, `${app.id}: with at least one segment`);
    eq(ex.glin_web_log_errors(), 0, `${app.id}: the GPU frame logged no errors`);

    // Images: `build.zig` embeds an app's `assets/` directory and the ENGINE decodes it, so a page draws
    // what a desktop window draws. The catalog is the app that has them, and its three live near the BOTTOM
    // of the docs page. The browser backend turns Clay's culling OFF (the text mirror needs the whole page,
    // see `src/web/shim.h`), so they decode at boot instead of when they are scrolled into view: the wheels
    // below only prove the page still scrolls, not that a texture waits for its first pixels.
    if (app.id === "catalog") {
      eq(ex.glin_web_gpu_image_count(), 3, "catalog: all three assets decode, because the whole page is in the frame");
      const imgW = ex.glin_web_gpu_image_width(0);
      const imgH = ex.glin_web_gpu_image_height(0);
      check(imgW > 0 && imgH > 0, "catalog: the first image has a size", `${imgW}x${imgH}`);
      eq(ex.glin_web_gpu_image_len(0), imgW * imgH * 4, "catalog: and RGBA8 bytes to match");
      check(ex.glin_web_gpu_image_id(0) > 0, "catalog: with an id a segment can name");
      eq(ex.glin_web_gpu_image_id(3), 0, "catalog: an out-of-range index answers 0, not a trap");
      // The pointer sits in the middle of the page, and a wheel walks it down.
      ex.glin_web_pointer(0, 0, app.w >> 1, app.h >> 1);
      ex.glin_web_wheel(0, 60, 0);
      eq(ex.glin_web_needs_frame(), 1, "catalog: a wheel over the page marks the frame dirty");
      ex.glin_web_frame();
      ex.glin_web_gpu_ready(0);
      ex.glin_web_frame();
      check(ex.glin_web_surface_ptr() !== 0, "catalog: and the CPU path still presents it");
      // Back to the size this app was booted at; the sections below are the calculator's.
      ex.glin_web_resize(app.w, app.h);
      ex.glin_web_frame();
    } else {
      eq(ex.glin_web_gpu_image_count(), 0, `${app.id}: no assets embedded, so no image textures`);
    }

    // The text mirror: a browser finds text in the DOM, and a canvas has none, so
    // the page's find-in-page read `0/0` over a screen full of words. Every run
    // the frame drew is exported for the page to mirror, and the page scroller's
    // offset travels with it so find can land on a match below the fold.
    ex.glin_web_frame();
    const runs = textRuns(ex);
    check(runs.length > 0, `${app.id}: the frame's text runs are exported for the page's find`, `runs=${runs.length}`);
    check(
      runs.every((r) => r.w > 0 && r.h > 0 && r.text.length > 0),
      `${app.id}: every run has a box and text`,
    );

    if (app.id === "catalog") {
      const findable = (needle) => runs.filter((r) => r.text.toLowerCase().includes(needle)).length;
      check(findable("text field") > 0, `catalog: the page's own words are findable`, `"text field" in ${findable("text field")} run(s)`);
      const reach = ex.glin_web_text_page_max();
      check(reach > 0, `catalog: the page reports how far it scrolls`, `reach=${reach}`);
      // Let the app settle first: a wheel's coast keeps scrolling for a few frames after the burst, and
      // what is asserted below is the jump, not the gesture that preceded it.
      for (let i = 0; i < 60 && ex.glin_web_needs_frame() === 1; i++) ex.glin_web_frame();
      const target = Math.min(reach, 240);
      ex.glin_web_find_scroll(target);
      ex.glin_web_frame();
      check(
        Math.abs(ex.glin_web_text_page_offset() - target) < 1,
        `catalog: find scrolling the mirror scrolls the app's page`,
        `asked ${target}, offset is ${ex.glin_web_text_page_offset()}`,
      );
    }
    ex.glin_web_gpu_ready(0);
    ex.glin_web_frame();
    check(ex.glin_web_surface_ptr() !== 0, `${app.id}: and falls back to the CPU surface`);

    if (app.id === "catalog") {
      ex.glin_web_pointer(0, 0, app.w >> 1, app.h >> 1);
      const atTop = () => {
        for (let i = 0; i < 200; i++) ex.glin_web_wheel(0, -200, 0);
        ex.glin_web_frame();
        return ex.glin_web_frame_hash() >>> 0;
      };
      const top = atTop();

      ex.glin_web_wheel(0, 60, 0);
      eq(ex.glin_web_needs_frame(), 1, "catalog: a wheel delta wants a frame");
      ex.glin_web_frame();
      const oneEvent = ex.glin_web_frame_hash() >>> 0;
      check(oneEvent !== top, "catalog: and the content moved", `0x${top.toString(16)} -> 0x${oneEvent.toString(16)}`);
      eq(atTop(), top, "catalog: wheeled back up it is exactly where it started");

      for (let i = 0; i < 6; i++) ex.glin_web_wheel(0, 10, 0);
      eq(ex.glin_web_needs_frame(), 1, "catalog: six wheel events between two frames still want ONE frame");
      ex.glin_web_frame();
      const burst = ex.glin_web_frame_hash() >>> 0;
      eq(burst, oneEvent, "catalog: the same total travel lands in the same place as one event of it");
      // ---- one detent is an IMPULSE, not a flick ----
      // A mouse wheel delivers ONE whole notch as ONE event, and the next only when the hand turns the wheel again.
      // Windows sends exactly this shape — a single `WM_MOUSEWHEEL` worth 60 pt — so there is no velocity in it to hand
      // over and nothing may move after it. The coast used to invent 784 pt more on the frames that followed.
      const still = atTop();
      // Let any earlier gesture fall out of the engine's own window first: a lone event has to actually be alone.
      for (let i = 0; i < 200; i++) ex.glin_web_frame();
      ex.glin_web_wheel(0, 60, 0);
      ex.glin_web_frame();
      const notched = ex.glin_web_frame_hash() >>> 0;
      check(notched !== still, "catalog: the notch moved the list");
      let crept = 0;
      for (let i = 0; i < 200; i++) {
        ex.glin_web_frame();
        if ((ex.glin_web_frame_hash() >>> 0) !== notched) crept += 1;
      }
      eq(crept, 0, "catalog: one frame of wheel is an impulse, so no frame after it moves the list");

      // ---- momentum: the flick keeps going after the fingers leave ----
      // A trackpad on a host that animates no flick of its own sends wheel events only while the fingers move, in a
      // RUN of frames, and the engine owes the coast after the last one: frames must keep arriving and keep moving.
      const reset = atTop();
      let previous = reset;
      for (let i = 0; i < 4; i++) {
        for (let j = 0; j < 3; j++) ex.glin_web_wheel(0, 20, 0);
        ex.glin_web_frame();
        previous = ex.glin_web_frame_hash() >>> 0;
      }
      const released = previous;
      check(released !== reset, "catalog: the flick moved the list");
      let coasted = 0;
      let frames = 0;
      while (frames < 400) {
        if (ex.glin_web_needs_frame() !== 1) break;
        ex.glin_web_frame();
        frames += 1;
        const h = ex.glin_web_frame_hash() >>> 0;
        if (h !== previous) coasted += 1;
        previous = h;
      }
      check(frames >= 4, "catalog: the coast asks for frames no event will carry", `${frames} frame(s)`);
      check(coasted >= 3, "catalog: and it moves the list after the last wheel event", `${coasted} changed frame(s)`);
      eq(ex.glin_web_needs_frame(), 0, "catalog: until the flick is spent and the page is still");
    }

    // The catalog is the app that PERSISTS: a nav click is an intent, an intent stages the document,
    // and the page is what stores it. Walking down the nav finds a row without hard-coding a layout,
    // and the bytes are checked as the versioned JSON the module encodes — which is the only half
    // `node` can see, because the database itself lives in the page.
    if (app.id === "catalog") {
      let staged = 0;
      for (let y = 120; y < 460 && staged === 0; y += 18) {
        ex.glin_web_pointer(1, 0, 100, y);
        ex.glin_web_pointer(2, 0, 100, y);
        ex.glin_web_frame();
        staged = ex.glin_web_store_dirty();
      }
      eq(staged, 1, "catalog: a nav click stages the document the page stores");
      const stagedLen = ex.glin_web_store_len();
      check(stagedLen > 0, "catalog: and it has bytes", `${stagedLen} bytes`);
      const stagedText = new TextDecoder().decode(
        new Uint8Array(ex.memory.buffer, ex.glin_web_store_ptr(), stagedLen),
      );
      check(
        stagedText.startsWith('{"v":2'),
        "catalog: the document is the versioned JSON the module encodes",
        stagedText.slice(0, 60),
      );
      check(
        stagedText.includes('"recent"'),
        "catalog: naming the section the click opened",
        stagedText.slice(0, 160),
      );
      ex.glin_web_store_clean();
      eq(ex.glin_web_store_dirty(), 0, "catalog: and cleaning it clears the debt");
      eq(ex.glin_web_log_errors(), 0, "catalog: staging logged no errors");
    }

    if (app.id !== "calculator") continue;

    // The calculator's keyboard path, end to end: `src/web/keymap.zig` translates
    // `"NumpadAdd"` to evdev 78, and the app's own `onKey` maps 78 to `plus`.
    // Driving it here proves DOM-shaped code string → keymap → KeyChain → handler
    // → re-render, without a browser.
    const cx = ex;
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

    // ZOOM. A page reports the canvas BACKING STORE (CSS x devicePixelRatio) while the toolkit lays out
    // in CSS pixels, so at 2x the same physical key arrives at twice the coordinate. Both must press it:
    // before the fix only the 1x click did, which is the "it only works at 100%" report.
    cx.glin_web_resize(720, 860);
    cx.glin_web_scale(2);
    cx.glin_web_frame();
    const beforeZoomClick = cx.glin_web_frame_hash() >>> 0;
    cx.glin_web_pointer(1, 0, 2 * 40, 2 * 200);
    cx.glin_web_pointer(2, 0, 2 * 40, 2 * 200);
    cx.glin_web_frame();
    check(
      (cx.glin_web_frame_hash() >>> 0) !== beforeZoomClick,
      "a click at 2x device scale presses the key the user aimed at",
      `0x${beforeZoomClick.toString(16)} -> 0x${(cx.glin_web_frame_hash() >>> 0).toString(16)}`,
    );
    cx.glin_web_scale(1);
    cx.glin_web_resize(360, 430);
    cx.glin_web_frame();
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
