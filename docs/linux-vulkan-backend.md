# Linux renderer: GLES3 → Vulkan

Status: **landed.** The renderer is Vulkan now; this document is the design record and the
explanation of why each choice was made.

## Goal

The Linux backend's GPU path was Wayland + **EGL + GLES3**, and is now **Vulkan**, behind the same
renderer contract the core frame path already drives. macOS (Metal), Windows (D3D11) and the
browser (CPU) are untouched.

Done means:

- `zig build` on macOS is still green (`zig build`, `zig build test`, `zig build zginlint:check`,
  `zig build lines:check`) — the macOS host never compiles the Linux arm, so this is about not
  breaking the shared build graph.
- On Linux: `zig build`, `zig build native-test` and `zig build bench-lazy-scroll` are green.
- `ci/check_test_parity.sh` still passes: the **portable** test count is unchanged, because test
  builds keep selecting `core/render_software.zig` (`src/platform.zig`). Only the Linux-only
  `native-test` set changes.
- CI green, squash-merged to `main`.

## As built

| file | what it is |
|---|---|
| `src/linux/vk.h` | the shim ABI: create/destroy/resize/set_texture/draw/offscreen, one 17-float vertex, per-segment draws |
| `src/linux/vk.c` | the Vulkan objects: instance, wayland surface, device, swapchain, render pass, three pipelines, texture table, offscreen readback |
| `src/linux/shaders/*.vert`, `*.frag`, `*.spv` | `quad.vert` + `rect`/`text`/`image` fragments, and the committed SPIR-V |
| `src/linux/renderer.zig` | geometry, the text and image caches, clip arithmetic — every decision |
| `src/linux/vk_parity_test.zig` | the GPU-vs-CPU gate, run by `zig build native-test` |
| `src/linux/present.zig` | **deleted**: presenting is part of `drawCommands` |
| `window.zig`, `build.zig`, `ci.yml`, docs | EGL out, `vulkan` in, `libvulkan-dev` + `mesa-vulkan-drivers` in CI |

Verified, on the code that landed:

| host | command | result |
|---|---|---|
| macOS (arm64) | `zig build`, `zig build test` | green, 1143/1145 (parity lock 1145) |
| macOS | `zginlint:check`, `lines:check`, `zig fmt --check` | 0 findings, no file over 3000 lines, formatted |
| Linux (arm64 container, lavapipe) | `zig build -Doptimize=ReleaseSafe` | green |
| Linux | `zig build test` | 1143/1145 — the same count as macOS |
| Linux | `zig build native-test` | 643/650 (7 skipped), including `vulkan vs cpu` diffs of **1/255** on `rects`, `rounded`, `side_bar` and the image quad |
| Linux | `zig build bench-lazy-scroll` + `ci/check_lazy_scroll_bench.sh` | `declared=28`, `scroll_y=-219430`, avg 0.08 ms — identical to the GLES3 run |
| Linux + weston headless | the demo, 3 frames | device created on llvmpipe, first frame drawn and presented, clean shutdown |

Regenerate the shaders with `sh tools/build_shaders.sh` (needs `glslang-tools`); the build itself
never compiles GLSL, so the committed `.spv` is what a Linux `zig build` reads.

Two bugs only a real compositor could find, both fixed:

- **The first frame cannot wait for a frame callback.** A surface with no buffer attached is not
  mapped, so the compositor owes it no callback — the old pre-loop `glClear` + `eglSwapBuffers` had
  been presenting that first buffer, and removing it left the loop waiting for a callback it would
  never get. The window now draws the first frame immediately.
- **The swapchain must die before the `wl_surface`.** `host.deinit()` runs after `run()` returns,
  which is after the window's `defer` destroyed the surface; `vkDestroySwapchainKHR` then segfaulted
  inside libwayland. `render.shutdown()` is now a `defer` registered right after `attach`, so it runs
  before the surface goes.

## How the Linux renderer is wired today

| piece | where |
|---|---|
| composition root | `src/platform.zig` — `render_impl = linux => src/linux/renderer.zig` |
| the bridge `core/` may use | `src/core/select.zig` (`Renderer`, `TextBackend`, …) |
| who creates it | `src/core/frame.zig:962` — lazily, `render.Renderer.init(alloc)` |
| who draws | `src/core/frame.zig:971/974` — `r.drawCommands(commands, w, h)` |
| who presents | `src/linux/window.zig:930` and `:1006` → `src/linux/present.zig` (`eglSwapBuffers`) |
| EGL bootstrap | `src/linux/window.zig:898-930` (display, config, context, `wl_egl_window`) |
| resize | `src/linux/window.zig:991` (`wl_egl_window_resize`) + `:775-782` (`applyUiScale`) |
| the renderer | `src/linux/renderer.zig` (1123 lines): pure helpers + `Renderer` (line 379) |
| link flags | `build.zig:140-142` (`wayland-egl`, `EGL`, `GLESv2`); `:873-877` for `native-test` |
| native test root | `src/native_test.zig` imports `linux/{text,renderer,window,file_dialog}.zig` |

