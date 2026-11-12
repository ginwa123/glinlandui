//! Frame -> screen for Linux — the `present.zig` half of the platform mirror.

const c = @cImport({
    @cInclude("EGL/egl.h");
});

/// Hand the drawn back buffer to the compositor.
pub fn present(display: ?*anyopaque, surface: ?*anyopaque) void {
    _ = c.eglSwapBuffers(display, surface);
}
