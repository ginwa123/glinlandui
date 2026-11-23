# `glinlandui/web` — the browser side

This directory is the **static half** of the browser backend: the files
`zig build web` installs into `zig-out/web/` next to the compiled module. It is
deliberately not part of `src/`, which holds only code that is compiled.

```
web/
├── index.html   the page: one full-bleed <canvas> and nothing in the way
├── shim.js      the browser shim — the peer of mac/shim.m
├── gpu.js       the GPU backends: WebGPU first, WebGL2 second, `null` third
├── parity.html  CPU vs GPU pixel diff, in a browser (a developer page)
├── style.css    the canvas sizing contract, the top-edge app menu, the failure panel
└── smoke.mjs    the off-browser verification (run by CI, not by the page)
```

`assets/font.ttf` is optional and not committed: see "The font" below.

## Run it

```sh
zig build web        # wasm module + these assets -> zig-out/web/
zig build serve      # python3 -m http.server 8080 --directory zig-out/web
```

then open <http://localhost:8080>. A **served** origin is required: a `file://`
page cannot `fetch` a WebAssembly module, and `shim.js` says so explicitly rather
than failing with a bare network error.

`zig build serve` uses `python3` and not npm on purpose. The entire point of this
backend is that it needs no JavaScript toolchain, so the development server should
not introduce one.

## The division of labour, which is the whole design

**`shim.js` makes no decisions.** Every translation lives in pure Zig under
`src/web/`, and every one of those modules is in the cross-platform test suite, so
it is checked on Linux and macOS as well as here:

| what | where |
|---|---|
| `KeyboardEvent.code` → evdev | `src/web/keymap.zig` |
| `MouseEvent.button` → evdev | `src/web/input.zig` |
| `deltaMode` + deltas → pixel scroll | `src/web/adapter.zig` |
| CSS pixels → backing-store pixels | `src/web/present.zig` |
| resize storms → one resize per frame | `src/web/adapter.zig` |
| RGBA8 → `ImageData` | `src/web/present.zig` (the identity) |
| the dirty flag / idle-CPU decision | `src/web/window.zig` |
| Clay commands → vertices + segments | `src/web/gpu.zig` |
| the glyph atlas: packing and version | `src/web/gpu.zig` |
| which renderer draws a frame | `src/web/renderer.zig` |

`src/web/shim.h` is the ABI both sides agree on, and `smoke.mjs` cross-checks it
against the module's real exports in both directions — a header that has drifted
from the code is worse than no header.

The two things `shim.js` *does* own are the two it cannot delegate:

1. **`requestAnimationFrame`.** The toolkit cannot own an event loop in a browser,
   so the page runs one and asks `glin_web_needs_frame()` first. An idle UI costs
   one integer read per animation frame: no layout, no rasterization, no pixel
   copy. (This is the atomic "skip the clear, the draw and the present together"
   that `core/frame.zig`'s frame-memo note says the Wayland loop could not do.)
   Most input handlers also draw immediately, because a click is two events and
   waiting a refresh for each is 33 ms of nothing. **The wheel is the exception
   and must stay one:** a trackpad delivers several wheel events per display
   refresh and a non-passive wheel listener is not coalesced by the browser, so
   drawing inside that handler rasterizes and presents two or three whole
   surfaces for one displayed frame, off vsync, of which only the last is ever
   seen. Measured on a 2880x1800 canvas at three events per refresh: 90 events
   cost 90 frames and 90 presents where 30 were displayed, and 93% of the main
   thread. The wheel handler therefore only tells the toolkit, the animation
   frame draws once with whatever the burst accumulated, and the content lands
   in exactly the same place (`smoke.mjs` pins that: the same total travel in one
   event or six ends at the same pixel). A desktop backend already behaves this
   way — `mac/window.zig` marks the frame dirty and invalidates, and AppKit
   repaints at the next display refresh.
2. **Rebuilding its view over wasm memory.** `memory.grow()` detaches every
   `TypedArray` view over the old buffer, and a frame can grow the heap at any
   moment. `blit()` therefore rebuilds when the buffer *identity* or the surface
   *pointer* changes, and never caches on the assumption that it will not. Getting
   this wrong gives a UI that renders correctly and then presents as blank,
   intermittently — the failure mode `src/web/present.zig` documents from the Zig
   side.

## The page is the window

A desktop build opens a window and the app fills it. The page does the same: the
canvas is fixed to the viewport, the toolkit lays out at that size, and there is
no heading, no lede, no footer and no visible status text — `web/index.html` is a
canvas, a screen-reader status line, and a `<noscript>`.

A fixed-size screen reads better at its own size, so `?w=360&h=430` pins the
canvas to that size and centres it with a window edge — the calculator at 360x430
on a 1440x900 desktop, rather than maximised. Every app's desktop size is in the
table below.

Three things the page still owns, none of them in the way:

- **The app menu**, a 5px strip at the top edge that expands into a menu bar on
  hover or keyboard focus (`#apps`, filled by `shim.js` from its `APPS` list).
  Hidden, it covers nothing anyone is aiming at.
- **The status line**, `role="status"` and visually hidden: it is what a screen
  reader hears and what CI-side tooling can read, not chrome.
- **The failure panel**, created only when something goes wrong. A page that
  works has no overlay at all; a page that cannot fetch the module says so in one
  visible line instead of a blank window.

## The apps

`zig build web` installs one wasm module per app, and `?app=<id>` picks it — one
library, six entry points, one page:

| `?app=` | module | desktop size | what it is |
|---|---|---|---|
| `demo` (default) | `glinlandui.wasm` | 480x360 | the demo: click, toggle, slider, file dialog |
| `calculator` | `glinlandui-calculator.wasm` | 360x430 | the keypad example, with a working keyboard |
| `todo` | `glinlandui-todo.wasm` | 720x640 | MVVM: state, ViewModel, view |
| `catalog` | `glinlandui-catalog.wasm` | 960x760 | every component on one scrolling screen |
| `file-dialog` | `glinlandui-file-dialog.wasm` | 520x300 | the dialog API. A browser has no filesystem, so it shows the portable stub's "unsupported" answer — the app runs, its SUBJECT cannot |
| `lazy-scroll` | `glinlandui-lazy-scroll.wasm` | 900x640 | 10,000 virtualised rows |

Add `&w=<px>&h=<px>` to any of those URLs to open the app at its desktop size
instead of maximised: `?app=calculator&w=360&h=430`.

```sh
zig build -Dweb run-todo        # build all modules, serve, print the URL
zig build -Dweb run-catalog
```

`web/smoke.mjs` boots **every** module (init, run, one frame, painted pixels, no
log errors, the font installed, then a GPU frame and a fall back to the CPU), so
"the examples run in a browser" is a gate rather than a claim. The one thing the
page cannot do is the file dialog's actual job, and the example says so on
screen.

The face is the **library's**, not an app's: `build.zig`'s `-Dfont` compiles the
TTF into the `font_data` module, `src/web/exports.zig` installs it from
`glin_web_init`, and no application — native or browser — declares a typeface.

### Images

An app names a path — `image(.{ .path = "examples/catalog/assets/disc.png" })` —
and that does not change for the browser. `build.zig` embeds the app's `assets/`
directory into a generated `asset_data` module, the app's `web.zig` hands it to
the engine (`ExportsWithAssets`), and `core/image_store.zig` serves those bytes to
the same decoder the desktop build uses for a file. The CPU path blits the
decoded pixels; the GPU path uploads them as textures and names them in
`kind == 2` segments.

An app with no `assets/` directory carries none of this, so nothing is paid for
it. `web/smoke.mjs` checks both halves: the catalog decodes exactly three images
once a window is tall enough to show them, and every other module reports zero.

### Zoom and display density

A browser reports pointer positions in the canvas **backing store** (CSS pixels ×
`devicePixelRatio`) while the toolkit lays out in CSS pixels — so `src/web/input.zig`'s
`toLayout` divides the display scale back out before a hit test sees the point. That
conversion is the browser's alone: Wayland and AppKit already report logical points.

It was missing once, and the symptom was "the components are dead unless the zoom is
100%": at 200% every click landed twice as far from the top-left, at 80% it landed
short. Three unit tests pin it now (2x, 1.25x, a nonsense scale), plus an end-to-end
Clay hit test at 2x and a `web/smoke.mjs` check that clicks a keypad at 2x scale.

Zooming also changes `devicePixelRatio` **without** necessarily resizing the CSS box
(a pinned `?w=&h=` canvas is a fixed box by definition), so `shim.js` watches
`matchMedia("(resolution: Ndppx)")` and re-arms it on every change: `resize` alone
misses a zoom on a fixed-size canvas.

## Persistence: IndexedDB, and why the page owns it

An app's settings have to survive a reload, and in a browser the only durable,
per-origin, structured store is IndexedDB. It is also **asynchronous** and
**page-only**, while the module imports nothing and every export is synchronous —
so the two sides exchange BYTES and nothing else:

    Zig   src/core/storage.zig          the document: bounded key/value pairs, a version, a migration
    Zig   src/web/storage.zig           the slot those bytes sit in, in wasm memory
    JS    web/store.js                  the database: open, load one string, save one string
    JS    web/shim.js                   the three calls that move a string across

The split matters because it keeps the decisions on the testable side. The key
names, the version number, what a setting means, and how an older payload is
migrated all live in `src/core/storage.zig`, which is in the cross-platform
parity suite and has no idea a browser exists. `web/store.js` moves one string
and makes no choices at all — the same rule `gpu.js` and `shim.js` keep.

The loop, per app:

- **boot.** The page reads `indexedDB` → `glinlandui` → store `state`, keyed by
  `?app=`. The string is written into `glin_web_store_scratch()` and handed to
  `glin_web_store_adopt(ptr, len)`, which requests a frame — the load lands
  between frames and the loop is idle by default. The app applies the document
  before it draws, so a reload paints the restored screen once instead of
  flashing the default one.
- **change.** An intent marks the app's document dirty; the next frame re-encodes
  it and stages the bytes, and `glin_web_store_dirty()` says a write is owed.
- **write.** The page reads `glin_web_store_ptr()` / `_len`, decodes them into a
  JS string, calls `glin_web_store_clean()`, and persists the string DEBOUNCED
  (250 ms) — a slider drag is one write, not one per pixel.

`glin_web_store_revision()` mirrors the router's generation: it moves on every
document the page hands back, so the page can tell "I already answered this one"
without comparing bytes.

**Absent is a supported state.** `indexedDB` is undefined in Node (where
`web/smoke.mjs` runs), in an insecure context, and in some private-browsing
modes. `createStore` reports `available: false` and every method resolves rather
than throwing, so the page skips the dance and the app runs with defaults. An app
that loses its settings is a disappointment; a page that fails to boot because a
database was missing is a bug.

`examples/catalog/` is the app that uses it: the compact/roomy theme, the address,
the picked tab/tree row/radio/slider/checkbox/toggle and a bounded "recently
viewed" list are all in its document, and the nav draws the recent list from it.

## The hover cursor

A native backend answers the OS with a cursor SHAPE — `glin_cocoa_set_cursor`,
`glin_win_set_cursor`, and `wp_cursor_shape_manager_v1` on Wayland — and macOS and
Windows have done it since the first component registered one. A browser has no
such call: the pointer over a `<canvas>` is a stylesheet question, so the same
shape has to arrive as a CSS `cursor` keyword. It did not, for a long time, and
the symptom was that every click, toggle and slider worked while the pointer
stayed an arrow — a page that is interactive read as a picture.

The choice is still made in Zig. What is under the pointer comes from
`core/frame.zig`'s `hoverCursorShape` — the same function the native backends
answer their OS with, resolving the same click registry — and
`src/web/adapter.zig`'s `cursorCss` maps the shape to its keyword (`pointer`,
`text`, `ew-resize`, `ns-resize`, `default`). `src/web/window.zig` adopts it after
every frame through `adapter.CursorState`, which moves a version only when the
shape actually changed, and three exports carry it out:

- `glin_web_cursor_ptr` / `_len` — the keyword, as bytes in wasm memory;
- `glin_web_cursor_version` — bumped only when that keyword changed.

`web/shim.js`'s `applyCursor()` compares the version, decodes the bytes and
assigns `canvas.style.cursor`, before either renderer path draws. The page
decides nothing: a `cursor: pointer` rule written in JS would be a second,
untested opinion about what is clickable, and it would be wrong the first time a
component registered an I-beam or a resize arrow instead.

The version gate is what keeps it cheap. A pointer resting on a button is 60
frames of one integer read, not 60 DOM writes, which is why the check belongs in
the frame path rather than in a `pointermove` handler.

`web/smoke.mjs` pins the chain without a browser: the module publishes `pointer`
over the demo's button, publishes it ONCE however many frames are drawn on it,
and puts `default` back when the pointer leaves. Those assertions were red before
the exports existed — and stay red if the frame stops adopting the shape, which
is the mutation that proves the gate can fail.

## The renderer ladder: WebGPU, else WebGL2, else the CPU

The browser target renders with the best backend the page can create:

| order | renderer | where the geometry comes from | what the page does |
|---|---|---|---|
| 1 | **WebGPU** (WGSL) | `src/web/gpu.zig` | uploads the vertex buffer, binds the atlas, one render pass |
| 2 | **WebGL2** (GLSL ES 300) | the same buffer, byte for byte | `drawArrays` per segment, scissor per segment |
| 3 | **CPU rasterizer** | `core/render_software.zig` | `putImageData` of the RGBA8 surface |

