// glinlandui macOS window shim — plain C surface.
//
// This header is deliberately free of every Objective-C and CoreGraphics type,
// for the same reason `pango_text.h` is: Zig's @cImport only ever sees this
// file, so the ObjC headers (and their macros) never have to survive
// translation. The implementation lives in `cocoa_window.m`.
//
// The split of responsibility is the whole point of this shim:
//   - Zig owns ALL logic. Layout, rendering, hit-testing, the Delegate
//     contract, keycode translation, coordinate flipping.
//   - This shim owns ONLY the window, the view, and capturing events into
//     callbacks. It makes no decisions.
//
// That is what keeps the untestable part small. The conversions that are easy
// to get silently wrong — keycodes, the y-axis flip, the BGRA byte order — all
// live in Zig and are unit-tested in the cross-platform parity suite.
//
// Callbacks are invoked synchronously on the AppKit main thread.

#ifndef GLIN_COCOA_WINDOW_H
#define GLIN_COCOA_WINDOW_H

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque handle to the window + its view.
typedef struct GlinCocoaWindow GlinCocoaWindow;

/// Called from `-drawRect:` before the shim composites. The host is expected
/// to render its frame and then call glin_cocoa_present() with a
/// BGRA, bottom-row-first buffer. Returns nothing: the shim does not care
/// whether a frame was produced.
typedef void (*GlinCocoaOnFrame)(void *user);

/// Pointer event in the view's own coordinate space. AppKit's origin is
/// bottom-left; the host is responsible for flipping to the toolkit's
/// top-left origin (see platform/macos_adapter.zig).
/// `pressed` is 0 for motion, 1 for a button-down/up transition.
/// `button` is 0 for the primary button.
typedef void (*GlinCocoaOnPointer)(void *user, double x, double y, int pressed, int button);

/// Raw scroll deltas in AppKit's sign convention (positive dy = content moving
/// up). The host clamps and negates them.
typedef void (*GlinCocoaOnScroll)(void *user, double dx, double dy);

/// Key event carrying the macOS virtual keycode (NOT an evdev code — the host
/// translates). Return 1 if the key was consumed.
typedef int (*GlinCocoaOnKey)(void *user, int mac_keycode, int pressed);

/// Proposed size after clamping. Not applied immediately: the host coalesces
/// resizes and applies at most one per drawn frame.
typedef void (*GlinCocoaOnResize)(void *user, int w, int h);

/// The window's close button was pressed.
typedef void (*GlinCocoaOnClose)(void *user);

/// Create the window and its view. Returns NULL on failure (e.g. no window
/// server, which is what a headless CI runner looks like).
/// `min_w`/`min_h` of 0 disable the minimum size.
GlinCocoaWindow *glin_cocoa_window_create(const char *title, int w, int h,
                                          int min_w, int min_h);

void glin_cocoa_window_destroy(GlinCocoaWindow *win);

/// Install the event callbacks. Must be called before run.
void glin_cocoa_window_set_callbacks(GlinCocoaWindow *win,
                                     GlinCocoaOnFrame on_frame,
                                     GlinCocoaOnPointer on_pointer,
                                     GlinCocoaOnScroll on_scroll,
                                     GlinCocoaOnKey on_key,
                                     GlinCocoaOnResize on_resize,
                                     GlinCocoaOnClose on_close,
                                     void *user);

/// Start the AppKit event loop; blocks until the app quits.
/// `max_frames` of 0 runs until the user quits. A positive value stops after
/// that many drawn frames, which is how the test harness gets a deterministic,
/// screenshot-able run instead of an interactive one.
void glin_cocoa_window_run(GlinCocoaWindow *win, int max_frames);

/// Hand the view a frame to composite. `bgra` must be
/// `w * h * 4` bytes, already converted to BGRA with the bottom row first
/// (see platform/blit.zig). Safe to call with a NULL buffer or a zero
/// dimension, in which case the previous frame stays on screen.
void glin_cocoa_present(GlinCocoaWindow *win, const unsigned char *bgra, int w, int h);

/// Ask the event loop to stop. Safe to call from any callback.
void glin_cocoa_quit(GlinCocoaWindow *win);

/// The window's current content size in points (0 if the window is gone).
void glin_cocoa_content_size(GlinCocoaWindow *win, int *out_w, int *out_h);

#ifdef __cplusplus
}
#endif

#endif // GLIN_COCOA_WINDOW_H
