//! Frame -> screen for Linux — the `present.zig` half of the platform mirror.
//!
//! ## Role, and why the function names differ from macOS's
//!
//! On macOS the renderer draws into a CPU buffer, and presenting means copying
//! that buffer into a CoreGraphics bitmap — a byte-level *blit*, which is why
//! `mac/present.zig` owns `blitBufLen`/`blitSizeValid`/`identityRgba8` and a
//! whole document about channel order and row order.
//!
//! Linux has none of that. `linux/renderer.zig` drives GLES3 and draws straight
//! into the EGL window surface, so there are no CPU pixels to copy and no byte
//! order to get wrong. Presenting is one call: hand the finished back buffer to
//! the compositor with `eglSwapBuffers`.
//!
//! So the two files share a name, a path and a ROLE — "make the finished frame
//! visible" — while sharing no functions, because the work genuinely differs.
//! That is the case the mirror cannot unify, and pretending otherwise (inventing
//! an `identityRgba8` here) would be worse than saying so.
//!
//! Both call sites live in `window.zig`'s `run()`: the initial clear-only present
//! before the loop, and the present after each drawn frame.
//!
//! NOT pure: `EGL/egl.h` is a system header, so this file is kept out of the
//! cross-platform parity suite (unlike `linux/{keymap,input,adapter}.zig`) and
//! is exercised only by the Linux-only `native-test` step and `zig build`.

const c = @cImport({
    @cInclude("EGL/egl.h");
});

/// Hand the drawn back buffer to the compositor.
///
/// Takes `?*anyopaque` rather than `c.EGLDisplay`/`c.EGLSurface` on purpose:
/// both are `typedef void *` in EGL, and `window.zig` translates its own copy of
/// the EGL headers. Naming the underlying pointer type here keeps the two
/// `@cImport` instances from having to agree on a type identity.
///
/// The return value is discarded exactly as before — a failed swap is not fatal
/// and must not tear down the window.
pub fn present(display: ?*anyopaque, surface: ?*anyopaque) void {
    _ = c.eglSwapBuffers(display, surface);
}
