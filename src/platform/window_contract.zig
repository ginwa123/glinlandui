//! Shared, platform-neutral window contract + tests.
//!
//! Everything in this module is pure Zig with no C imports, no Wayland
//! objects, and no windowing system. Both the native Wayland backend and the
//! macOS/CoreGraphics backend build on exactly these definitions, and the
//! tests here run IDENTICALLY on both platforms. This is what makes the
//! test count equal across operating systems: the window contract is tested
//! once, in one place, with one set of expected values.
const std = @import("std");
const consts = @import("protocol_consts.zig");

/// Centered top-left corner of the default 720x480 window.
pub const Placement = struct {
    x: i32,
    y: i32,
};

/// 5.1: center the 720x480 window in the output; clamp to 0,0 when the
/// output is smaller than the window.
pub fn computePlacement(out_w: u32, out_h: u32) Placement {
    const x: i32 = if (out_w > 720) @intCast((out_w - 720) / 2) else 0;
    const y: i32 = if (out_h > 480) @intCast((out_h - 480) / 2) else 0;
    return .{ .x = x, .y = y };
}

/// Tiled window size limits: min 520x360. A 0 dimension means the
/// compositor defers to the client -> keep the default size.
pub const min_width: u32 = 520;
pub const min_height: u32 = 360;

pub fn clampSize(w: u32, h: u32) struct { w: u32, h: u32 } {
    const cw = if (w == 0) 720 else @max(w, min_width);
    const ch = if (h == 0) 480 else @max(h, min_height);
    return .{ .w = cw, .h = ch };
}

/// Escape closes the window. Accepts the linux input-event-codes keycode
/// (1) and the wl_keyboard keysym (0xff1b).
pub fn keyToClose(keycode: u32) bool {
    return keycode == 1 or keycode == 0xff1b;
}

/// Legacy (layer-shell era): centred anchor = all four edges.
pub fn centeredAnchor() u32 {
    return consts.LayerAnchor.top |
        consts.LayerAnchor.bottom |
        consts.LayerAnchor.left |
        consts.LayerAnchor.right;
}

/// Legacy fixed surface size 720x480.
pub const LayerSize = struct {
    w: u32,
    h: u32,
};

pub fn layerSize() LayerSize {
    return .{ .w = 720, .h = 480 };
}

/// The canonical EGL config attribute list (shared, platform-neutral).
pub const eglConfigAttribs = consts.eglConfigAttribs;

/// Parse QS_SETTINGS_TEST_FRAMES — null/empty/invalid means "run forever".
pub fn parseTestFrames(env: ?[]const u8) ?u32 {
    const s = env orelse return null;
    if (s.len == 0) return null;
    return std.fmt.parseInt(u32, s, 10) catch null;
}

/// Engine-side motion dedup (memoized immediate, input half): hover floods
/// and sub-pixel repeats must not dirty the frame loop.
pub fn pointerPosChanged(old_x: f32, old_y: f32, new_x: f32, new_y: f32) bool {
    const ox: i32 = @intFromFloat(@floor(old_x));
    const oy: i32 = @intFromFloat(@floor(old_y));
    const nx: i32 = @intFromFloat(@floor(new_x));
    const ny: i32 = @intFromFloat(@floor(new_y));
    return ox != nx or oy != ny;
}

/// Wayland 24.8 fixed-point → float. Portable so both platforms test the
/// same conversion.
pub fn fixedToFloat(f: i32) f32 {
    return @as(f32, @floatFromInt(f)) / 256.0;
}

/// On-demand frame scheduler decision (pure, unit-tested).
pub const FrameStep = enum { draw, kick, idle };

pub fn frameStep(frame_done: bool, needs_draw: bool, frame_pending: bool) FrameStep {
    if (frame_done and needs_draw) return .draw;
    if (frame_done) return .idle;
    if (needs_draw and !frame_pending) return .kick;
    return .idle;
}

/// Toolkit-style window configuration shared by both backends.
pub const WindowConfig = struct {
    app_id: [*:0]const u8 = "qs-settings",
    title: [*:0]const u8 = "Settings",
    width: u32 = 720,
    height: u32 = 480,
    min_width: u32 = 520,
    min_height: u32 = 360,
};

/// UI delegate: the backend owns the window/present; the delegate draws in
/// on_frame and receives input/lifecycle callbacks.
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

