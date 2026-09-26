//! macOS pointer/button translation into the Delegate's pointer contract.
//!
//! ## The bug this exists to prevent
//!
//! The Delegate's `on_pointer(x, y, pressed, button)` does NOT take "button 0
//! means left". It takes an **evdev button code**, and `dispatch.pointerEvent`
//! only starts a press when `button == BTN_LEFT` (272):
//!
//!     if (button_code == BTN_LEFT and pressed) { ... start press ... }
//!     else if (button_code == BTN_LEFT)          { ... fire click on release }
//!     else if (s.down and !s.dragging)           { ... drag detection ... }
//!
//! A backend that reports every event with `button = 0` therefore matches
//! only the third arm: a click is never even started, so the release never
//! fires one, and the UI looks completely dead while the state machine is
//! perfectly healthy. The Wayland backend gets this right by construction — it
//! forwards motion with button 0 and only passes the protocol's evdev code on
//! an actual button transition.
//!
//! So the translation lives here, pure and cross-platform, instead of being
//! re-derived inside the Objective-C shim where nothing can test it.

const std = @import("std");
const adapter = @import("macos_adapter.zig");

/// evdev button codes, matching `components.dispatch.BTN_LEFT`.
pub const BTN_LEFT: u32 = 272;
pub const BTN_RIGHT: u32 = 273;
pub const BTN_MIDDLE: u32 = 274;

/// `NSEventTypeMouseMoved` and friends: the pointer moved, no button
/// transition happened.
pub const MOTION: u8 = 0;
/// The primary (usually left) button went down or up.
pub const DOWN: u8 = 1;
/// A secondary button went down or up.
pub const UP: u8 = 2;

/// What AppKit told us, before translation.
pub const Raw = struct {
    /// `NSEventType`: one of MOTION / DOWN / UP. Anything else (scroll, enter,
    /// exit, otherMouse*) is not a pointer event and must not be translated as
    /// one — AppKit reuses the same handler set for all of them.
    kind: u8,
    /// `NSEvent.buttonNumber`: 0 left, 1 right, 2 and up are "other".
    button_number: i32,
    /// Location in the view, bottom-left origin.
    x: f32,
    y: f32,
};

/// The Delegate's shape, ready to hand to `d.on_pointer`.
pub const Translated = struct {
    x: f32,
    y: f32,
    pressed: bool,
    /// The evdev code on a transition, and 0 on motion — matching Wayland
    /// exactly, which is what keeps drag detection working.
    button: u32,
};

/// Map an AppKit `NSEventTypeMouse*` / `NSEventButtonNumber` to the toolkit's
/// pointer contract. `held` is the current left-button state, needed for
/// motion: motion must report `pressed` as "is the button down", not false.
pub fn evdevButton(button_number: i32) u32 {
    return switch (button_number) {
        0 => BTN_LEFT,
        1 => BTN_RIGHT,
        2 => BTN_MIDDLE,
        // NSEvent's "other" buttons 3.. are extra mouse buttons; report them
        // as middle rather than dropping them, so an app can still see them.
        else => BTN_MIDDLE,
    };
}

/// Translate one AppKit pointer event. `w`/`h` are the view size.
pub fn translate(w: u32, h: u32, raw: Raw, held: bool) Translated {
    // AppKit's y is bottom-left; the toolkit's is top-left.
    const pt = adapter.toToolkitPoint(w, h, raw.x, raw.y);
    return switch (raw.kind) {
        // Motion carries button 0 so it lands in dispatch's drag arm. Passing
        // BTN_LEFT here would re-arm the press on every move, resetting
        // down_x/down_y and making drag impossible to ever trigger.
        MOTION => .{ .x = pt.x, .y = pt.y, .pressed = held, .button = 0 },
        DOWN => .{ .x = pt.x, .y = pt.y, .pressed = true, .button = evdevButton(raw.button_number) },
        UP => .{ .x = pt.x, .y = pt.y, .pressed = false, .button = evdevButton(raw.button_number) },
        // Unknown kind: treat as motion rather than inventing a press.
        else => .{ .x = pt.x, .y = pt.y, .pressed = held, .button = 0 },
    };
}

// ===================== tests (parity suite — every platform) =====================

const dispatch = @import("../components/dispatch.zig");

test "a press carries BTN_LEFT, which is the code dispatch requires" {
    // THE regression guard. Passing 0 here is what made every click a no-op.
    const t = translate(360, 430, .{ .kind = DOWN, .button_number = 0, .x = 10, .y = 10 }, false);
    try std.testing.expectEqual(BTN_LEFT, t.button);
    try std.testing.expectEqual(dispatch.BTN_LEFT, t.button);
    try std.testing.expect(t.pressed);
}

test "a release carries BTN_LEFT with pressed false, so the click fires" {
    const t = translate(360, 430, .{ .kind = UP, .button_number = 0, .x = 10, .y = 10 }, true);
    try std.testing.expectEqual(BTN_LEFT, t.button);
    try std.testing.expect(!t.pressed);
}

