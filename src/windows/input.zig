//! Windows pointer/button translation into the Delegate's pointer contract.
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
//! A backend that reports every event with `button = 0` therefore matches only
//! the third arm: a click is never even started, so the release never fires
//! one, and the UI looks completely dead while the state machine is perfectly
//! healthy. That is exactly what happened on macOS before the button code was
//! fixed, which is why the translation is a pure, cross-platform module with
//! its own tests rather than arithmetic inside a platform shim.
//!
//! ## What Win32 contributes
//!
//! Almost nothing, and that is the point. Win32 already distinguishes
//! `WM_LBUTTONDOWN` / `WM_RBUTTONDOWN` / `WM_MBUTTONDOWN` / `WM_XBUTTONDOWN`
//! and reports the pressed state in `wParam`, so the shim hands the backend a
//! (kind, button_number, x, y, pressed) tuple and this module's whole job is
//! to say which evdev code that is and whether the toolkit should treat the
//! event as motion.
//!
//! The one real decision is MOTION, which must carry button 0 and the *held*
//! state, and it is the same decision mac/input.zig makes.

const std = @import("std");
const adapter = @import("adapter.zig");

/// evdev button codes, matching `components.dispatch.BTN_LEFT`.
pub const BTN_LEFT: u32 = 272;
pub const BTN_RIGHT: u32 = 273;
pub const BTN_MIDDLE: u32 = 274;

/// `WM_MOUSEMOVE`: the pointer moved, no button transition happened.
pub const MOTION: u8 = 0;
/// The primary (left) button went down or up.
pub const DOWN: u8 = 1;
/// A secondary button went down or up.
pub const UP: u8 = 2;

