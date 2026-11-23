/* glinlandui browser shim — the exported ABI, and the ONLY interface between
 * wasm and the page.
 *
 * ## What this header is
 *
 * `mac/shim.h` is the contract between `mac/window.zig` (all the logic) and
 * `mac/shim.m` (the NSWindow and its callbacks). This is the same contract for a
 * browser, except that the other side is JavaScript — so there is no C TU to
 * compile and this header exists as the authoritative list of names `shim.js` may
 * call. It is the mirror's `shim.h` slot, kept so all three platform folders read
 * the same way.
 *
 * ## The direction of control is INVERTED
 *
 * `src/web/window.zig` explains this at length; the short version is that a
 * browser owns its event loop, so `glin_web_run` arms and RETURNS and the page
 * drives everything through the calls below. Nothing here blocks.
 *
 * ## Which side makes decisions
 *
 * The page makes NONE. Every translation — `KeyboardEvent.code` to evdev,
 * `MouseEvent.button` to evdev, CSS pixels to backing-store pixels, `deltaMode` to
 * a pixel delta, the resize coalescing — is pure Zig in `src/web/{keymap,input,
 * adapter,present}.zig`, and all of it is in the cross-platform parity suite. A
 * page that reimplements any of it would move untested logic into the one place
 * that cannot be tested, which is exactly the mistake `mac/shim.h` warns about.
 *
 * ## Threading
 *
 * Everything here is main-thread only, and not merely by convention: WebAssembly
 * linear memory has one view, `requestAnimationFrame` is main-thread, and every
 * DOM event listener runs there. There is no worker in this design.
 *
 * ## Memory: the rule that cannot be forgotten
 *
 * `glin_web_surface_ptr()` returns a byte offset into the module's SINGLE linear
 * memory. `memory.grow()` DETACHES every existing `TypedArray` view over that
 * memory, so a view captured once is invalid after any allocation that grows the
 * heap — and a font install, a Clay arena resize or a glyph bitmap can all do
 * that. The caller must therefore rebuild its view whenever `memory.buffer`
 * identity changes. `web/present.zig` carries the same rule from the Zig side,
 * with the reasoning.
 */

#ifndef GLIN_WEB_SHIM_H
#define GLIN_WEB_SHIM_H

#include <stdint.h>

/* ---------------------------------------------------------------------------
 * Lifecycle
 * ------------------------------------------------------------------------ */

/* Create the toolkit window and its Clay arena.
 *
 * `backing_w` / `backing_h` are the CANVAS BACKING STORE size in device pixels,
 * i.e. the CSS size multiplied by `devicePixelRatio` (see `glin_web_scale` and
 * `web/present.zig`'s `canvasSize`). `min_w` / `min_h` of 0 disable the minimum.
 *
 * Returns 1 on success, 0 if a window already exists or an allocation failed.
 * Idempotent in the sense that a second call is a no-op that returns 0, so a
 * double-initialised page does not get two Hosts fighting over Clay's
 * process-global context. */
int32_t glin_web_init(uint32_t backing_w, uint32_t backing_h, uint32_t min_w, uint32_t min_h);

/* Arm the loop. NEVER BLOCKS: there is no loop to start, because the page owns
 * one. After this returns, the calls below are meaningful. Returns 0 if
 * `glin_web_init` has not succeeded. */
int32_t glin_web_run(void);

/* The page is going away (`pagehide`). Notifies the app's `on_close` and stops
 * the loop. Safe to call at any time, including before `glin_web_init`. */
void glin_web_shutdown(void);

/* ---------------------------------------------------------------------------
 * Frame
 * ------------------------------------------------------------------------ */

/* Whether the page should bother drawing this animation frame.
 *
 * Consult this BEFORE `glin_web_frame`. An idle UI returns 0, and the page should
 * then do nothing at all: no layout, no rasterization, no `putImageData`. That
 * check is what makes an idle tab cost approximately nothing, and it is the
 * atomic "skip the clear, the draw and the present together" that
 * `core/frame.zig`'s frame-memo note says the Wayland loop could not achieve. */
int32_t glin_web_needs_frame(void);

