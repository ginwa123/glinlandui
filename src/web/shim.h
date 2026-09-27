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
