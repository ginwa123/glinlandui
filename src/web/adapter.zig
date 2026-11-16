//! Browser event adapter: the pure translation layer between DOM event properties and the toolkit's Delegate contract.
const std = @import("std");
const contract = @import("../core/window_contract.zig");

// ============================== coordinates ==============================

/// A pointer position in toolkit (top-left) space, with out-of-bounds values clamped.
pub const Point = struct {
    x: f32,
    y: f32,
};

/// Clamp a toolkit-space point into the view. No flip — see (1) above.
pub fn clampToView(width: u32, height: u32, x: f32, y: f32) Point {
    const w: f32 = @floatFromInt(width);
    const h: f32 = @floatFromInt(height);
    return .{
        .x = std.math.clamp(x, 0, @max(0, w)),
        .y = std.math.clamp(y, 0, @max(0, h)),
    };
}

/// True when a toolkit-space point is inside the view.
pub fn pointInView(width: u32, height: u32, x: f32, y: f32) bool {
    if (width == 0 or height == 0) return false;
    return x >= 0 and y >= 0 and
        x < @as(f32, @floatFromInt(width)) and
        y < @as(f32, @floatFromInt(height));
}

// ============================== scrolling ==============================

/// Clamp a normalised scroll delta to a sane range.
pub const max_scroll_step: f32 = 60.0;

pub fn clampScroll(d: f32) f32 {
    return std.math.clamp(d, -max_scroll_step, max_scroll_step);
}

/// `WheelEvent.deltaMode`.
pub const WheelDeltaMode = enum(u8) {
    pixel = 0,
    line = 1,
    page = 2,
    /// Anything else the DOM reports (there is no third value today, but a future addition must not be silently treated as pixels).
    _,

    pub fn fromInt(mode: i32) WheelDeltaMode {
        return switch (mode) {
            0 => .pixel,
            1 => .line,
            2 => .page,
            else => @enumFromInt(@as(u8, @truncate(@as(u32, @bitCast(mode))))),
        };
    }
};

/// One "line" in pixels for `deltaMode == line`.
pub const pixels_per_line: f32 = 16.0;

/// Normalise one wheel event to pixel deltas, then clamp.
pub fn scrollDelta(raw_dx: f32, raw_dy: f32, mode: WheelDeltaMode, viewport_h: u32) struct { dx: f32, dy: f32 } {
    const unit: f32 = switch (mode) {
        .pixel => 1.0,
        .line => pixels_per_line,
        .page => blk: {
            const h: f32 = @floatFromInt(viewport_h);
            break :blk if (h > 0) h else pixels_per_line;
        },
        _ => 1.0,
    };
    return .{ .dx = clampScroll(raw_dx * unit), .dy = clampScroll(raw_dy * unit) };
}