/* Draw one frame: adopt at most one coalesced resize, run Clay layout, rasterize,
 * and publish the surface. Safe to call when `needs_frame` is 0 (it just redraws
 * the same content), but pointless. */
void glin_web_frame(void);

/* The frame just drawn, so the page can present it.
 *
 * `glin_web_surface_ptr` is an OFFSET into wasm memory, not a JS pointer, and
 * `glin_web_surface_len` is `width * height * 4` for an RGBA8, top-left-origin,
 * straight-alpha buffer — which is `ImageData`'s layout, so no channel swap and
 * no vertical flip is needed. See the memory rule at the top of this header
 * before caching a view over it.
 *
 * All four return 0 before the first frame. */
uint32_t glin_web_surface_ptr(void);
uint32_t glin_web_surface_len(void);
uint32_t glin_web_surface_width(void);
uint32_t glin_web_surface_height(void);

/* Diagnostics, computed lazily on the frame they describe — asking costs one
 * O(width*height) scan, and a page that never asks pays nothing.
 *
 * These replace the macOS backend's `"first frame: WxH, N painted pixels, blit
 * checksum"` log line, which CI greps. A browser has no stderr, so the same
 * evidence is exposed as numbers: `web/smoke.mjs` asserts `painted_pixels > 0`
 * (a blank canvas still paints every pixel, so "it ran" proves nothing) and a
 * non-zero `frame_hash` (which a flat frame cannot fake). */
uint32_t glin_web_painted_pixels(void);
uint64_t glin_web_frame_hash(void);
uint32_t glin_web_frames(void);

/* ---------------------------------------------------------------------------
 * Input
 *
 * All synchronous, all non-blocking, all marking the frame dirty. None of them
 * needs an "invalidate" call: the page's `requestAnimationFrame` loop is always
 * reading `glin_web_needs_frame`.
 * ------------------------------------------------------------------------ */

/* A `PointerEvent`.
 *
 * `kind`: 0 = motion, 1 = button down, 2 = button up, 3 = cancelled
 *         (`pointercancel` — the OS took the gesture over).
 * `button`: `MouseEvent.button` (0 main, 1 auxiliary, 2 secondary, 3 back,
 *           4 forward). Ignored for motion.
 * `x` / `y`: canvas BACKING-STORE pixels. The page must scale by
 *            `devicePixelRatio`; `web/present.zig`'s `toBackingPoint` owns the
 *            choice of scale and `web/adapter.zig` clamps, so an out-of-bounds
 *            value from a captured drag is expected rather than a bug.
 *
 * A press reports the evdev code `components.dispatch` requires (272 for the
 * primary button); motion reports 0. Collapsing those two is what made every
 * macOS click a silent no-op, so the distinction is explicit here too. */
void glin_web_pointer(int32_t kind, int32_t button, double x, double y);

/* A `WheelEvent`.
 *
 * `dx` / `dy` are the RAW `deltaX` / `deltaY`. `mode` is the DOM's `deltaMode`
 * (0 pixel, 1 line, 2 page); the toolkit normalises it, because a backend that
 * ignores it scrolls a list by three pixels on one platform and three lines on
 * another. The SIGN IS NOT TOUCHED: the DOM's positive `deltaY` already means
 * "scroll down", which is the toolkit's convention — unlike AppKit's, which has
 * to be negated. */
void glin_web_wheel(double dx, double dy, int32_t mode);

/* A `keydown` / `keyup`.
 *
 * `code` is `KeyboardEvent.code` (a DOM string, deliberately PHYSICAL-key named:
 * `"KeyA"`, `"Digit1"`, `"NumpadAdd"`), passed as a byte range because
 * `KeyboardEvent.code` is a string API and translating it in JS would put a
 * 99-entry table in the one place that cannot be unit-tested. `src/web/keymap.zig`
 * — pure, tested, type-checked on Linux and macOS — does the translation.
 *
 * The range may point into any wasm-owned buffer; the page typically allocates a
 * scratch buffer once with `glin_web_alloc` and writes into it per event. An
 * unmapped code is silence rather than a guess. `pressed` is 1 for keydown. */
void glin_web_key(const uint8_t *code, uint32_t code_len, int32_t pressed);

