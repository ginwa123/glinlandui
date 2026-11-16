//! Windows event adapter: the pure translation layer between Win32's event conventions and the toolkit's Delegate contract.

const std = @import("std");
const contract = @import("../core/window_contract.zig");

// ============================== coordinates ==============================

/// The defining property of the Win32 backend: client y already points DOWN from the top, so the toolkit's y is the client's y, unchanged.
pub fn identityYIsTopLeft(y: f32) f32 {
    return y;
}

/// A pointer position in toolkit space, with out-of-bounds values clamped.
pub const Point = struct {
    x: f32,
    y: f32,
};

/// Translate a Win32 client point into toolkit space, clamped to the client area.
pub fn toToolkitPoint(width: u32, height: u32, x: f32, y: f32) Point {
    const w: f32 = @floatFromInt(width);
    const h: f32 = @floatFromInt(height);
    return .{
        .x = std.math.clamp(x, 0, @max(0, w)),
        .y = std.math.clamp(y, 0, @max(0, h)),
    };
}

/// True when a toolkit-space point is inside the client area.
pub fn pointInView(width: u32, height: u32, x: f32, y: f32) bool {
    if (width == 0 or height == 0) return false;
    return x >= 0 and y >= 0 and
        x < @as(f32, @floatFromInt(width)) and
        y < @as(f32, @floatFromInt(height));
}

// ============================== scrolling ==============================

/// `WHEEL_DELTA` in winuser.h.
pub const wheel_delta: f32 = 120.0;

/// Clamp a raw scroll delta to a sane range.
pub const max_scroll_step: f32 = 60.0;

pub fn clampScroll(d: f32) f32 {
    return std.math.clamp(d, -max_scroll_step, max_scroll_step);
}

/// The Delegate's scroll contract: positive dy means "scroll DOWN".
pub fn scrollDelta(raw_dx: f32, raw_dy: f32) struct { dx: f32, dy: f32 } {
    return .{ .dx = clampScroll(raw_dx), .dy = clampScroll(raw_dy) };
}

// ============================== resizing ==============================

/// Apply a coalesced resize, at most once.
pub fn applyPendingResize(state: *contract.WindowState) bool {
    if (state.pending_w == 0 or state.pending_h == 0) return false;
    if (state.pending_w == state.win_w and state.pending_h == state.win_h) {
        // Nothing actually changed.
        state.pending_w = 0;
        state.pending_h = 0;
        return false;
    }
    state.win_w = state.pending_w;
    state.win_h = state.pending_h;
    state.pending_w = 0;
    state.pending_h = 0;
    if (state.delegate) |d| d.on_resize(d.ptr, state.win_w, state.win_h);
    return true;
}

/// Record a proposed size from `WM_SIZE`.
pub fn noteResize(state: *contract.WindowState, w: u32, h: u32) bool {
    if (w == 0 or h == 0) return false;
    const clamped = state.clamp(w, h);
    state.pending_w = clamped.w;
    state.pending_h = clamped.h;
    return true;
}

/// True when a size differs from the current one, so the caller can request a redraw only on a real change.
pub fn sizeChanged(state: *const contract.WindowState) bool {
    return state.pending_w != 0 and state.pending_h != 0 and
        (state.pending_w != state.win_w or state.pending_h != state.win_h);
}

// ============================== quit ==============================

/// Whether the window should stop.
pub fn resolveQuit(state: *contract.WindowState) bool {
    if (state.quit) return true;
    if (state.delegate) |d| {
        if (d.is_quit(d.ptr)) {
            state.quit = true;
            return true;
        }
    }
    return false;
}

/// Mark the window as quitting (the close button, or a delegate request).
pub fn requestQuit(state: *contract.WindowState) void {
    state.quit = true;
}

// ===================== tests (parity suite — every platform) =====================

test "client y needs no flip: y grows downwards from the top" {
    // THE property that distinguishes this backend from the macOS one.
    try std.testing.expectEqual(@as(f32, 0), identityYIsTopLeft(0));
    try std.testing.expectEqual(@as(f32, 120), identityYIsTopLeft(120));
    try std.testing.expectApproxEqAbs(@as(f32, 120), identityYIsTopLeft(119.6), 0.5);
}

