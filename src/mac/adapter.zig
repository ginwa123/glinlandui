//! macOS event adapter: the pure translation layer between AppKit's event
//! coordinates and the toolkit's Delegate contract.
//!
//! AppKit and the toolkit disagree in ways that all fail *silently* — the
//! window still renders, clicks simply do not land where they are drawn. So
//! every translation lives here, in a module with no Cocoa, and is unit-tested
//! on every platform.
//!
//! The three disagreements:
//!
//!  1. ORIGIN. AppKit reports pointer y from the BOTTOM of the view; Clay and
//!     the Delegate use the TOP. Forgetting this mirrors the UI vertically:
//!     clicking the top row presses the bottom row's key.
//!  2. RESIZE COALESCING. A live window drag delivers dozens of resize
//!     events per second. Applying each one reallocates and relayouts, so the
//!     window stutters and ends up rendering at a size the user never saw.
//!     `applyPendingResize` applies at most one, at draw time.
//!  3. SCROLL MAGNITUDE. AppKit's scroll deltas are in points and are
//!     unconstrained; Wayland's are small fixed steps. Passing them through
//!     unchanged makes scrolling on macOS jump an entire list per notch.

const std = @import("std");
const contract = @import("../core/window_contract.zig");

// ============================== coordinates ==============================

/// Convert an AppKit (bottom-left origin) pointer y to the toolkit's top-left
/// origin: `y' = height - y`.
///
/// This is the single highest-consequence line in the macOS backend. A window
/// that omits it renders correctly and responds to clicks on the mirrored
/// row, which reads to a user as "the buttons are broken" rather than "the y
/// axis is inverted".
pub fn flipY(height: u32, y: f32) f32 {
    return @as(f32, @floatFromInt(height)) - y;
}

/// A pointer position in toolkit (top-left) space, with out-of-bounds values
/// clamped. Clamping matters because AppKit can report a y one point outside
/// the view while the pointer sits on the window's resize border; an
/// unclamped y would be fed to hit-testing and could match a neighbouring
/// element.
pub const Point = struct {
    x: f32,
    y: f32,
};

/// Translate an AppKit event location into toolkit space, clamped to the view.
pub fn toToolkitPoint(width: u32, height: u32, x: f32, y: f32) Point {
    const w: f32 = @floatFromInt(width);
    const h: f32 = @floatFromInt(height);
    return .{
        .x = std.math.clamp(x, 0, @max(0, w)),
        .y = std.math.clamp(flipY(height, y), 0, @max(0, h)),
    };
}

/// True when a toolkit-space point is inside the view. Used to ignore motion
/// delivered while the pointer is outside the window.
pub fn pointInView(width: u32, height: u32, x: f32, y: f32) bool {
    if (width == 0 or height == 0) return false;
    return x >= 0 and y >= 0 and
        x < @as(f32, @floatFromInt(width)) and
        y < @as(f32, @floatFromInt(height));
}

// ============================== scrolling ==============================

/// Clamp a raw AppKit scroll delta to a sane range. AppKit reports points, and
/// a trackpad flick can produce deltas in the hundreds in a single event.
/// Wayland's are small steps, so the toolkit's scroll views were tuned for
/// those; feeding macOS's raw values through makes one flick jump the whole
/// list. This is a pure clamp, not a scaling factor, so it degrades to
/// "scrolls further" rather than "scrolls at the wrong speed" when the OS
/// already reports sane values.
pub const max_scroll_step: f32 = 60.0;

pub fn clampScroll(d: f32) f32 {
    return std.math.clamp(d, -max_scroll_step, max_scroll_step);
}

/// AppKit's `NSScrollingDeltaY` is positive for content moving UP (scrolling
/// down the list), the opposite of the toolkit's convention, where positive
/// dy means "scroll down". Negating therefore aligns the two backends.
pub fn scrollDelta(raw_dx: f32, raw_dy: f32) struct { dx: f32, dy: f32 } {
    return .{ .dx = clampScroll(raw_dx), .dy = -clampScroll(raw_dy) };
}