/* A new canvas size, in BACKING-STORE pixels (`ResizeObserver`). Recorded, not
 * applied: a live window drag sends one per animation frame and the next
 * `glin_web_frame` adopts at most the last, so the page lays out once per drawn
 * frame instead of once per event. */
void glin_web_resize(uint32_t backing_w, uint32_t backing_h);

/* `devicePixelRatio` changed (the window moved to another display, or the user
 * zoomed). Clamped by `web/present.zig` to 1..4. */
void glin_web_scale(float scale);

/* Focus was lost. Releases any held pointer button, because a tab that loses
 * focus mid-drag never receives the matching `pointerup`, and a stale held button
 * would make the next motion drag the UI with nothing pressed. */
void glin_web_blur(void);

/* ---------------------------------------------------------------------------
 * Routing: the address the app is showing
 *
 * The app owns its address; the page owns the URL. `src/core/route.zig` is the
 * whole mechanism — the app navigates by intent and reads the current route while
 * it declares — and the browser is one backend that mirrors it: `#buttons` in
 * `location.hash`, and the browser's own Back button adopted back in. The same
 * code runs on the desktop, where there is no URL to mirror.
 *
 * `?app=catalog` is the PAGE's business (which module to load) and the fragment is
 * the APP's (which screen), so two apps can both have an `#overview` and the app
 * switcher never has to know what a screen is.
 *
 * The page makes no decisions here either: it copies the router's address into the
 * URL, and the URL's address back into the router. The GENERATION is what makes
 * that loop safe — an address the page has already mirrored is not pushed again,
 * which is what keeps a Back button from skipping two entries at a time.
 * ------------------------------------------------------------------------ */

/* The route's bytes as an OFFSET into wasm memory, and their length. 0 length means
 * the app has no address yet (it has not navigated and the page supplied none). */
uint32_t glin_web_route_ptr(void);
uint32_t glin_web_route_len(void);

/* Changes on every navigation, and only then. The page keeps the last value it
 * mirrored; anything else is a new address to write into the URL. */
uint32_t glin_web_route_generation(void);

/* A block the page writes an address into before `glin_web_location`, so adopting
 * one allocates nothing and cannot grow the heap (see the memory rule above). Its
 * length is `route.max_path`; a longer address is truncated, not rejected. */
uint32_t glin_web_route_scratch(void);
uint32_t glin_web_route_scratch_len(void);

/* The page telling the toolkit where the app really is: the boot deep link
 * (`#buttons`), a `popstate` from the browser's Back/Forward, or an edited URL.
 *
 * This REPLACES the current entry instead of pushing one, because the environment
 * has already moved. Returns the generation it produced, which the page records as
 * mirrored so it does not push the address it just adopted. */
uint32_t glin_web_location(const uint8_t *path, uint32_t path_len);

/* ---------------------------------------------------------------------------
 * Memory handed IN (the font)
 * ------------------------------------------------------------------------ */

/* Allocate `len` bytes in wasm memory and return their offset, or 0 on failure.
 * The caller owns the block until it hands it to `glin_web_font` (or frees it). */
uint32_t glin_web_alloc(uint32_t len);

/* Free a block from `glin_web_alloc`. `ptr` / `len` must be the pair that call
 * returned. */
void glin_web_free(uint32_t ptr, uint32_t len);

/* Install a font the page fetched, so text draws as GLYPHS instead of the
 * glyph-free per-byte bars.
 *
 * A browser has no font paths, so this is the only way it can get one:
 * `src/web/text.zig` reports an empty candidate list on purpose, and
 * `core/glyphs.zig`'s `installFont` is what the rasterizer consults first. The
 * bytes must be a plain `.ttf`/`.otf` — NOT a `.ttc` collection, which
 * `stbtt_InitFont` cannot load, and NOT an error page, which
 * `glin_compat_trap`-adjacent assertion machinery would otherwise see.
 *
 * `ptr` / `len` must be a block from `glin_web_alloc`; ownership passes to the
 * module, which keeps it for the lifetime of the instance (the installed font
 * must outlive every glyph lookup, so it is never freed).
 *
 * Returns 1 if the bytes parsed and were installed, 0 if they were not a
 * loadable font — in which case the page may retry, and the toolkit keeps drawing
 * glyph-free text rather than failing. */