`src/linux/renderer.zig` is deliberately split in two:

- **Headless-testable pure helpers**, which must survive the port with their tests:
  `u32ToClayColor`, `u32ToGLColor`, `estimatorAdvance`, `extentToClay`, `hashTextKey`,
  `lruVictim`, `hashImageKey`, `scaledDims`, `coverUv`, `containBox`, `cornerRadiusVec4`,
  `straightColor`, plus `ImageFit` / `ImageRef` / `DecodedImage` and the cache entry types.
- **The GL part**: shaders (241-378), `Renderer` (379-1123) with `init` (422), `deinit` (487),
  `drawCommands` (914), the text-coverage LRU (64 entries) and the image LRU (32 entries).

## What replaces it

### 1. A C shim owns the Vulkan objects: `src/linux/vk.h` + `src/linux/vk.c`

Same split as `mac/metal.h`/`metal.m` and `windows/shim.h`/`shim.c`, and for the same reason:
Zig's `@cImport` only ever sees the shim header, so `<vulkan/vulkan.h>`'s macros never have to
survive translation. **Zig keeps every decision** (geometry, caches, clip arithmetic); the shim
owns the `VkInstance`, device, swapchain, pipelines and texture table and decides nothing.

The proposed ABI is already in the tree as `src/linux/vk.h`:

```
GlinVk *glin_vk_create(wl_display, wl_surface, w, h, vert_spv, rect_spv, text_spv, image_spv);
void    glin_vk_destroy(GlinVk *);
int     glin_vk_resize(GlinVk *, int w, int h);
int     glin_vk_set_texture(GlinVk *, unsigned id, const unsigned char *bytes, int w, int h, int channels);
int     glin_vk_draw(GlinVk *, const GlinVkVertex *verts, int nverts,
                     const GlinSegment *segs, int nsegs, float r, g, b, a);
int     glin_vk_offscreen(GlinVk *, verts, nverts, segs, nsegs, w, h, r, g, b, a, unsigned char *out);
const char *glin_vk_device_name(GlinVk *);
const char *glin_vk_last_error(void);
```

`GlinVkVertex` is the **same 17-float / 68-byte vertex** `mac/metal.h` and `windows/shim.h`
declare (`pos`, `local`, `size`, `radius`, `color`, `mode`, `border`, `kind`), so a renderer port
between backends stays a change of call site. `GlinSegment` adds `kind` (0 rect, 1 text, 2 image),
which is what picks the pipeline; `texture_id` 0 means "no texture" (rects sample a 1×1 white
texture, so one pipeline layout serves all three).

Implementation notes that are easy to get wrong:

- Instance: `VK_KHR_surface` always, `VK_KHR_wayland_surface` only when a `wl_surface` is given
  (headless creation must not ask for it). `VK_USE_PLATFORM_WAYLAND_KHR` before `<vulkan/vulkan.h>`.
- **Classic render pass, not dynamic rendering**: dynamic rendering needs Vulkan 1.3 or an
  extension; a single-color-attachment render pass works on 1.0 and on lavapipe.
- Pipelines are tied to a render pass, so keep one set and rebuild it (`ensure_pipes`) when the
  pass changes — swapchain recreation with a new format, or the offscreen target.
- Swapchain format: prefer `VK_FORMAT_B8G8R8A8_UNORM`, else `R8G8B8A8_UNORM`, `FIFO` present
  mode, `COLOR_ATTACHMENT` usage. **Not** an `_SRGB` format: GLES3 on an UNORM default framebuffer
  did no gamma conversion, and the golden/parity checks are byte comparisons.
- Blending matches the old GL state: `SRC_ALPHA / ONE_MINUS_SRC_ALPHA`, alpha `ONE /
  ONE_MINUS_SRC_ALPHA`; render pass `loadOp = CLEAR`.
- Scissor is dynamic state. Vulkan requires the rectangle to lie inside the framebuffer, so **clamp
  it** — the GL path only clamped the origin and relied on GL tolerating an oversized box. Do the
  clamping in Zig (`clampScissor`, pure and testable) and skip segments with zero area.
