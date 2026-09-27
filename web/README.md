# `glinlandui/web` — the browser side

This directory is the **static half** of the browser backend: the files
`zig build web` installs into `zig-out/web/` next to the compiled module. It is
deliberately not part of `src/`, which holds only code that is compiled.

```
web/
├── index.html   the page: one <canvas>, a status line, a <noscript>
├── shim.js      the browser shim — the peer of mac/shim.m
├── style.css    page chrome + the canvas sizing contract
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

`src/web/shim.h` is the ABI both sides agree on, and `smoke.mjs` cross-checks it
against the module's real exports in both directions — a header that has drifted
from the code is worse than no header.

The two things `shim.js` *does* own are the two it cannot delegate:

1. **`requestAnimationFrame`.** The toolkit cannot own an event loop in a browser,
   so the page runs one and asks `glin_web_needs_frame()` first. An idle UI costs
   one integer read per animation frame: no layout, no rasterization, no pixel
   copy. (This is the atomic "skip the clear, the draw and the present together"
   that `core/frame.zig`'s frame-memo note says the Wayland loop could not do.)
2. **Rebuilding its view over wasm memory.** `memory.grow()` detaches every
   `TypedArray` view over the old buffer, and a frame can grow the heap at any
   moment. `blit()` therefore rebuilds when the buffer *identity* or the surface
   *pointer* changes, and never caches on the assumption that it will not. Getting
   this wrong gives a UI that renders correctly and then presents as blank,
   intermittently — the failure mode `src/web/present.zig` documents from the Zig
   side.

## Verifying it without a browser

```sh
zig build web && node web/smoke.mjs
```

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