int32_t glin_web_font(uint32_t ptr, uint32_t len);

/* WHY the last `glin_web_font` failed, as a number. 0 means it did not.
 *
 * `glin_web_font` returns a bare 0/1, which cannot distinguish "the bytes were
 * empty" from "the signature was not an sfnt" from "stb refused the header". That
 * ambiguity is expensive: a page showing glyph-free bars looks identical whether
 * the font was missing, rejected, or unparseable, and the only way to tell is to
 * guess and re-run.
 *
 *   0 = no failure recorded
 *   1 = empty input
 *   2 = signature not recognised (not an sfnt; a `.ttc`, or an HTML error page)
 *   3 = stbtt_InitFont refused the header
 *   4 = no window (glin_web_init has not run)
 *
 * `web/smoke.mjs` asserts this is 0 after `glin_web_init`, which is what proves
 * the embedded font actually installed rather than silently falling back. */
uint32_t glin_web_font_error(void);

/* A once-allocated scratch block for `glin_web_key`'s event codes, and its
 * length. The page writes `KeyboardEvent.code` into it per keystroke instead of
 * allocating each time; it is exported rather than a constant so a page written
 * against this header alone does not have to guess an address. 0 if
 * `glin_web_init` has not succeeded. */
uint32_t glin_web_key_scratch(void);
uint32_t glin_web_key_scratch_len(void);

/* ---------------------------------------------------------------------------
 * GPU: WebGPU, else WebGL2, else the CPU rasterizer
 *
 * The renderer picks a backend in that order, and the page does the picking,
 * because only the page can create a `GPUDevice` or a `WebGL2RenderingContext`.
 * It then tells the toolkit the answer with `glin_web_gpu_ready` and, from then
 * on, draws the buffers below instead of the CPU surface:
 *
 *   - `glin_web_gpu_ready(0)` — no GPU context, or one that failed. The toolkit
 *     rasterizes on the CPU exactly as it did before this ABI existed, and the
 *     page blits `glin_web_surface_ptr()` with `putImageData`. Nothing is lost:
 *     this is the browser's GDI fallback.
 *   - `glin_web_gpu_ready(1)` — WebGPU, `(2)` — WebGL2. From the next frame on,
 *     `glin_web_surface_ptr()` returns 0 (there are no CPU pixels to blit) and
 *     the frame lives in the vertex and segment buffers below.
 *
 * The CALL DIRECTION is the same as everywhere else in this header: the page
 * calls into the module. The module imports NOTHING — `WebAssembly.Module.imports()`
 * on this module must stay empty, which is why the GPU calls run from JS over
 * these accessors rather than from Zig over `extern` functions.
 *
 * ## One vertex, 17 floats (68 bytes)
 *
 *     float pos[2]     device pixels, top-left origin
 *     float local[2]   rect: box-local px; text/image: normalized uv
 *     float size[2]    rect box size in device px; 0 for text
 *     float radius[4]  rect corner radii TL, TR, BL, BR in device px
 *     float color[4]   straight (non-premultiplied) 0..1 RGBA
 *     float mode       rect: 0 fill, 1 border outline
 *     float border     rect: border width in device px
 *     float kind       0 rect, 1 text coverage, 2 image
 *
 * `glin_web_gpu_vertex_stride()` returns 68: never hardcode it. The layout is
 * the same one `src/linux/vk.h` and `src/mac/metal.h` declare, so the shaders in
 * `web/gpu.js` are a port rather than a second design.
 *
 * ## One segment, 9 int32 (36 bytes)
 *
 *     int32 start, count     first vertex index, vertex count
 *     int32 has_scissor     0 = no clip
 *     int32 sx, sy, sw, sh   scissor in device pixels, top-left origin
 *     uint32 texture_id      0 = the glyph atlas; 1.. reserved for images
 *     int32 kind             0 rect, 1 text (atlas), 2 image
 *
 * A segment is a run of vertices sharing one scissor and one pipeline, because
 * Clay interleaves boxes and text and a scrolled container's clip cannot be a
 * single per-frame rectangle. Draw them in order: the buffer is already sorted
 * by depth and the blend state is straight-alpha over.
 * ------------------------------------------------------------------------ */