The ladder is not a performance hint: it is the browser's copy of the native
fallbacks. macOS tries Metal and drops to the CPU rasterizer plus a CoreGraphics
blit; Windows tries D3D11 and drops to GDI. Here the toolkit asks
`glin_web_gpu_ready(kind)` — 1 WebGPU, 2 WebGL2, 0 none — and a browser with
neither API keeps exactly the behaviour it had before the GPU path existed.

**The order lives in `web/gpu.js`, and it has to.** A canvas hands out ONE kind of
context for its lifetime, so `getContext("2d")` first would make WebGL2 and WebGPU
impossible afterwards; `shim.js` therefore asks for the GPU *before* the 2d
context, and only falls through to `2d` when both GPU APIs said no. Everything
else is still Zig: the vertex/segment buffers, the clipping, the text baseline,
the atlas packing and the frame size all come out of `src/web/gpu.zig`, which is
the same code as `src/mac/renderer.zig` with the API calls removed.

`?gpu=off`, `?gpu=webgl` and `?gpu=webgpu` force one rung, which is how the three
paths are compared on one machine — and how the CPU fallback is proven to still
work in a browser that has a GPU.

### What the page is given, per frame

`src/web/shim.h` documents the ABI; the short version is that the page reads

- `glin_web_gpu_verts_ptr/_len` — 17-float vertices, 68 bytes each;
- `glin_web_gpu_segs_ptr/_count` — 9 int32 per segment: `start`, `count`, a
  scissor, a texture id and a kind (0 rect, 1 text, 2 image);
- `glin_web_gpu_atlas_ptr/_version` — 1024x1024 8-bit coverage, re-uploaded when
  the version changes;
- `glin_web_gpu_width/_height` and `glin_web_gpu_clear_rgba`.

`glin_web_gpu_vertex_stride()` and `_segment_stride()` exist so the page never
hardcodes a layout: `web/gpu.js` asserts them against 68/36 and throws if the Zig
side ever changes shape, which turns a silent mis-draw into a message.

## Verifying it without a browser

```sh
zig build web && node web/smoke.mjs
```