test "toToolkitPoint is the identity for points already inside" {
    // Deliberately NOT `y = height - y`.
    const p = toToolkitPoint(360, 430, 123, 45);
    try std.testing.expectEqual(@as(f32, 123), p.x);
    try std.testing.expectEqual(@as(f32, 45), p.y);
}

test "toToolkitPoint clamps a drag that left the client area" {
    // With the capture set, WM_MOUSEMOVE keeps arriving with coordinates outside the client rect.
    const below = toToolkitPoint(200, 100, 50, 140);
    try std.testing.expectEqual(@as(f32, 50), below.x);
    try std.testing.expectEqual(@as(f32, 100), below.y);

    const left = toToolkitPoint(200, 100, -30, 50);
    try std.testing.expectEqual(@as(f32, 0), left.x);
    try std.testing.expectEqual(@as(f32, 50), left.y);

    const above_right = toToolkitPoint(200, 100, 500, -5);
    try std.testing.expectEqual(@as(f32, 200), above_right.x);
    try std.testing.expectEqual(@as(f32, 0), above_right.y);
}

test "toToolkitPoint on a zero-sized client yields the origin, not NaN" {
    // A minimized window reports 0x0; the arithmetic must not produce NaN.
    const p = toToolkitPoint(0, 0, 5, 5);
    try std.testing.expectEqual(@as(f32, 0), p.x);
    try std.testing.expectEqual(@as(f32, 0), p.y);
}

test "pointInView is exclusive on the far edge and rejects a zero size" {
    try std.testing.expect(pointInView(100, 100, 0, 0));
    try std.testing.expect(pointInView(100, 100, 99.9, 99.9));
    try std.testing.expect(!pointInView(100, 100, 100, 50));
    try std.testing.expect(!pointInView(100, 100, 50, 100));
    try std.testing.expect(!pointInView(100, 100, -1, 50));
    // A zero-sized client contains no points; without this the arithmetic would accept (0,0) and dispatch a click into a window that does not exist.
    try std.testing.expect(!pointInView(0, 100, 0, 0));
    try std.testing.expect(!pointInView(100, 0, 0, 0));
}

test "clampScroll bounds a high-resolution wheel flick" {
    try std.testing.expectEqual(max_scroll_step, clampScroll(9999));
    try std.testing.expectEqual(-max_scroll_step, clampScroll(-9999));
    try std.testing.expectEqual(@as(f32, 12), clampScroll(12));
    try std.testing.expectEqual(@as(f32, -12), clampScroll(-12));
    try std.testing.expectEqual(@as(f32, 0), clampScroll(0));
}

test "scrollDelta passes the shim's already-negated dy straight through" {
    // The shim negates WM_MOUSEWHEEL (positive = wheel away from user = scroll up) so that the toolkit's positive-dy-means-down convention holds.
    const one_notch_up = scrollDelta(0, -1);
    try std.testing.expectEqual(@as(f32, 0), one_notch_up.dx);
    try std.testing.expectEqual(@as(f32, -1), one_notch_up.dy);

    const one_notch_down = scrollDelta(0, 1);
    try std.testing.expectEqual(@as(f32, 1), one_notch_down.dy);
}

test "scrollDelta clamps in both axes without changing sign" {
    const d = scrollDelta(9999, -9999);
    try std.testing.expectEqual(max_scroll_step, d.dx);
    try std.testing.expectEqual(-max_scroll_step, d.dy);
}

test "one wheel detent is one scroll step" {
    // The shim divides by WHEEL_DELTA, so a single detent arrives as exactly 1.0 and must survive the clamp untouched.
    try std.testing.expectEqual(@as(f32, 1.0), scrollDelta(0, 1.0).dy);
    try std.testing.expectEqual(@as(f32, -1.0), scrollDelta(0, -1.0).dy);
    try std.testing.expect(wheel_delta == 120.0);
}

test "applyPendingResize does nothing when nothing is pending" {
    var st = contract.WindowState.init(.{ .width = 360, .height = 430 });
    try std.testing.expect(!applyPendingResize(&st));
    try std.testing.expectEqual(@as(u32, 360), st.win_w);
    try std.testing.expectEqual(@as(u32, 430), st.win_h);
}