/* The page's answer: 0 = none (CPU rasterizer), 1 = WebGPU, 2 = WebGL2. Anything
 * above 2 is treated as 0 rather than trusted. Marks the frame dirty, so the next
 * `glin_web_frame` is built for the backend that will draw it. */
void glin_web_gpu_ready(uint32_t kind);

/* What the last `glin_web_gpu_ready` said. 0 is a supported browser, not a failure. */
uint32_t glin_web_gpu_kind(void);

/* The frame's geometry. Every pointer is an OFFSET into wasm memory (0 when the
 * buffer is empty) and every length is bytes, so the page's views must obey the
 * memory rule at the top of this header: rebuild them when `memory.buffer`
 * identity changes, because a frame can grow the heap. */
uint32_t glin_web_gpu_verts_ptr(void);
uint32_t glin_web_gpu_verts_len(void);
uint32_t glin_web_gpu_segs_ptr(void);
uint32_t glin_web_gpu_segs_count(void);
uint32_t glin_web_gpu_vertex_stride(void);
uint32_t glin_web_gpu_segment_stride(void);

/* The 8-bit glyph atlas (width * height coverage bytes, ALREADY in device
 * pixels) and a version that changes only when its CONTENTS changed. Re-upload
 * the whole texture when the version differs from the one uploaded last; sample
 * it with LINEAR filtering and CLAMP_TO_EDGE, red channel only. 0 / 0 means the
 * frame had no text, which is not an error. */
uint32_t glin_web_gpu_atlas_ptr(void);
uint32_t glin_web_gpu_atlas_len(void);
uint32_t glin_web_gpu_atlas_version(void);
uint32_t glin_web_gpu_atlas_width(void);
uint32_t glin_web_gpu_atlas_height(void);

/* The frame's target size in DEVICE pixels. The geometry is already expressed in
 * that space, so a shader needs only this to map pixels to clip space, and the
 * canvas backing store should match it. 0 before the first draw. */
uint32_t glin_web_gpu_width(void);
uint32_t glin_web_gpu_height(void);

/* The clear colour, packed RGBA8 with red in the low byte: one integer instead
 * of four floats crossing the boundary per frame. Alpha is 255 in practice; a
 * transparent clear is still honoured by the page's blend setup. */
uint32_t glin_web_gpu_clear_rgba(void);

/* The image textures the frame names, in draw order. A segment of kind 2 names
 * one in `texture_id`; a segment of kind 0 or 1 binds the glyph atlas.
 *
 * Each image is decoded ONCE, by the engine, from the bytes `build.zig` embedded
 * (`asset_data`) — the same decoder the disk path uses, so the page and a desktop
 * window draw the same pixels. Upload the RGBA8 bytes as a texture when `version`
 * changes, and keep it keyed by `id` (ids wrap at 255, and a wrap bumps the
 * version, so a reused id is replaced rather than reused silently).
 *
 * `index` is 0..`glin_web_gpu_image_count()`-1; a bad index answers 0. */
uint32_t glin_web_gpu_image_count(void);
uint32_t glin_web_gpu_image_id(uint32_t index);
uint32_t glin_web_gpu_image_version(uint32_t index);
uint32_t glin_web_gpu_image_width(uint32_t index);
uint32_t glin_web_gpu_image_height(uint32_t index);
uint32_t glin_web_gpu_image_ptr(uint32_t index);
uint32_t glin_web_gpu_image_len(uint32_t index);

/* ---------------------------------------------------------------------------
 * Diagnostics the page may want to surface
 * ------------------------------------------------------------------------ */

/* How many messages `std.log` has produced, by level.
 *
 * A freestanding wasm module has nowhere to print — the default `logFn` cannot
 * even compile — so `src/web_main.zig` overrides it with a counter. That turns
 * "we cannot report" into "the page can observe": a renderer that failed to
 * initialise increments `errors`, and `web/smoke.mjs` asserts that a frame logged
 * none. That is a stronger check than grepping a log for a known string, because
 * it does not depend on anyone having predicted the message. */
uint32_t glin_web_log_errors(void);
uint32_t glin_web_log_warnings(void);
uint32_t glin_web_log_infos(void);

#endif /* GLIN_WEB_SHIM_H */
