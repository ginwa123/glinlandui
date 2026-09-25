//! CPU-only platform window for hosts without the native Wayland client stack.
//!
//! This is intentionally a portability seam, not a macOS UI backend. Window
//! configuration, geometry helpers, and the delegate contract match the Linux
//! API, so the library surface, Clay frame pipeline, and headless test harness
//! are all exercised by macOS CI. Calling run returns a precise error rather
//! than silently pretending a native window exists.
const std = @import("std");

pub const render = @import("wayland/render.zig");
pub const text = @import("wayland/text_backend.zig");
pub const frame = @import("wayland/frame.zig");

/// Centered top-left corner of the 720x480 window.
pub const Placement = struct {
    x: i32,
    y: i32,
};

pub fn computePlacement(out_w: u32, out_h: u32) Placement {
    const x: i32 = if (out_w > 720) @intCast((out_w - 720) / 2) else 0;
    const y: i32 = if (out_h > 480) @intCast((out_h - 480) / 2) else 0;
    return .{ .x = x, .y = y };
}

pub const min_width: u32 = 520;
pub const min_height: u32 = 360;

pub fn clampSize(w: u32, h: u32) struct { w: u32, h: u32 } {
    const cw = if (w == 0) 720 else @max(w, min_width);
    const ch = if (h == 0) 480 else @max(h, min_height);
    return .{ .w = cw, .h = ch };
}

pub fn keyToClose(keycode: u32) bool {
    return keycode == 1 or keycode == 0xff1b;
}

/// Numeric equivalent of the legacy layer-shell top|bottom|left|right mask.
pub fn centeredAnchor() u32 {
    return 1 | 2 | 4 | 8;
}

pub const LayerSize = struct {
    w: u32,
    h: u32,
};

pub fn layerSize() LayerSize {
    return .{ .w = 720, .h = 480 };
}

/// CPU builds do not create an EGL configuration. The return type keeps the
/// Linux root export source-compatible for consumers that reference it.
pub fn eglConfigAttribs() [13]i32 {
    return .{
        8, 8, // EGL_RED_SIZE, EGL_GREEN_SIZE
        8, 8, // EGL_BLUE_SIZE, EGL_ALPHA_SIZE
        0x3038, 0x00000001, // EGL_SURFACE_TYPE, EGL_WINDOW_BIT
        0x3040, 0x00000040, // EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT
        0x3038, 0x3038, 0x3038, // EGL_NONE
        0,      0,
    };
}

pub fn parseTestFrames(env: ?[]const u8) ?u32 {
    const s = env orelse return null;
    if (s.len == 0) return null;
    return std.fmt.parseInt(u32, s, 10) catch null;
}

pub const WindowConfig = struct {
    app_id: [*:0]const u8 = "qs-settings",
    title: [*:0]const u8 = "Settings",
    width: u32 = 720,
    height: u32 = 480,
    min_width: u32 = 520,
    min_height: u32 = 360,
};

pub const Delegate = struct {
    ptr: *anyopaque,
    on_frame: *const fn (*anyopaque, w: u32, h: u32) void,
    on_pointer: *const fn (*anyopaque, x: f32, y: f32, pressed: bool, button: u32) void,
    on_scroll: ?*const fn (*anyopaque, dx: f32, dy: f32) void = null,
    on_key: *const fn (*anyopaque, keycode: u32, pressed: bool) bool,
    on_resize: *const fn (*anyopaque, w: u32, h: u32) void,
    on_close: *const fn (*anyopaque) void,
    is_quit: *const fn (*anyopaque) bool,
};

pub const Window = struct {
    config: WindowConfig,
    delegate: ?Delegate = null,

    pub fn init(config: WindowConfig) Window {
        return .{ .config = config };
    }

    pub fn clamp(self: Window, w: u32, h: u32) struct { w: u32, h: u32 } {
        const cw = if (w == 0) self.config.width else @max(w, self.config.min_width);
        const ch = if (h == 0) self.config.height else @max(h, self.config.min_height);
        return .{ .w = cw, .h = ch };
    }

    /// No native window is created on this backend.
    pub fn run(self: *Window) !void {
        _ = self;
        return error.UnsupportedPlatform;
    }
};

test "portable window applies the documented geometry policy" {
    const window = Window.init(.{ .width = 800, .height = 640, .min_width = 500, .min_height = 400 });
    try std.testing.expectEqual(@as(u32, 800), window.clamp(0, 0).w);
    try std.testing.expectEqual(@as(u32, 640), window.clamp(0, 0).h);
    try std.testing.expectEqual(@as(u32, 500), window.clamp(100, 100).w);
    try std.testing.expectEqual(@as(u32, 400), window.clamp(100, 100).h);
}

test "portable placement centers larger outputs and clamps small outputs" {
    try std.testing.expectEqual(Placement{ .x = 140, .y = 60 }, computePlacement(1000, 600));
    try std.testing.expectEqual(Placement{ .x = 0, .y = 0 }, computePlacement(640, 480));
}