/// A backend-neutral window: the state every backend shares. The native
/// Wayland Window and the macOS Window both hold one of these and add their
/// platform objects alongside it.
pub const WindowState = struct {
    config: WindowConfig,
    delegate: ?Delegate = null,
    win_w: u32,
    win_h: u32,
    pending_w: u32 = 0,
    pending_h: u32 = 0,
    quit: bool = false,
    frame_done: bool = false,
    configured: bool = false,
    needs_draw: bool = true,
    frame_pending: bool = false,
    last_shape: u32 = consts.CursorShape.default,

    pub fn init(config: WindowConfig) WindowState {
        return .{
            .config = config,
            .win_w = config.width,
            .win_h = config.height,
        };
    }

    /// 0 in a dimension defers to the client -> config default size;
    /// otherwise max(dim, config min).
    pub fn clamp(self: WindowState, w: u32, h: u32) struct { w: u32, h: u32 } {
        const cw = if (w == 0) self.config.width else @max(w, self.config.min_width);
        const ch = if (h == 0) self.config.height else @max(h, self.config.min_height);
        return .{ .w = cw, .h = ch };
    }
};

// ===================== tests (identical on every platform) =====================

test "computePlacement centers 720x480 in 1920x1080" {
    const p = computePlacement(1920, 1080);
    try std.testing.expectEqual(@as(i32, 600), p.x);
    try std.testing.expectEqual(@as(i32, 300), p.y);
}

test "computePlacement centers 720x480 in 1280x720" {
    const p = computePlacement(1280, 720);
    try std.testing.expectEqual(@as(i32, 280), p.x);
    try std.testing.expectEqual(@as(i32, 120), p.y);
}

test "computePlacement clamps smaller output to 0,0" {
    const p = computePlacement(640, 400);
    try std.testing.expectEqual(@as(i32, 0), p.x);
    try std.testing.expectEqual(@as(i32, 0), p.y);
}

test "keyToClose accepts Escape keycode 1 and keysym 0xff1b" {
    try std.testing.expect(keyToClose(1));
    try std.testing.expect(keyToClose(0xff1b));
    try std.testing.expect(!keyToClose(30));
    try std.testing.expect(!keyToClose(9));
}

test "frameStep draws only on dirty frames, kicks when dirty-idle, idles otherwise" {
    try std.testing.expectEqual(FrameStep.draw, frameStep(true, true, false));
    try std.testing.expectEqual(FrameStep.draw, frameStep(true, true, true));
    try std.testing.expectEqual(FrameStep.idle, frameStep(true, false, false));
    try std.testing.expectEqual(FrameStep.idle, frameStep(true, false, true));
    try std.testing.expectEqual(FrameStep.kick, frameStep(false, true, false));
    try std.testing.expectEqual(FrameStep.idle, frameStep(false, true, true));
    try std.testing.expectEqual(FrameStep.idle, frameStep(false, false, false));
    try std.testing.expectEqual(FrameStep.idle, frameStep(false, false, true));
}

test "pointerPosChanged dedups identical hover events" {
    try std.testing.expect(!pointerPosChanged(10.5, 20.5, 10.5, 20.5));
    try std.testing.expect(pointerPosChanged(10.5, 20.5, 11.5, 20.5));
    try std.testing.expect(pointerPosChanged(10.5, 20.5, 10.5, 21.5));
    try std.testing.expect(!pointerPosChanged(0, 0, 0.00390625, 0));
    try std.testing.expect(!pointerPosChanged(10.1, 20.9, 10.9, 20.1));
    try std.testing.expect(pointerPosChanged(10.9, 20.9, 11.1, 20.9));
}

test "centeredAnchor sets all four edges (TOP|BOTTOM|LEFT|RIGHT = 15)" {
    try std.testing.expectEqual(@as(u32, 15), centeredAnchor());
    try std.testing.expect(centeredAnchor() & consts.LayerAnchor.top != 0);
    try std.testing.expect(centeredAnchor() & consts.LayerAnchor.bottom != 0);
    try std.testing.expect(centeredAnchor() & consts.LayerAnchor.left != 0);
    try std.testing.expect(centeredAnchor() & consts.LayerAnchor.right != 0);
}