test "applyPendingResize adopts the pending size and notifies once" {
    const Rec = struct {
        resizes: usize = 0,
        w: u32 = 0,
        h: u32 = 0,
        fn onFrame(_: *anyopaque, _: u32, _: u32) void {}
        fn onPointer(_: *anyopaque, _: f32, _: f32, _: bool, _: u32) void {}
        fn onKey(_: *anyopaque, _: u32, _: bool) bool {
            return false;
        }
        fn onResize(ptr: *anyopaque, w: u32, h: u32) void {
            const s: *@This() = @ptrCast(@alignCast(ptr));
            s.resizes += 1;
            s.w = w;
            s.h = h;
        }
        fn onClose(_: *anyopaque) void {}
        fn isQuit(_: *anyopaque) bool {
            return false;
        }
    };
    var rec = Rec{};
    var st = contract.WindowState.init(.{
        .width = 360,
        .height = 430,
        .min_width = 200,
        .min_height = 300,
    });
    st.delegate = .{
        .ptr = &rec,
        .on_frame = Rec.onFrame,
        .on_pointer = Rec.onPointer,
        .on_key = Rec.onKey,
        .on_resize = Rec.onResize,
        .on_close = Rec.onClose,
        .is_quit = Rec.isQuit,
    };

    _ = noteResize(&st, 500, 600);
    try std.testing.expect(applyPendingResize(&st));
    try std.testing.expectEqual(@as(u32, 500), st.win_w);
    try std.testing.expectEqual(@as(u32, 600), st.win_h);
    try std.testing.expectEqual(@as(usize, 1), rec.resizes);
    try std.testing.expectEqual(@as(u32, 500), rec.w);
    try std.testing.expectEqual(@as(u32, 600), rec.h);

    // A second apply has nothing pending, so it must not re-notify.
    try std.testing.expect(!applyPendingResize(&st));
    try std.testing.expectEqual(@as(usize, 1), rec.resizes);
}

test "a WM_SIZE storm coalesces into a single applied size" {
    // This is the point of applyPendingResize: a live drag sends many messages per frame.
    const Rec = struct {
        resizes: usize = 0,
        fn onFrame(_: *anyopaque, _: u32, _: u32) void {}
        fn onPointer(_: *anyopaque, _: f32, _: f32, _: bool, _: u32) void {}
        fn onKey(_: *anyopaque, _: u32, _: bool) bool {
            return false;
        }
        fn onResize(ptr: *anyopaque, _: u32, _: u32) void {
            const s: *@This() = @ptrCast(@alignCast(ptr));
            s.resizes += 1;
        }
        fn onClose(_: *anyopaque) void {}
        fn isQuit(_: *anyopaque) bool {
            return false;
        }
    };
    var rec = Rec{};
    var st = contract.WindowState.init(.{
        .width = 360,
        .height = 430,
        .min_width = 200,
        .min_height = 300,
    });
    st.delegate = .{
        .ptr = &rec,
        .on_frame = Rec.onFrame,
        .on_pointer = Rec.onPointer,
        .on_key = Rec.onKey,
        .on_resize = Rec.onResize,
        .on_close = Rec.onClose,
        .is_quit = Rec.isQuit,
    };

    for (360..380) |w| _ = noteResize(&st, @intCast(w), 430);
    // Nothing has been applied yet, so the window is still its old size.
    try std.testing.expectEqual(@as(u32, 360), st.win_w);
    try std.testing.expectEqual(@as(usize, 0), rec.resizes);

    try std.testing.expect(applyPendingResize(&st));
    try std.testing.expectEqual(@as(u32, 379), st.win_w); // the LAST one wins
    try std.testing.expectEqual(@as(usize, 1), rec.resizes);
}

test "noteResize ignores the 0x0 a minimized window reports" {
    // WM_SIZE with SIZE_MINIMIZED carries 0x0.
    var st = contract.WindowState.init(.{ .width = 360, .height = 430 });
    try std.testing.expect(!noteResize(&st, 0, 0));
    try std.testing.expect(!noteResize(&st, 0, 430));
    try std.testing.expect(!noteResize(&st, 360, 0));
    try std.testing.expect(!applyPendingResize(&st));
    try std.testing.expectEqual(@as(u32, 360), st.win_w);
    try std.testing.expectEqual(@as(u32, 430), st.win_h);
}