That run also covers the Zig half of the GPU path: `glin_web_gpu_ready(1)`
switches the renderer with no device in sight, and the smoke test asserts the
vertex buffer, the segment coverage, the atlas and the frame size, then switches
back to the CPU and asserts the surface returns. What Node cannot cover is the
draw call itself.

`smoke.mjs` drives the module through `src/web/shim.h` in Node and exits non-zero
on failure. It is the browser's peer of `ci/check_macos_colors.sh`: the canvas, the
DOM and `requestAnimationFrame` are unreachable from a Zig test, and this is the
check that covers the gap. See its header for the assertion list and for what it
deliberately does **not** assert (an exact frame checksum shared with the native
builds — floating point is not bit-identical across targets, and the rasterizer's
1px antialias band is `f32`-sensitive).

## The font

A browser has no font paths, so `src/web/text.zig` reports an empty candidate list
on purpose and the toolkit will draw its documented **glyph-free per-byte bars**
unless a font is handed to it as bytes:

```sh
mkdir -p web/assets
cp /usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf web/assets/font.ttf
```

`shim.js` fetches `assets/font.ttf` if it exists, copies it into wasm memory, and
calls `glin_web_font`. A missing font is **not an error** — the page reports it and
keeps drawing. A *present but unparseable* font is also not an error: it is refused
and freed, which is what `glyphs.sfntSignatureRecognized` exists for. The bytes
must be a plain `.ttf`/`.otf`, **not** a `.ttc` collection, which
`stbtt_InitFont` cannot load.

No font is committed to this repository, so nothing here depends on a specific
one. `@embedFile`-ing a font into the module is a possible later option, at the
cost of the font's size in every download.

## Keyboard behaviour worth knowing

The keymap is keyed by `KeyboardEvent.code` — the **physical** key at its
US-layout position — because that is the same abstraction evdev uses. The
consequence is that an AZERTY user types US characters, which is **exactly what
Linux/Wayland does today** (Wayland also speaks evdev). It is a documented
limitation shared with the native backend, not a new one; fixing it means an
`event.key`/composition text-input path, which is shared work with Linux.

`shim.js` calls `preventDefault` only when the toolkit reports that it *consumed*
the key — which is the app's answer, decided in Zig by `components.input`. That
keeps Tab, Space and the arrows working for the toolkit's own text fields while
still letting them scroll or move focus when nothing wants them, and it keeps the
decision out of the one file here that has no tests.

## Verifying it IN a browser, pixel for pixel

```
zig build web && zig build serve        # http://localhost:8080/parity.html
```

`web/parity.html` is the browser's peer of `golden_test.zig`: it instantiates the
module twice, renders one frame with the CPU rasterizer and the same frame with
whatever GPU backend the browser gives it, reads the GPU result back through a
2d canvas and prints the difference. The toolkit's standard is 1/255.

Measured on the machine this landed on (Firefox, WebGL2 over llvmpipe, 480x360):

```
CPU  480x360, 691200 bytes, 172800 painted, 0 error(s)
GPU  WebGL2 (kind 2)
     480x360, 606 vertices, 6 segment(s), atlas v1 (1048576 bytes)
     draw returned true
DIFF 172800 pixels: mean |d| 0.00/255, max 1, 0.00% over 8, 0.00% over 32
```

The same page picks WebGPU when the browser has it; that is the only way to
exercise the WGSL path, and a browser without WebGPU (Firefox on Linux today)
reports WebGL2 instead.

Two things about headless verification, both learned the hard way:

- **A `firefox --headless --screenshot` of a WebGL canvas is blank**, even when
  the frame is correct — the compositor's GL layer is not captured. Read the
  pixels back (`drawImage` into a 2d canvas, then `getImageData`) and print the
  numbers; that is what `parity.html` does.
- **A screenshot fires on `load`, before an async wasm fetch finishes.** If you
  script a screenshot, delay the load event (a slow `<img>`) or you will capture
  the page before its first frame.