test "layerSize matches theme 720x480" {
    const sz = layerSize();
    try std.testing.expectEqual(@as(u32, 720), sz.w);
    try std.testing.expectEqual(@as(u32, 480), sz.h);
}

test "delegate defaults to null (headless no-op)" {
    const win = WindowState.init(.{});
    try std.testing.expect(win.delegate == null);
}

test "attached delegate round-trips on_key/on_close/is_quit" {
    const State = struct {
        quit: bool = false,
        frames: u32 = 0,
        last_w: u32 = 0,
        last_h: u32 = 0,
    };
    const fns = struct {
        fn onFrame(ptr: *anyopaque, w: u32, h: u32) void {
            const s: *State = @ptrCast(@alignCast(ptr));
            s.frames += 1;
            s.last_w = w;
            s.last_h = h;
        }
        fn onPointer(_: *anyopaque, _: f32, _: f32, _: bool, _: u32) void {}
        fn onKey(ptr: *anyopaque, keycode: u32, pressed: bool) bool {
            const s: *State = @ptrCast(@alignCast(ptr));
            if (pressed and keyToClose(keycode)) {
                s.quit = true;
                return true;
            }
            return false;
        }
        fn onResize(_: *anyopaque, _: u32, _: u32) void {}
        fn onClose(ptr: *anyopaque) void {
            const s: *State = @ptrCast(@alignCast(ptr));
            s.quit = true;
        }
        fn isQuit(ptr: *anyopaque) bool {
            const s: *State = @ptrCast(@alignCast(ptr));
            return s.quit;
        }
    };
    var state = State{};
    var win = WindowState.init(.{});
    win.delegate = .{
        .ptr = &state,
        .on_frame = fns.onFrame,
        .on_pointer = fns.onPointer,
        .on_key = fns.onKey,
        .on_resize = fns.onResize,
        .on_close = fns.onClose,
        .is_quit = fns.isQuit,
    };
    const d = win.delegate.?;
    d.on_frame(d.ptr, 720, 480);
    try std.testing.expectEqual(@as(u32, 1), state.frames);
    try std.testing.expectEqual(@as(u32, 720), state.last_w);
    try std.testing.expect(!d.on_key(d.ptr, 30, true));
    try std.testing.expect(!d.is_quit(d.ptr));
    try std.testing.expect(!d.on_key(d.ptr, 1, false));
    try std.testing.expect(!d.is_quit(d.ptr));
    try std.testing.expect(d.on_key(d.ptr, 1, true));
    try std.testing.expect(d.is_quit(d.ptr));
}

test "eglConfigAttribs requests RGBA8 ES3 window surface terminated by NONE" {
    const a = eglConfigAttribs();
    try std.testing.expect(a[a.len - 1] == consts.EglAttrib.none);
    var red: i32 = -1;
    var green: i32 = -1;
    var blue: i32 = -1;
    var alpha: i32 = -1;
    var surface_type: i32 = -1;
    var renderable: i32 = -1;
    var i: usize = 0;
    while (i + 1 < a.len) : (i += 2) {
        if (a[i] == consts.EglAttrib.none) break;
        if (a[i] == consts.EglAttrib.red_size) red = a[i + 1];
        if (a[i] == consts.EglAttrib.green_size) green = a[i + 1];
        if (a[i] == consts.EglAttrib.blue_size) blue = a[i + 1];
        if (a[i] == consts.EglAttrib.alpha_size) alpha = a[i + 1];
        if (a[i] == consts.EglAttrib.surface_type) surface_type = a[i + 1];
        if (a[i] == consts.EglAttrib.renderable_type) renderable = a[i + 1];
    }
    try std.testing.expectEqual(@as(i32, 8), red);
    try std.testing.expectEqual(@as(i32, 8), green);
    try std.testing.expectEqual(@as(i32, 8), blue);
    try std.testing.expectEqual(@as(i32, 8), alpha);
    try std.testing.expect(surface_type & consts.EglConfigValue.window_bit != 0);
    try std.testing.expect(renderable & consts.EglConfigValue.openGL_es3_bit != 0);
}