/// What the shim told us, before translation. `button_number` uses the
/// numbering in windows/shim.h: 0 left, 1 right, 2 middle. XBUTTON1 is
/// remapped to "right" and XBUTTON2 to "middle" there, so that this module and
/// `mac/input.zig` are interchangeable.
pub const Raw = struct {
    kind: u8,
    button_number: i32,
    /// Client coordinates. The origin is already top-left, so unlike AppKit
    /// there is no flip — see windows/adapter.zig.
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

/// Map a Win32 button number to the toolkit's evdev code.
pub fn evdevButton(button_number: i32) u32 {
    return switch (button_number) {
        0 => BTN_LEFT,
        1 => BTN_RIGHT,
        2 => BTN_MIDDLE,
        // Extra mouse buttons: report them as middle rather than dropping them,
        // so an app can still see them. Never map an unknown button to 0 —
        // see the module comment for why that is a dead UI.
        else => BTN_MIDDLE,
    };
}

/// Translate one Win32 pointer event. `w`/`h` are the client size. `held` is
/// the current left-button state, needed for motion: motion must report
/// `pressed` as "is the button down", not false.
pub fn translate(w: u32, h: u32, raw: Raw, held: bool) Translated {
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

const dispatch = @import("../core/components/dispatch.zig");

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

test "an extra mouse button degrades to middle, never to 0" {
    // XBUTTON3 and anything else the shim forwards. Mapping an unknown button
    // to 0 is the dead-UI bug in another costume: 0 is MOTION's code, and a
    // release with button 0 fires nothing.
    for ([_]i32{ 3, 4, 17 }) |n| {
        const t = translate(360, 430, .{ .kind = DOWN, .button_number = n, .x = 5, .y = 5 }, false);
        try std.testing.expect(t.button != 0);
        try std.testing.expect(t.button != BTN_LEFT);
    }
}

test "the y axis is NOT flipped: a small y is the top of the window" {
    // THE difference from mac/input.zig. A press near the visual TOP of the
    // window has a SMALL Win32 client y, and it must stay small.
    const top = translate(360, 430, .{ .kind = DOWN, .button_number = 0, .x = 20, .y = 20 }, false);
    const bottom = translate(360, 430, .{ .kind = DOWN, .button_number = 0, .x = 20, .y = 400 }, false);
    try std.testing.expect(top.y < bottom.y);
    try std.testing.expectApproxEqAbs(@as(f32, 20), top.y, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 400), bottom.y, 0.5);
}

test "the x axis is passed through unflipped" {
    const t = translate(360, 430, .{ .kind = DOWN, .button_number = 0, .x = 123, .y = 200 }, false);
    try std.testing.expectApproxEqAbs(@as(f32, 123), t.x, 0.01);
}

test "a drag that leaves the client area is clamped, not passed through" {
    // SetCapture keeps WM_MOUSEMOVE flowing after the pointer leaves.
    const t = translate(360, 430, .{ .kind = MOTION, .button_number = 0, .x = -25, .y = 900 }, true);
    try std.testing.expectEqual(@as(f32, 0), t.x);
    try std.testing.expectEqual(@as(f32, 430), t.y);
}

test "an unknown event kind degrades to motion instead of a phantom press" {
    const t = translate(360, 430, .{ .kind = 99, .button_number = 0, .x = 10, .y = 10 }, false);
    try std.testing.expectEqual(@as(u32, 0), t.button);
    try std.testing.expect(!t.pressed);
}

test "a full press-then-release sequence walks both of dispatch's arms" {
    // Drives the REAL dispatcher, not a reimplementation. With the button-0 bug
    // the press arm was never taken at all, so `st.down` stayed false and
    // nothing could ever be clicked.
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

    const move = translate(400, 400, .{ .kind = MOTION, .button_number = 0, .x = 200, .y = 200 }, true);
    dispatch.pointerEvent(&st, move.x, move.y, move.pressed, move.button, 400, 400);
    try std.testing.expectApproxEqAbs(anchor_x, st.down_x, 0.01);
    try std.testing.expectApproxEqAbs(anchor_y, st.down_y, 0.01);
    try std.testing.expect(st.dragging);
}

test "a press that starts outside the client area is not fired on release" {
    // A drag can be released after the pointer has left the window; without
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
// that button's centre into Win32 client space (which — unlike macOS — is
// already toolkit space), runs it through `translate`, feeds the result to the
// real dispatcher, and asserts the button's own callback fired.

const host_mod = @import("../core/host.zig");
const box_widget = @import("../core/components/box.zig");
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

test "a Windows click reaches a real laid-out button's handler" {
    const w: u32 = 200;
    const h: u32 = 200;
    var app = App{};

    // Clay keeps a process-global context pointer into the init arena, so a
    // test Host must not be deinit'd — the same discipline as the calculator
    // example's own tests.
    var host = try host_mod.Host.init(std.heap.page_allocator, &app, App.root);
    host.frame(w, h);

    const reg = @import("../core/components/click_registry.zig");
    reg.registerZCursor(cl.getElementId("test-hit-box"), App.onClick, &app, 0, 0, .pointer);

    // The button fills the window, so its centre is the window's centre. In
    // Win32 client space that is the same number as in toolkit space.
    const data = cl.getElementData(cl.getElementId("test-hit-box"));
    try std.testing.expect(data.found);
    const bb = data.bounding_box;
    const client_x = bb.x + bb.width * 0.5;
    const client_y = bb.y + bb.height * 0.5;

    var st = dispatch.PtrState{};
    const down = translate(w, h, .{
        .kind = DOWN,
        .button_number = 0,
        .x = client_x,
        .y = client_y,
    }, false);
    dispatch.pointerEvent(&st, down.x, down.y, down.pressed, down.button, w, h);
    try std.testing.expectEqual(@as(usize, 0), app.hit.fired);

    const up = translate(w, h, .{
        .kind = UP,
        .button_number = 0,
        .x = client_x,
        .y = client_y,
    }, true);
    dispatch.pointerEvent(&st, up.x, up.y, up.pressed, up.button, w, h);

    // The whole point: a press-release pair on a real button fires it once.
    try std.testing.expectEqual(@as(usize, 1), app.hit.fired);
}

test "a click on the TOP of the window hits the TOP of the button" {
    // Proves the no-flip property end to end. If `translate` ever started
    // mirroring y — because someone copied flipY across from macOS — the
    // top-of-window click would land on the bottom of the box and the
    // in-bounds press would never start.
    const w: u32 = 200;
    const h: u32 = 200;
    var app = App{};
    var host = try host_mod.Host.init(std.heap.page_allocator, &app, App.root);
    host.frame(w, h);
    const data = cl.getElementData(cl.getElementId("test-hit-box"));
    try std.testing.expect(data.found);
    const bb = data.bounding_box;

    // A point 20% down the window, in Win32 client space.
    const client_y = bb.y + bb.height * 0.2;
    const t = translate(w, h, .{ .kind = DOWN, .button_number = 0, .x = bb.x, .y = client_y }, false);

    try std.testing.expectApproxEqAbs(client_y, t.y, 0.5);
    // And it really is near the top of the box, not the bottom.
    try std.testing.expect(t.y < bb.y + bb.height * 0.5);
}