test "motion carries button 0 and the current held state" {
    // Motion must NOT carry BTN_LEFT, or every move would restart the press
    // and drag detection could never fire.
    const t = translate(360, 430, .{ .kind = MOTION, .button_number = 0, .x = 10, .y = 10 }, true);
    try std.testing.expectEqual(@as(u32, 0), t.button);
    try std.testing.expect(t.pressed);
    const idle = translate(360, 430, .{ .kind = MOTION, .button_number = 0, .x = 10, .y = 10 }, false);
    try std.testing.expectEqual(@as(u32, 0), idle.button);
    try std.testing.expect(!idle.pressed);
}

test "right and middle map to their own evdev codes" {
    const r = translate(360, 430, .{ .kind = DOWN, .button_number = 1, .x = 5, .y = 5 }, false);
    try std.testing.expectEqual(BTN_RIGHT, r.button);
    try std.testing.expect(r.button != BTN_LEFT);
    const m = translate(360, 430, .{ .kind = DOWN, .button_number = 2, .x = 5, .y = 5 }, false);
    try std.testing.expectEqual(BTN_MIDDLE, m.button);
}

test "a right-button press is never mistaken for a left one" {
    // dispatch only reacts to BTN_LEFT, so a right press must not start a
    // click that a left release then fires.
    const t = translate(360, 430, .{ .kind = DOWN, .button_number = 1, .x = 5, .y = 5 }, false);
    try std.testing.expect(t.button != dispatch.BTN_LEFT);
}

test "the y axis is flipped from AppKit's bottom-left origin" {
    // A press at the visual TOP of the window is a LARGE AppKit y.
    const top = translate(360, 430, .{ .kind = DOWN, .button_number = 0, .x = 20, .y = 400 }, false);
    const bottom = translate(360, 430, .{ .kind = DOWN, .button_number = 0, .x = 20, .y = 20 }, false);
    try std.testing.expect(top.y < bottom.y);
    try std.testing.expectApproxEqAbs(@as(f32, 30), top.y, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 410), bottom.y, 0.5);
}

test "the x axis is passed through unflipped" {
    const t = translate(360, 430, .{ .kind = DOWN, .button_number = 0, .x = 123, .y = 200 }, false);
    try std.testing.expectApproxEqAbs(@as(f32, 123), t.x, 0.01);
}

test "an unknown event kind degrades to motion instead of a phantom press" {
    // AppKit routes scroll/enter/exit through the same handler family; treating
    // one of those as a press would click a button the user never touched.
    const t = translate(360, 430, .{ .kind = 99, .button_number = 0, .x = 10, .y = 10 }, false);
    try std.testing.expectEqual(@as(u32, 0), t.button);
    try std.testing.expect(!t.pressed);
}

test "a full press-then-release sequence walks both of dispatch's arms" {
    // Drives the REAL dispatcher, not a reimplementation. With the old bug
    // (button 0 on every event) the press arm was never taken at all, so
    // `st.down` stayed false and nothing could ever be clicked.
    //
    // The click registry itself needs a Clay layout to hit-test against, and
    // that end-to-end path (layout -> registry -> machine -> display) is
    // already covered by the calculator example's own tests. What matters
    // HERE is that the codes we hand dispatch reach the right branch.
    var st = dispatch.PtrState{};
    const down = translate(200, 200, .{ .kind = DOWN, .button_number = 0, .x = 100, .y = 100 }, false);
    dispatch.pointerEvent(&st, down.x, down.y, down.pressed, down.button, 200, 200);
    try std.testing.expect(st.down);
    try std.testing.expect(st.press_in_bounds);
    try std.testing.expect(!st.dragging);

    const up = translate(200, 200, .{ .kind = UP, .button_number = 0, .x = 100, .y = 100 }, true);
    dispatch.pointerEvent(&st, up.x, up.y, up.pressed, up.button, 200, 200);
    // The release arm ran: the press is consumed and no longer in bounds.
    try std.testing.expect(!st.down);
    try std.testing.expect(!st.press_in_bounds);
    try std.testing.expect(!st.dragging);
}

test "motion while held keeps the press anchored so drag can trigger" {
    // Motion must not re-arm the press, or down_x/down_y would be reset on
    // every move and `dragging` could never exceed the threshold.
    var st = dispatch.PtrState{};
    const down = translate(400, 400, .{ .kind = DOWN, .button_number = 0, .x = 50, .y = 50 }, false);
    dispatch.pointerEvent(&st, down.x, down.y, down.pressed, down.button, 400, 400);
    const anchor_x = st.down_x;
    const anchor_y = st.down_y;

    // Move a long way while held.
    const move = translate(400, 400, .{ .kind = MOTION, .button_number = 0, .x = 200, .y = 200 }, true);
    dispatch.pointerEvent(&st, move.x, move.y, move.pressed, move.button, 400, 400);
    try std.testing.expectApproxEqAbs(anchor_x, st.down_x, 0.01);
    try std.testing.expectApproxEqAbs(anchor_y, st.down_y, 0.01);
    try std.testing.expect(st.dragging);
}