test "parseTestFrames parses N, rejects null/empty/invalid" {
    try std.testing.expectEqual(@as(?u32, 5), parseTestFrames("5"));
    try std.testing.expectEqual(@as(?u32, 0), parseTestFrames("0"));
    try std.testing.expectEqual(@as(?u32, null), parseTestFrames(null));
    try std.testing.expectEqual(@as(?u32, null), parseTestFrames(""));
    try std.testing.expectEqual(@as(?u32, null), parseTestFrames("abc"));
}

test "fixedToFloat converts 24.8 fixed-point to float" {
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), fixedToFloat(256), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), fixedToFloat(128), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), fixedToFloat(0), 1e-6);
}

test "clampSize enforces min 520x360, 0 defers to client size" {
    const win = WindowState.init(.{});
    try std.testing.expectEqual(@as(u32, 720), win.clamp(0, 0).w);
    try std.testing.expectEqual(@as(u32, 480), win.clamp(0, 0).h);
    try std.testing.expectEqual(@as(u32, 520), win.clamp(100, 100).w);
    try std.testing.expectEqual(@as(u32, 360), win.clamp(100, 100).h);
    try std.testing.expectEqual(@as(u32, 1000), win.clamp(1000, 700).w);
    try std.testing.expectEqual(@as(u32, 700), win.clamp(1000, 700).h);
    try std.testing.expectEqual(@as(u32, 720), clampSize(0, 0).w);
    try std.testing.expectEqual(@as(u32, 520), clampSize(100, 100).w);
}

test "WindowState.init stores custom config" {
    const win = WindowState.init(.{
        .app_id = "qs-settings",
        .title = "Settings",
        .width = 800,
        .height = 600,
    });
    try std.testing.expectEqualStrings("qs-settings", std.mem.span(win.config.app_id));
    try std.testing.expectEqualStrings("Settings", std.mem.span(win.config.title));
    try std.testing.expectEqual(@as(u32, 800), win.config.width);
    try std.testing.expectEqual(@as(u32, 600), win.config.height);
    try std.testing.expectEqual(@as(u32, 800), win.win_w);
    try std.testing.expectEqual(@as(u32, 600), win.win_h);
}

test "Window defaults are 720x480 + 520/360 (literals; see ui/theme.zig)" {
    const win = WindowState.init(.{});
    try std.testing.expectEqual(@as(u32, 720), win.config.width);
    try std.testing.expectEqual(@as(u32, 480), win.config.height);
    try std.testing.expectEqual(@as(u32, 520), win.config.min_width);
    try std.testing.expectEqual(@as(u32, 360), win.config.min_height);
    try std.testing.expectEqualStrings("qs-settings", std.mem.span(win.config.app_id));
    try std.testing.expectEqualStrings("Settings", std.mem.span(win.config.title));
    try std.testing.expect(win.delegate == null);
    try std.testing.expect(win.needs_draw);
}

test "Window.clamp honors custom mins" {
    const win = WindowState.init(.{ .width = 720, .height = 480, .min_width = 520, .min_height = 360 });
    try std.testing.expectEqual(@as(u32, 720), win.clamp(0, 0).w);
    try std.testing.expectEqual(@as(u32, 480), win.clamp(0, 0).h);
    try std.testing.expectEqual(@as(u32, 520), win.clamp(100, 100).w);
    try std.testing.expectEqual(@as(u32, 360), win.clamp(100, 100).h);
    try std.testing.expectEqual(@as(u32, 1000), win.clamp(1000, 700).w);
    try std.testing.expectEqual(@as(u32, 700), win.clamp(1000, 700).h);
    const custom = WindowState.init(.{ .width = 800, .height = 600, .min_width = 400, .min_height = 300 });
    try std.testing.expectEqual(@as(u32, 400), custom.clamp(100, 100).w);
    try std.testing.expectEqual(@as(u32, 300), custom.clamp(100, 100).h);
    try std.testing.expectEqual(@as(u32, 800), custom.clamp(0, 0).w);
    try std.testing.expectEqual(@as(u32, 600), custom.clamp(0, 0).h);
}

test "cursor shape mapping matches protocol constants" {
    try std.testing.expectEqual(consts.CursorShape.default, @as(u32, 1));
    try std.testing.expectEqual(consts.CursorShape.pointer, @as(u32, 4));
    try std.testing.expectEqual(consts.CursorShape.text, @as(u32, 9));
    try std.testing.expectEqual(consts.CursorShape.ew_resize, @as(u32, 26));
}