test "noteResize honours the config minimum" {
    var st = contract.WindowState.init(.{ .width = 360, .height = 430, .min_width = 200, .min_height = 300 });
    _ = noteResize(&st, 10, 10);
    try std.testing.expect(applyPendingResize(&st));
    try std.testing.expectEqual(@as(u32, 200), st.win_w);
    try std.testing.expectEqual(@as(u32, 300), st.win_h);
}

test "a pending size equal to the current one is dropped, not applied" {
    const Rec = struct {
        resizes: usize = 0,
        fn onFrame(_: *anyopaque, _: u32, _: u32) void {}
        fn onPointer(_: *anyopaque, _: f32, _: f32, _: bool, _: u32) void {}
        fn onKey(_: *anyopaque, _: u32, _: bool) bool {
            return false;
        }
        fn onResize(ptr: *anyopaque, _: u32, _: u32) void {
            const s: *@This() = @ptrCast(@alignCast(ptr));
            s.resizes += 1;
        }
        fn onClose(_: *anyopaque) void {}
        fn isQuit(_: *anyopaque) bool {
            return false;
        }
    };
    var rec = Rec{};
    // Explicit minimums: the WindowConfig default of 520x360 would raise the 360-wide proposal to 520, making it a real change and defeating the "same size.
    var st = contract.WindowState.init(.{
        .width = 360,
        .height = 430,
        .min_width = 200,
        .min_height = 300,
    });
    st.delegate = .{
        .ptr = &rec,
        .on_frame = Rec.onFrame,
        .on_pointer = Rec.onPointer,
        .on_key = Rec.onKey,
        .on_resize = Rec.onResize,
        .on_close = Rec.onClose,
        .is_quit = Rec.isQuit,
    };
    _ = noteResize(&st, 360, 430);
    try std.testing.expect(!applyPendingResize(&st));
    try std.testing.expectEqual(@as(usize, 0), rec.resizes);
    // And the stale pending pair was cleared, so it cannot fire later.
    try std.testing.expectEqual(@as(u32, 0), st.pending_w);
    try std.testing.expectEqual(@as(u32, 0), st.pending_h);
}

test "sizeChanged is true only for a real, usable change" {
    var st = contract.WindowState.init(.{
        .width = 360,
        .height = 430,
        .min_width = 200,
        .min_height = 300,
    });
    try std.testing.expect(!sizeChanged(&st));
    _ = noteResize(&st, 360, 430);
    try std.testing.expect(!sizeChanged(&st)); // same size
    _ = noteResize(&st, 400, 430);
    try std.testing.expect(sizeChanged(&st));
}

test "resolveQuit reports the backend's own quit flag" {
    var st = contract.WindowState.init(.{});
    try std.testing.expect(!resolveQuit(&st));
    requestQuit(&st);
    try std.testing.expect(st.quit);
    try std.testing.expect(resolveQuit(&st));
}

test "resolveQuit latches a delegate-driven quit" {
    // Escape goes through `keyToClose` and sets the delegate's quit flag; the window must notice and stop without the close button being used.
    const Quit = struct {
        fn onFrame(_: *anyopaque, _: u32, _: u32) void {}
        fn onPointer(_: *anyopaque, _: f32, _: f32, _: bool, _: u32) void {}
        fn onKey(_: *anyopaque, _: u32, _: bool) bool {
            return false;
        }
        fn onResize(_: *anyopaque, _: u32, _: u32) void {}
        fn onClose(_: *anyopaque) void {}
        fn isQuit(_: *anyopaque) bool {
            return true;
        }
    };
    var st = contract.WindowState.init(.{});
    st.delegate = .{
        .ptr = undefined,
        .on_frame = Quit.onFrame,
        .on_pointer = Quit.onPointer,
        .on_key = Quit.onKey,
        .on_resize = Quit.onResize,
        .on_close = Quit.onClose,
        .is_quit = Quit.isQuit,
    };
    try std.testing.expect(resolveQuit(&st));
    // Latched: the backend's own flag is set too, so it stays quit.
    try std.testing.expect(st.quit);
    try std.testing.expect(resolveQuit(&st));
}