- `vkCmdDraw(firstVertex = seg.start, vertexCount = seg.count)` — one draw per segment.
- Textures: a fixed table of `GLIN_VK_MAX_TEXTURES` (128) entries; `set_texture` creates/replaces
  the image and rewrites that id's descriptor set. It may `vkDeviceWaitIdle` — it only runs on a
  cache miss.
- `glin_vk_offscreen` renders into an `R8G8B8A8_UNORM` target and copies it to a host-visible
  buffer, converting to RGBA on the way out if the device's pass format was BGRA.
- No stderr printing from C: return codes plus `glin_vk_last_error()`, and Zig reports through
  `core/log.zig` (`std.log` is banned by `zginlint/no-std-log-warn`).

### 2. Shaders: GLSL in the repo, SPIR-V committed

Vulkan cannot consume GLSL, and the build must not depend on a shader compiler being installed —
`zig build` for Linux also runs on macOS hosts and on CI images we do not control.

- `src/linux/shaders/quad.vert` — one vertex shader for all three pipelines, `layout(push_constant)
  uniform { vec2 u_res; }`. Vulkan's NDC y points **down**, so the pixel→clip conversion is
  `p / u_res * 2 - 1` with no negation (the GLES3 shader negated y).
- `rect.frag` — the same rounded-box SDF as today, with `cov(d) = clamp(0.5 - d, 0.0, 1.0)`.
  Because geometry is built in **device pixels**, the AA band is one device pixel for free and
  `u_scale` disappears; that also removes the "2× display leaves a quarter-transparent column"
  bug the current shader carries a uniform for.
- `text.frag` — `o_color = vec4(u_color.rgb, u_color.a * texture(u_tex, v_uv).r)`.
- `image.frag` — `o_color = texture(u_tex, v_uv)`.
- `*.spv` committed next to them, embedded with `@embedFile` and passed to `glin_vk_create`.
  Generate with `tools/build_shaders.sh` (`glslangValidator -V --target-env vulkan1.0`), and commit
  both the sources and the binaries: the sources stay reviewable and the build stays compiler-free.

### 3. `src/linux/renderer.zig` becomes the Vulkan renderer

Port `src/mac/renderer.zig`'s shape (build vertices + segments in Zig, hand them to the shim) but
keep Linux's **pango run rasterisation**: today a text run is one `text.rasterizeRun` coverage
bitmap, cached by `hashTextKey` and drawn as a single tinted quad. That is better than the macOS
per-glyph atlas (shaping, kerning, subpixel positioning) and it keeps the existing cache, its LRU
and its tests. So:

- Keep every pure helper and its test; `u32ToGLColor` can be renamed or kept (it is only a colour
  normaliser) but do not lose the test coverage.
- Text cache slot `i` → texture id `i + 1` (1..64); image cache slot `j` → id `65 + j` (65..96).
  On eviction the same id is replaced with the new bitmap, which is why the ids are slot-stable.
- Build all geometry at **device** scale (`ui_scale.current()`), the way `drawTextCmd` already
  does its `fs_dev` arithmetic — but stop dividing back into points: positions, sizes and radii are
  device pixels end to end.
- `pub fn attach(display, surface)` (module-level pending pair, exactly like `mac/renderer.zig`'s
  `attachView`) called by `window.zig` after the `wl_surface` exists; `drawCommands` creates the
  device on first use, resizes the swapchain from `scale.pixelSize(win_w, win_h, s)`, and presents.
- Clear colour: move `clearColor()` (`src/linux/window.zig:108`) into the renderer; the render pass
  does the clear now, so `glClear` in the window goes away.
- `pub fn attachOffscreen()` + `renderOffscreen(commands, w, h)` for the parity test, as macOS has.

### 4. `src/linux/window.zig`

- Delete the EGL bootstrap (`898-930`), `eglConfigAttribs()` + its test, `glClear*`/`glViewport`
  calls, the `egl_window` field, and `applyUiScale`'s `wl_egl_window_resize`/`glViewport` block
  (keep the `wl_surface_set_buffer_scale` half — that is the compositor contract, not GL).
- Call `render.attach(display, surface)` once the surface exists; the renderer does the rest.
- Delete `src/linux/present.zig` and the `present.present(...)` calls: presenting is part of
  `drawCommands` now. (`present.zig` is imported only by `window.zig`.)

### 5. `build.zig`

- Linux module (`:140-142`): drop `wayland-egl`, `EGL`, `GLESv2`; add `vulkan`; add the shim TU
  (`mod.addCSourceFile(.{ .file = b.path("src/linux/vk.c"), ... })` — inside the `is_linux` branch).
- `makeNativeTestStep` (`:873-877`): same swap, so `native-test` links the shim it exercises.
- Update the `native-test` step description (`:594-595`) and the comment above it.

