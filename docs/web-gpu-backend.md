# Browser renderer: WebGPU → WebGL2 → CPU

Status: **landed.** The browser target draws on the GPU when the page can create
one; this document is the design record.

## Goal

The browser backend was the CPU rasterizer and nothing else: `src/web/renderer.zig`
was five lines re-exporting `core/render_software.zig`, and `web/shim.js` copied
that surface into a `2d` canvas with `putImageData`. A full-window `putImageData`
of a 2x canvas is ~20 MB per frame plus a scalar raster of every pixel, which is
the cost the native backends stopped paying years ago.

Done means:

- the browser picks **WebGPU**, else **WebGL2**, else the existing **CPU**
  rasterizer, in that order;
- the GPU path draws the same geometry contract as `src/linux/renderer.zig`
  (Vulkan) and `src/mac/renderer.zig` (Metal) — 17-float vertices, per-segment
  draws, rect/text pipelines, one atlas, scissor clipping;
- `zig build web` and `node web/smoke.mjs` stay green, and the CPU fallback still
  presents real pixels;
- no GPU code path can break the CPU one: a page that creates neither context
  gets exactly the renderer the toolkit had before.

## As built

| file | what it is |
|---|---|
| `src/web/gpu.zig` | geometry: vertices, segments, clip arithmetic, the glyph atlas, the frame size. The port of `mac/renderer.zig` with the API calls removed — every decision stays here |
| `src/web/renderer.zig` | the dispatcher: GPU when the page said so, `core/render_software.zig` otherwise |
| `web/gpu.js` | the two GPU backends — `createWebGPU` (WGSL) and `createWebGL2` (GLSL ES 300) — plus `createBackend`, which tries them in order and returns `null` |
| `web/shim.js` | asks for a GPU context BEFORE `getContext("2d")`, tells the module which one it got, and presents either buffer |
| `web/parity.html` | CPU vs GPU in one browser, diffed per pixel |
| `examples/<name>/web.zig` | the browser entry per app: the ABI, the freestanding runtime, the log sink. The native `main.zig` is untouched, and no app declares a font |
| `src/web/shim.h` | the ABI: `glin_web_gpu_ready`, and the buffer accessors the page reads |

### The ABI, and why it points this way

The module is built for `wasm32-freestanding` and **imports nothing** —
`WebAssembly.Module.imports()` must stay empty, which `web/smoke.mjs` asserts.
That rules out `extern` functions Zig could call, so the GPU calls run from JS and
the geometry crosses the boundary as two buffers:

- `glin_web_gpu_verts_ptr/_len` — 68-byte vertices (`pos`, `local`, `size`,
  `radius`, `color`, `mode`, `border`, `kind`);
- `glin_web_gpu_segs_ptr/_count` — 36-byte segments (`start`, `count`,
  `has_scissor`, `sx/sy/sw/sh`, `texture_id`, `kind`);
- `glin_web_gpu_atlas_ptr/_version` — 1024x1024 8-bit coverage;
- `glin_web_gpu_width/_height`, `glin_web_gpu_clear_rgba`, and the two stride
  accessors that keep the page from hardcoding either layout.

`glin_web_gpu_ready(0|1|2)` is the page's answer, and `0` is a supported browser
rather than a failure: the toolkit then rasterizes on the CPU as it always did.

### The shaders

One vertex shader, one fragment shader per pipeline, ported from
`src/linux/shaders/*`:

- **rect**: the rounded-box SDF in device pixels, `mode > 0.5` punching the
  interior out for a border outline;
- **text**: the 8-bit atlas sampled on `.r`, tinted with the vertex colour.

Both APIs differ from Vulkan in exactly two places, and both are stated here
because a reader porting between them needs to know:

- Vulkan's clip space has +y **down**, so `quad.vert` needs no flip. WebGPU and
  WebGL put +y up, so both shaders here compute `1 - y/res*2`.
- A WebGL scissor rectangle is measured from the **bottom** of the framebuffer
  while Clay's is measured from the top, so the GL backend converts it
  (`h - (y + h)`); WebGPU's `setScissorRect` is top-left like Vulkan's.

Blending is straight-alpha over in all three (`SRC_ALPHA`,
`ONE_MINUS_SRC_ALPHA`), and the clear colour comes from
`soft.currentClearColor()` — the same value the CPU path clears with, so a themed
background cannot drift between backends.

### Images

A page has no filesystem, so an `.image` command used to draw the documented
placeholder in every browser. It now draws the real picture, through the
engine — the app still just names a path:

| step | where |
|---|---|
| embed the app's `assets/` directory as source | `build.zig`'s `makeAssetsModule` → the generated `asset_data` module |
| register those bytes under the path the app declared | `core/image_store.zig`, called from `glin_web_init` through `ExportsWithAssets` |
| decode them | `render_software.decodeImageBytes` — the SAME `stb_image` decoder, downscale and memory order as the disk path, so the two cannot disagree |
| draw them | CPU: the normal blit. GPU: `src/web/gpu.zig` decodes once per (path, max_dim), gives the image an id, and emits `kind == 2` segments naming it |

The page keeps one GPU texture per id — `rgba8unorm` in WebGPU (with rows padded
to 256 bytes, which `writeTexture` requires), `RGBA8` in WebGL2 — and re-uploads
only when `glin_web_gpu_image_version()` changes. `asset_data` is per app, so an
app with no `assets/` directory carries nothing and reports zero image textures.

The catalog is the proof: three assets, three textures, and a CPU-vs-WebGL2 diff
of the whole 1000x4000 screen (mean 0.03/255 over 4,000,000 pixels, 0 errors) in
`web/parity.html?app=catalog&w=1000&h=4000`.

## Verified

| host | command | result |
|---|---|---|
| this machine | `zig build web` | green, module imports nothing, 16 new exports |
| this machine | `node web/smoke.mjs` | 56/56 checks, including the GPU geometry path with no device |
| this machine | `zig fmt --check src/ web/`, `zginlint:check`, `lines:check` | clean |
| this machine | `ci/check_backend_parity.sh`, `check_render_scale.sh`, `check_layering.sh` | green |
| Firefox (headless, WebGL2 over llvmpipe) | `web/parity.html` at 480x360 | **mean 0.00/255, max 1** over 172,800 pixels, 0 errors |
| any browser without either API | `?gpu=off` | CPU rasterizer, 623,808 painted pixels at 912x684 |

Not verified, and stated as such: **the WGSL/WebGPU path has not been run on a
GPU.** No WebGPU-capable browser exists on the machine this landed on, so the
pipeline descriptions, bind groups and WGSL module compile in Chromium's
implementation or they do not — `web/parity.html` is the page that answers it in
one glance, and `web/gpu.js` reports the backend it chose in the status line.

## Why not one backend only

WebGPU is the better API — closer to Metal and Vulkan, no bind-state guesswork —
but it is not everywhere yet. WebGL2 is (and it is OpenGL ES 3.0, the API this
toolkit's Linux backend used before the Vulkan port, so its shader path is not
new ground). The CPU rasterizer stays because it is the only path that works in
every browser, and because it is the reference the other two are measured
against.