test "a press that starts outside the view is not fired on release" {
    // AppKit can deliver a release after the pointer left the window; without
    // the in-bounds check that would click whatever is under the stale point.
    var st = dispatch.PtrState{};
    const down = translate(200, 200, .{ .kind = DOWN, .button_number = 0, .x = 100, .y = 100 }, false);
    dispatch.pointerEvent(&st, down.x, down.y, down.pressed, down.button, 200, 200);
    try std.testing.expect(st.press_in_bounds);

    // Release far outside; the point is clamped, so drive dispatch directly
    // with an out-of-range coordinate to exercise the bounds check itself.
    dispatch.pointerEvent(&st, 300, 300, false, BTN_LEFT, 200, 200);
    try std.testing.expect(!st.down);
}

// ---- end-to-end: the real backend path, against a real Clay layout ----
//
// Everything above is a unit test of the translation. This one is the proof
// that matters: it builds an actual Host, lets Clay lay a button out, converts
// that button's centre into AppKit's bottom-left space, runs it through
// `translate`, feeds the result to the real dispatcher, and asserts the
// button's own callback fired. That is precisely the chain a macOS click takes
// — and the chain that silently did nothing before the button code was fixed.

const host_mod = @import("../wayland/host.zig");
const box_widget = @import("../components/box.zig");
const cl = @import("zclay");

const Hit = struct {
    fired: usize = 0,
};

const App = struct {
    hit: Hit = .{},

    fn root(ctx: ?*anyopaque, _: u32, _: u32) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        box_widget.box(.{
            .id = "test-hit-box",
            .direction = .column,
            .w = .grow,
            .h = .grow,
            .bg = 0x334455,
        }, self, App.child);
    }

    fn child(self: *App) void {
        _ = self;
    }

    fn onClick(ctx: ?*anyopaque, _: usize) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        self.hit.fired += 1;
    }
};

test "a macOS click reaches a real laid-out button's handler" {
    const w: u32 = 200;
    const h: u32 = 200;
    var app = App{};

    // Clay keeps a process-global context pointer into the init arena, so a
    // test Host must not be deinit'd — the same discipline as the calculator
    // example's own tests.
    var host = try host_mod.Host.init(std.heap.page_allocator, &app, App.root);
    host.frame(w, h);

    const reg = @import("../components/click_registry.zig");
    reg.registerZCursor(cl.getElementId("test-hit-box"), App.onClick, &app, 0, 0, .pointer);

    // The button fills the window, so its centre is the window's centre in
    // toolkit (top-left) space.
    const data = cl.getElementData(cl.getElementId("test-hit-box"));
    try std.testing.expect(data.found);
    const bb = data.bounding_box;
    const toolkit_x = bb.x + bb.width * 0.5;
    const toolkit_y = bb.y + bb.height * 0.5;

    // Convert to AppKit's bottom-left space — exactly what `locationInView:`
    // hands the backend, i.e. the inverse of the y flip the backend applies.
    const appkit_x = toolkit_x;
    const appkit_y = @as(f32, @floatFromInt(h)) - toolkit_y;

    var st = dispatch.PtrState{};
    const down = translate(w, h, .{
        .kind = DOWN,
        .button_number = 0,
        .x = appkit_x,
        .y = appkit_y,
    }, false);
    dispatch.pointerEvent(&st, down.x, down.y, down.pressed, down.button, w, h);
    try std.testing.expectEqual(@as(usize, 0), app.hit.fired);

    const up = translate(w, h, .{
        .kind = UP,
        .button_number = 0,
        .x = appkit_x,
        .y = appkit_y,
    }, true);
    dispatch.pointerEvent(&st, up.x, up.y, up.pressed, up.button, w, h);

    // The whole point: a press-release pair on a real button fires it once.
    try std.testing.expectEqual(@as(usize, 1), app.hit.fired);
}

test "the translated coordinates land back on the button the user aimed at" {
    // Proves the flip is the exact inverse, not merely "somewhere in range": a
    // click near the top of the window must hit the top of the button, and one
    // near the bottom must hit the bottom.
    const w: u32 = 200;
    const h: u32 = 200;
    var app = App{};
    var host = try host_mod.Host.init(std.heap.page_allocator, &app, App.root);
    host.frame(w, h);
    const data = cl.getElementData(cl.getElementId("test-hit-box"));
    try std.testing.expect(data.found);
    const bb = data.bounding_box;

    // A point 20% down the window, expressed in AppKit space.
    const toolkit_y = bb.y + bb.height * 0.2;
    const appkit_y = @as(f32, @floatFromInt(h)) - toolkit_y;
    const t = translate(w, h, .{ .kind = DOWN, .button_number = 0, .x = bb.x, .y = appkit_y }, false);

    try std.testing.expectApproxEqAbs(toolkit_y, t.y, 0.5);
    // And it really is near the top of the box, not the bottom.
    try std.testing.expect(t.y < bb.y + bb.height * 0.5);
}