### 6. CI (`.github/workflows/ci.yml`)

Four apt lists install `libegl-dev` + `libgles-dev` (lines ~64/69, ~408/413, ~580/585, ~869/874).
Replace both with `libvulkan-dev` and add `mesa-vulkan-drivers` (lavapipe) so the GPU parity test
has a device on a runner. Rename the Linux job/labels that say "native GLES3" (`:46`, `:113`,
`:116`, `:129`, `:359`, `:377`, `:436`, `:439`).

### 7. Docs

`AGENTS.md:26,76,160`, `README.md:15,49,326,758,1322` and `src/README.md` all say EGL/GLES3 on
Linux. `ci/check_layering.sh:115` forbids `core/` from including EGL/GLES — extend that pattern
with `vulkan` so the layering gate keeps meaning something.

## Test plan

- **Keep** the pure-helper tests in `src/linux/renderer.zig` (they run in `native-test`).
- **Add** `src/linux/vk_parity_test.zig`, mirroring `src/mac/metal_parity_test.zig`: render the
  golden scenes through `renderOffscreen` and compare against `core/render_software.zig` with the
  same 1-unit tolerance; skip (`error.SkipZigTest`) when `attachOffscreen` finds no device, so a
  machine without a Vulkan driver is not a failure.
  - **Skip scenes containing `.text` commands.** Linux text comes from pango `rasterizeRun`; the CPU
    reference draws stb glyphs. That difference is by design, not a bug — compare `rects`,
    `rounded`, `side_bar` (and `composite` only if it has no text).
  - The image case can reuse the macOS test's approach (write a TGA, `s.putImage`,
    `soft.Surface.putImage` with the same `hashImageKey`) and a 2-unit tolerance for bilinear.
- The old shader-string regression tests in `renderer.zig` (rect coverage band, no `smoothstep`)
  move to the new `rect.frag`, embedded with `@embedFile` so the test still reads real source.

## Verification

The dev machine is macOS, so the Linux arm has to be exercised in a container. A Debian bookworm
container already has Zig 0.16.0, `libvulkan-dev`, `vulkan-tools`, `mesa-vulkan-drivers`
(lavapipe), `glslang-tools` and the pango/wayland dev packages, with
`/Users/ginwa/glinlandui` mounted at `/w`:

```sh
podman exec 6b06aed45bfe sh -lc 'cd /w && zig build -Doptimize=ReleaseSafe'
podman exec 6b06aed45bfe sh -lc 'cd /w && zig build native-test --summary all'
podman exec 6b06aed45bfe sh -lc 'cd /w && zig build bench-lazy-scroll && sh ci/check_lazy_scroll_bench.sh'
podman exec 6b06aed45bfe sh -lc 'cd /w && vulkaninfo --summary | head -20'   # lavapipe present?
```

A windowed run needs a compositor; `weston --backend=headless-backend.so --socket=wayland-test`
with `XDG_RUNTIME_DIR` and `WAYLAND_DISPLAY=wayland-test` is how the demo run above was checked.
The offscreen parity test needs neither, which is why it is the real gate in CI.

On macOS, before calling it done:

```sh
zig build && zig build test && zig build zginlint:check && zig build lines:check
zig fmt --check build.zig src examples tools
```

## Pitfalls found while surveying this

- `tests.lock` (1145) locks the **portable** test count. The Linux renderer's own tests live in
  `native-test` only, so they can change freely — do not touch `tests.lock` for them.
- `zginlint` runs on the macOS host and does not resolve `@cInclude`, so a shim header that only
  exists on Linux is fine; the C TU itself must only be added inside `build.zig`'s `is_linux` branch.
- `src/linux/window.zig` keeps `wl_surface` and `display` as locals in `run()`; `attach` must be
  called there, and the renderer must tolerate `attach` never being called (headless tests).
- `frame.zig` treats a failed `Renderer.init` as "clear-only" and logs a warning. Under Vulkan a
  failed create means nothing is drawn at all, so `init` should stay lazy (succeed) and the failure
  should surface on the first `drawCommands` — and be logged once, through `core/log.zig`, with
  `glin_vk_last_error()` and `glin_vk_device_name()`.
- Frames in flight: `vkAcquireNextImageKHR` returning `VK_ERROR_OUT_OF_DATE_KHR` must recreate the
  swapchain and *not* present, and `vkQueuePresentKHR` can return `VK_ERROR_OUT_OF_DATE_KHR` too.
  A resize that the surface has not acknowledged yet is not an error worth logging.
- The render pass uses `initialLayout = UNDEFINED` even though an acquired image is in
  `PRESENT_SRC_KHR`: that is the canonical pattern and is what lets one pass serve every frame.
