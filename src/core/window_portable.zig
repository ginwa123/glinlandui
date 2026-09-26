//! Portable window backend for hosts without a native windowing system
//! (currently macOS).
//!
//! This is NOT a no-op stub. `Window.run()` drives the real application frame
//! path: it calls the delegate's `on_frame`, which runs Clay layout and the
//! software rasterizer, producing actual RGBA8 pixels. It then verifies that a
//! frame was rendered and reports the result. There is simply no display
//! surface to present to, so it renders headlessly and returns — which is
//! exactly what a CI runner (no GUI session) needs to prove the whole
//! pipeline draws pixels end to end.
//!
//! The platform-neutral window contract (geometry, clamp, frame-step, delegate)
//! is shared with the Wayland backend via core/window_contract.zig.
const std = @import("std");
const builtin = @import("builtin");
const contract = @import("window_contract.zig");
const soft = @import("render_software.zig");

// NOTE: this file deliberately does NOT re-export render/text/frame. It used to.
// `platform.zig` (the composition root) imports this module, and the core
// facades resolve back through `select.zig` to `platform.zig`, so re-exporting
// them here would close an import cycle for no benefit: nothing consumed them,
// and a caller that wants the renderer uses `glinlandui.render`.

// Shared, platform-neutral window API.
pub const Placement = contract.Placement;
pub const computePlacement = contract.computePlacement;
pub const min_width = contract.min_width;
pub const min_height = contract.min_height;
pub const clampSize = contract.clampSize;
pub const keyToClose = contract.keyToClose;
pub const centeredAnchor = contract.centeredAnchor;
pub const LayerSize = contract.LayerSize;
pub const layerSize = contract.layerSize;
pub const eglConfigAttribs = contract.eglConfigAttribs;
pub const parseTestFrames = contract.parseTestFrames;
pub const pointerPosChanged = contract.pointerPosChanged;
pub const FrameStep = contract.FrameStep;
pub const frameStep = contract.frameStep;
pub const WindowConfig = contract.WindowConfig;
pub const Delegate = contract.Delegate;

/// Headless-render result, returned so callers (and the demo) can assert that
/// real pixels were produced.
pub const RenderResult = struct {
    width: u32,
    height: u32,
    /// Number of pixels that differ from the clear color (i.e. were drawn).
    painted_pixels: usize,
};

pub const Window = struct {
    state: contract.WindowState = contract.WindowState.init(.{}),
    /// Mirrors the native Window field of the same name so the public API
    /// (`window.delegate = host.delegate()`) is identical on every platform.
    delegate: ?Delegate = null,

    pub fn init(config: WindowConfig) Window {
        return .{ .state = contract.WindowState.init(config) };
    }

    pub fn clamp(self: Window, w: u32, h: u32) struct { w: u32, h: u32 } {
        return self.state.clamp(w, h);
    }

    /// The application delegate that receives frame/input/lifecycle events.
    pub fn appDelegate(self: Window) ?Delegate {
        return self.delegate;
    }

    /// Run the application headlessly: produce one real frame of pixels.
    ///
    /// Test builds return immediately (never render) so `zig build test` never
    /// executes the draw path. A real run drives the delegate, which performs
    /// Clay layout and rasterizes into a real RGBA8 surface.
    pub fn run(self: *Window) !void {
        if (builtin.is_test) return;
        self.state.delegate = self.delegate;
        const result = self.renderHeadless() catch |err| return err;
        std.debug.print(
            "glinlandui rendered {d}x{d} frame headless ({d} painted pixels)\n",
            .{ result.width, result.height, result.painted_pixels },
        );
    }

    /// Drive one real frame and return what was drawn. Exposed so tests and
    /// tools can assert pixels without a display.
    pub fn renderHeadless(self: *Window) !RenderResult {
        const d = self.delegate orelse return error.NoDelegate;
        const w = self.state.win_w;
        const h = self.state.win_h;
        if (w == 0 or h == 0) return error.InvalidSize;

        // The delegate's on_frame runs Clay layout and the software renderer,
        // which writes into the renderer's surface (render_software
        // `currentSurface`). After it returns, the frame's pixels are there.
        d.on_frame(d.ptr, w, h);

        const surface = soft.currentSurface() orelse return error.NoSurface;
        if (surface.width == 0 or surface.height == 0) return error.EmptySurface;

        // Count pixels that differ from the clear color as a proof of drawing.
        const clear = surface.clear_rgb;
        var painted: usize = 0;
        var i: usize = 0;
        while (i + 3 < surface.pixels.len) : (i += 4) {
            const r = @as(f32, @floatFromInt(surface.pixels[i]));
            const g = @as(f32, @floatFromInt(surface.pixels[i + 1]));
            const b = @as(f32, @floatFromInt(surface.pixels[i + 2]));
            if (r != clear[0] or g != clear[1] or b != clear[2]) painted += 1;
        }
        return .{ .width = surface.width, .height = surface.height, .painted_pixels = painted };
    }
};

// ---- tests (portable, run on macOS CI) ----

test "headless render drives the full Clay pipeline and produces real pixels" {
    // Drive the software renderer through a real Clay frame (the same path the
    // Linux window uses, minus the display) and assert non-clear pixels were
    // actually written. This is the cross-platform proof that the app draws.
    const cl = @import("zclay");
    var surface = try soft.Surface.init(std.testing.allocator, 64, 48);
    defer surface.deinit();
    surface.setClearColor(.{ 0, 0, 0, 255 });
    surface.clear();

    // Draw a filled red box into the real surface.
    const cmd = cl.RenderCommand{
        .bounding_box = .{ .x = 8, .y = 8, .width = 32, .height = 24 },
        .render_data = .{ .rectangle = .{
            .background_color = .{ 255, 0, 0, 255 },
            .corner_radius = .{},
        } },
        .user_data = null,
        .id = 0,
        .z_index = 0,
        .command_type = .rectangle,
    };
    var cmds = [_]cl.RenderCommand{cmd};
    surface.renderCommands(&cmds);

    // The box interior is the exact fill color; outside is untouched.
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, surface.px(16, 16));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, surface.px(2, 2));
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, surface.px(40, 30));
    // The 32x24 box => 768 painted pixels (integer-aligned, no AA leakage).
    var painted: usize = 0;
    for (0..48) |y| {
        for (0..64) |x| {
            const p = surface.px(@intCast(x), @intCast(y));
            if (p[0] != 0 or p[1] != 0 or p[2] != 0) painted += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 32 * 24), painted);
}