/// True when a wheel event carries nothing.
pub fn wheelIsNoop(dx: f32, dy: f32) bool {
    return dx == 0 and dy == 0;
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

/// Record a proposed size.
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

/// Mark the window as quitting (the page is going away, or a delegate request).
pub fn requestQuit(state: *contract.WindowState) void {
    state.quit = true;
}

// ===================== tests (parity suite — every platform) =====================

test "the browser's origin already matches the toolkit's, so nothing is flipped" {
    // The macOS mirror of this test asserts `flipY(400, 0) == 400`.
    const top = clampToView(400, 300, 10, 0);
    const bottom = clampToView(400, 300, 10, 300);
    try std.testing.expectEqual(@as(f32, 0), top.y);
    try std.testing.expectEqual(@as(f32, 300), bottom.y);
    try std.testing.expect(top.y < bottom.y);
}

test "clampToView bounds a drag that left the canvas" {
    // Pointer capture keeps delivering motion outside the element, so these coordinates are routine rather than pathological.
    const p = clampToView(200, 100, -5, 105);
    try std.testing.expectEqual(@as(f32, 0), p.x);
    try std.testing.expectEqual(@as(f32, 100), p.y);
    const q = clampToView(200, 100, 9999, -9999);
    try std.testing.expectEqual(@as(f32, 200), q.x);
    try std.testing.expectEqual(@as(f32, 0), q.y);
}

test "clampToView on a zero-sized canvas yields the origin, not NaN" {
    const p = clampToView(0, 0, 5, 5);
    try std.testing.expectEqual(@as(f32, 0), p.x);
    try std.testing.expectEqual(@as(f32, 0), p.y);
}

test "pointInView is exclusive on the far edge and rejects a zero size" {
    try std.testing.expect(pointInView(100, 100, 0, 0));
    try std.testing.expect(pointInView(100, 100, 99.9, 99.9));
    try std.testing.expect(!pointInView(100, 100, 100, 50));
    try std.testing.expect(!pointInView(100, 100, 50, 100));
    try std.testing.expect(!pointInView(100, 100, -1, 50));
    try std.testing.expect(!pointInView(0, 100, 0, 0));
    try std.testing.expect(!pointInView(100, 0, 0, 0));
}

test "pixel-mode wheel deltas are NOT negated, unlike AppKit's" {
    // THE sign regression guard.
    const d = scrollDelta(0, 10, .pixel, 300);
    try std.testing.expectEqual(@as(f32, 0), d.dx);
    try std.testing.expectEqual(@as(f32, 10), d.dy);
    try std.testing.expectEqual(@as(f32, -10), scrollDelta(0, -10, .pixel, 300).dy);
}

test "line-mode deltas become pixels the engines' way" {
    const d = scrollDelta(0, 3, .line, 300);
    try std.testing.expectEqual(@as(f32, 3 * pixels_per_line), d.dy);
    const x = scrollDelta(2, 0, .line, 300);
    try std.testing.expectEqual(@as(f32, 32), x.dx);
}

test "page-mode deltas use the viewport, and degrade to a line without one" {
    // A page notch is the viewport height — but the result is then CLAMPED to `max_scroll_step`, so a 300px viewport yields 60, not 300.
    try std.testing.expectEqual(max_scroll_step, scrollDelta(0, 1, .page, 300).dy);
    // A viewport smaller than the clamp passes through unclamped, which is what proves the viewport is actually being used rather than the clamp masking it.
    try std.testing.expectEqual(@as(f32, 40), scrollDelta(0, 1, .page, 40).dy);
    // Nothing laid out yet: a page notch that scrolls nothing at all reads as a broken wheel, so it degrades to a line step.
    try std.testing.expectEqual(@as(f32, pixels_per_line), scrollDelta(0, 1, .page, 0).dy);
}

test "an unknown deltaMode is treated as pixels rather than as zero" {
    // A future DOM addition must not silently freeze scrolling.
    const d = scrollDelta(0, 7, .fromInt(99), 300);
    try std.testing.expectEqual(@as(f32, 7), d.dy);
    try std.testing.expectEqual(WheelDeltaMode.pixel, WheelDeltaMode.fromInt(0));
    try std.testing.expectEqual(WheelDeltaMode.line, WheelDeltaMode.fromInt(1));
    try std.testing.expectEqual(WheelDeltaMode.page, WheelDeltaMode.fromInt(2));
}

test "a huge trackpad flick is clamped, not scaled" {
    try std.testing.expectEqual(max_scroll_step, clampScroll(9999));
    try std.testing.expectEqual(-max_scroll_step, clampScroll(-9999));
    try std.testing.expectEqual(@as(f32, 12), clampScroll(12));
    try std.testing.expectEqual(max_scroll_step, scrollDelta(0, 9999, .pixel, 300).dy);
    // Still positive after clamping: the clamp must not be mistaken for a sign.
    try std.testing.expect(scrollDelta(0, 9999, .pixel, 300).dy > 0);
}

test "a zero-delta wheel event is recognised as a no-op" {
    // Trackpads send a tail of these; each one would otherwise dirty the frame and force a full re-rasterization.
    try std.testing.expect(wheelIsNoop(0, 0));
    try std.testing.expect(!wheelIsNoop(0, 1));
    try std.testing.expect(!wheelIsNoop(-1, 0));
}

test "applyPendingResize does nothing when nothing is pending" {
    var st = contract.WindowState.init(.{ .width = 360, .height = 430 });
    try std.testing.expect(!applyPendingResize(&st));
    try std.testing.expectEqual(@as(u32, 360), st.win_w);
    try std.testing.expectEqual(@as(u32, 430), st.win_h);
}

test "a resize storm coalesces into a single applied size" {
    // What applyPendingResize is for: a window drag asserts a new element size every frame, and only the LAST one before a draw should be adopted.
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
    // Explicit minimums: the WindowConfig default of 520x360 would raise these proposals and defeat the point.
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
    try std.testing.expectEqual(@as(u32, 360), st.win_w);
    try std.testing.expectEqual(@as(usize, 0), rec.resizes);

    try std.testing.expect(applyPendingResize(&st));
    try std.testing.expectEqual(@as(u32, 379), st.win_w); // the LAST one wins
    try std.testing.expectEqual(@as(usize, 1), rec.resizes);
}

test "noteResize ignores a zero dimension instead of blanking the canvas" {
    // A `display: none` canvas measures 0x0.
    var st = contract.WindowState.init(.{ .width = 360, .height = 430 });
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
    var st = contract.WindowState.init(.{
        .width = 360,
        .height = 430,
        .min_width = 200,
        .min_height = 300,
    });
    _ = noteResize(&st, 360, 430);
    try std.testing.expect(!applyPendingResize(&st));
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

test "resolveQuit reports a backend-set flag and latches a delegate one" {
    var st = contract.WindowState.init(.{});
    try std.testing.expect(!resolveQuit(&st));
    requestQuit(&st);
    try std.testing.expect(st.quit);
    try std.testing.expect(resolveQuit(&st));

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
    var st2 = contract.WindowState.init(.{});
    st2.delegate = .{
        .ptr = undefined,
        .on_frame = Quit.onFrame,
        .on_pointer = Quit.onPointer,
        .on_key = Quit.onKey,
        .on_resize = Quit.onResize,
        .on_close = Quit.onClose,
        .is_quit = Quit.isQuit,
    };
    // Escape closes a browser tab's UI the same way it closes a native window.
    try std.testing.expect(resolveQuit(&st2));
    try std.testing.expect(st2.quit);
}