// ============================== resizing ==============================

/// Apply a coalesced resize, at most once.
///
/// AppKit reports the proposed size; the toolkit should adopt it when it next
/// draws, not on every event. A drag therefore produces one resize per drawn
/// frame instead of one per event, and `delegate.on_resize` fires exactly
/// once per applied size.
///
/// Returns true when a resize was applied (and the delegate notified), false
/// when there was nothing pending or the pending size matches the current one.
pub fn applyPendingResize(state: *contract.WindowState) bool {
    if (state.pending_w == 0 or state.pending_h == 0) return false;
    if (state.pending_w == state.win_w and state.pending_h == state.win_h) {
        // Nothing actually changed. Clear the pending pair anyway so a stale
        // value cannot fire much later against an unrelated resize.
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

/// Record a proposed size from AppKit. Sizes that clamp to nothing usable
/// (0 in either dimension, which AppKit sends while a window is being
/// minimised) are ignored so they cannot blank the window.
pub fn noteResize(state: *contract.WindowState, w: u32, h: u32) bool {
    if (w == 0 or h == 0) return false;
    const clamped = state.clamp(w, h);
    state.pending_w = clamped.w;
    state.pending_h = clamped.h;
    return true;
}

/// True when a size differs from the current one, so the caller can request a
/// redraw only on a real change.
pub fn sizeChanged(state: *const contract.WindowState) bool {
    return state.pending_w != 0 and state.pending_h != 0 and
        (state.pending_w != state.win_w or state.pending_h != state.win_h);
}

// ============================== quit ==============================

/// Whether the window should stop. The backend's own flag is authoritative
/// (the close button sets it); the delegate's `is_quit` is checked too so an
/// app that quits itself (Escape through `keyToClose`, a "Quit" button) stops
/// without the backend having to guess.
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

test "flipY maps the bottom of the view to the bottom of toolkit space" {
    // A click at the very bottom of the view (AppKit y == 0) is the LAST row
    // in toolkit space, so the flipped y must equal the height.
    try std.testing.expectEqual(@as(f32, 400), flipY(400, 0));
    try std.testing.expectEqual(@as(f32, 0), flipY(400, 400));
}

test "flipY mirrors about the vertical centre" {
    try std.testing.expectEqual(@as(f32, 300), flipY(400, 100));
    try std.testing.expectEqual(@as(f32, 100), flipY(400, 300));
}

test "flipY is an involution" {
    // Applying it twice must return the original y, for any height. This is
    // the property that proves it is a pure mirror and not a scaling.
    for ([_]u32{ 1, 430, 720, 1000 }) |h| {
        for ([_]f32{ 0, 1.5, 99, 200 }) |y| {
            const there = flipY(h, y);
            const back = flipY(h, there);
            try std.testing.expectApproxEqAbs(y, back, 0.0001);
        }
    }
}

test "the keypad's top row and bottom row do not collide after a flip" {
    // A 4x5 keypad in a 430-tall window. The FIRST key row is near the top
    // and the LAST near the bottom. If flipY were missing or a no-op, both
    // would land in the same half of the window.
    const h: u32 = 430;
    const top_row_center_appkit: f32 = 120; // near the top in AppKit space
    const bottom_row_center_appkit: f32 = 310; // near the bottom
    const top = flipY(h, top_row_center_appkit);
    const bottom = flipY(h, bottom_row_center_appkit);
    // AppKit says the top row is at 120; toolkit space must place it near 430.
    try std.testing.expect(top > bottom);
    try std.testing.expectApproxEqAbs(@as(f32, 310), top, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 120), bottom, 0.5);
}

test "toToolkitPoint translates and clamps into the view" {
    // Bottom-left corner of a 200x100 view -> top-left of toolkit space.
    const p = toToolkitPoint(200, 100, 10, 0);
    try std.testing.expectEqual(@as(f32, 10), p.x);
    try std.testing.expectEqual(@as(f32, 100), p.y);
}

test "toToolkitPoint clamps a y just outside the view" {
    // AppKit reports y == height while the pointer sits on the resize border.
    // Unclamped, that y would be handed to hit-testing and could match a
    // neighbouring element.
    const p = toToolkitPoint(200, 100, 10, 105);
    // AppKit y == 105 is 5pt ABOVE the top edge (origin is at the bottom), so
    // the toolkit-space y is 100 - 105 = -5, which clamps to the top edge.
    try std.testing.expectEqual(@as(f32, 0), p.y);
    try std.testing.expectEqual(@as(f32, 10), p.x);
}

test "toToolkitPoint clamps a negative x" {
    const p = toToolkitPoint(200, 100, -5, 50);
    try std.testing.expectEqual(@as(f32, 0), p.x);
    try std.testing.expectEqual(@as(f32, 50), p.y);
}

test "toToolkitPoint on a zero-sized view yields the origin, not NaN" {
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
    // A zero-sized view contains no points; without this the arithmetic would
    // accept (0,0) and dispatch a click into a window that does not exist.
    try std.testing.expect(!pointInView(0, 100, 0, 0));
    try std.testing.expect(!pointInView(100, 0, 0, 0));
}

test "clampScroll bounds a huge trackpad flick" {
    try std.testing.expectEqual(max_scroll_step, clampScroll(9999));
    try std.testing.expectEqual(-max_scroll_step, clampScroll(-9999));
    // Values already in range pass through untouched.
    try std.testing.expectEqual(@as(f32, 12), clampScroll(12));
    try std.testing.expectEqual(@as(f32, -12), clampScroll(-12));
    try std.testing.expectEqual(@as(f32, 0), clampScroll(0));
}

test "scrollDelta negates dy to match the toolkit's convention" {
    // The toolkit uses positive dy = scroll DOWN. AppKit's scrollingDeltaY is
    // positive for the opposite, so a missing negation scrolls the wrong way.
    const d = scrollDelta(0, 10);
    try std.testing.expectEqual(@as(f32, 0), d.dx);
    try std.testing.expectEqual(@as(f32, -10), d.dy);
    try std.testing.expectEqual(@as(f32, 10), scrollDelta(0, -10).dy);
}

test "scrollDelta clamps and negates together" {
    const d = scrollDelta(9999, 9999);
    try std.testing.expectEqual(max_scroll_step, d.dx);
    try std.testing.expectEqual(-max_scroll_step, d.dy);
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
    // min_* are explicit because the WindowConfig default is 520x360, which
    // would silently raise the 500-wide proposal below.
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

test "a resize storm coalesces into a single applied size" {
    // This is the point of applyPendingResize: AppKit sends many events per
    // drag frame. Only the LAST one should be adopted, and the delegate
    // notified once.
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

    // 20 proposed sizes arrive before any draw.
    for (360..380) |w| _ = noteResize(&st, @intCast(w), 430);
    // Nothing has been applied yet, so the window is still its old size.
    try std.testing.expectEqual(@as(u32, 360), st.win_w);
    try std.testing.expectEqual(@as(usize, 0), rec.resizes);

    try std.testing.expect(applyPendingResize(&st));
    try std.testing.expectEqual(@as(u32, 379), st.win_w); // the LAST one wins
    try std.testing.expectEqual(@as(usize, 1), rec.resizes);
}

test "noteResize ignores a zero dimension instead of blanking the window" {
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
    // Explicit minimums: the WindowConfig default of 520x360 would raise the
    // 360-wide proposal to 520, making it a real change and defeating the
    // "same size is dropped" intent of this test.
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
    // Escape goes through `keyToClose` and sets the delegate's quit flag; the
    // window must notice and stop without the close button being used.
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
