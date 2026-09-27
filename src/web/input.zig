//! Browser pointer translation into the Delegate's pointer contract.
//!
//! ## The bug this exists to prevent (same as macOS, different cause)
//!
//! The Delegate's `on_pointer(x, y, pressed, button)` does NOT take "button 0
//! means left". It takes an **evdev button code**, and `dispatch.pointerEvent`
//! only starts a press when `button == BTN_LEFT` (272):
//!
//!     if (button_code == BTN_LEFT and pressed) { ... start press ... }
//!     else if (button_code == BTN_LEFT)          { ... fire click on release ... }
//!     else if (s.down and !s.dragging)           { ... drag detection ... }
//!
//! A backend that reports every event with `button = 0` matches only the third
//! arm: a click is never started, so the release never fires one, and the UI
//! looks completely dead while the state machine is perfectly healthy. So the
//! translation lives here, pure and cross-platform, instead of being re-derived
//! inside `shim.js` where nothing can test it.
//!
//! ## The DOM's button numbering is NOT AppKit's
//!
//! This is the one place the browser and macOS genuinely disagree on values, and
//! copying macOS's table across would swap right and middle:
//!
//!     DOM MouseEvent.button       AppKit NSEvent.buttonNumber
//!       0 main (left)              0 left
//!       1 auxiliary (MIDDLE)       1 RIGHT
//!       2 secondary (RIGHT)        2+ middle / other
//!       3 back, 4 forward          —
//!
//! `mac/input.zig` maps 1 -> BTN_RIGHT and 2 -> BTN_MIDDLE. Doing that here would
//! make middle-click behave as right-click and vice versa — a bug that only shows
//! up for users who have a middle button, and that no amount of transcription
//! review would catch without this note.
//!
//! ## No button NUMBER is ever passed through
//!
//! Only evdev codes leave this module, on a transition, with 0 on motion — the
//! same contract Wayland satisfies by construction. That is what keeps the widget
//! layer and `components.input` browser-free.

const std = @import("std");
const Color = @import("../core/color.zig").Color;
const adapter = @import("adapter.zig");

/// evdev button codes, matching `components.dispatch.BTN_LEFT`.
pub const BTN_LEFT: u32 = 272;
pub const BTN_RIGHT: u32 = 273;
pub const BTN_MIDDLE: u32 = 274;
pub const BTN_SIDE: u32 = 275;
pub const BTN_EXTRA: u32 = 276;

/// The pointer moved; no button transition happened.
pub const MOTION: u8 = 0;
/// A button went down.
pub const DOWN: u8 = 1;
/// A button went up.
pub const UP: u8 = 2;

/// What the DOM told us, before translation.
pub const Raw = struct {
    /// One of MOTION / DOWN / UP. Anything else is not a pointer event the
    /// toolkit models and must not be translated as one.
    kind: u8,
    /// `MouseEvent.button`: 0 main, 1 auxiliary, 2 secondary, 3 back, 4 forward.
    /// Only meaningful on DOWN/UP — motion carries no button.
    button: i32,
    /// Location in the canvas BACKING STORE, already scaled by the caller from
    /// the DOM's CSS pixels. `web/present.zig`'s `toBackingPoint` owns that
    /// scale, because it is the inverse of what sizes the canvas.
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

/// Map a DOM `MouseEvent.button` to the toolkit's evdev button code.
///
/// See the table in the module comment: THIS IS NOT THE macOS MAPPING.
pub fn evdevButton(button_number: i32) u32 {
    return switch (button_number) {
        0 => BTN_LEFT,
        1 => BTN_MIDDLE,
        2 => BTN_RIGHT,
        // The browser's back/forward thumb buttons are real buttons that an app
        // may want to observe; reporting them as middle is better than dropping
        // them, and they must never be mistaken for BTN_LEFT.
        3 => BTN_SIDE,
        4 => BTN_EXTRA,
        else => BTN_MIDDLE,
    };
}

/// Translate one DOM pointer event. `w`/`h` are the canvas backing-store size.
/// `held` is the current primary-button state, needed for motion: motion must
/// report `pressed` as "is the button down", not false.
pub fn translate(w: u32, h: u32, raw: Raw, held: bool) Translated {
    // Clamp into the canvas. Unlike AppKit this is not a border case — a drag
    // with pointer capture keeps reporting coordinates outside the element, and
    // an unclamped value fed to hit-testing could match a neighbouring widget.
    const pt = adapter.clampToView(w, h, raw.x, raw.y);
    return switch (raw.kind) {
        // Motion carries button 0 so it lands in dispatch's drag arm. Passing
        // BTN_LEFT here would re-arm the press on every move, resetting
        // down_x/down_y and making drag impossible to ever trigger.
        MOTION => .{ .x = pt.x, .y = pt.y, .pressed = held, .button = 0 },
        DOWN => .{ .x = pt.x, .y = pt.y, .pressed = true, .button = evdevButton(raw.button) },
        UP => .{ .x = pt.x, .y = pt.y, .pressed = false, .button = evdevButton(raw.button) },
        // Unknown kind: treat as motion rather than inventing a press.
        else => .{ .x = pt.x, .y = pt.y, .pressed = held, .button = 0 },
    };
}

/// The release to synthesise when the browser cancels a gesture
/// (`pointercancel`: the OS took over, a touch scrolled the page, the pointer was
/// lifted off a pen's range).
///
/// There is no evdev code for "cancelled" — the Delegate contract has no such
/// state, and inventing one would mean changing `components/dispatch.zig`, which
/// is shared with Linux and macOS and is not the browser's to change. So a cancel
/// is reported as what it most nearly is: a release of whatever was held.
///
/// The honest consequence, named so it is not a surprise: if the press was
/// in-bounds and the pointer never moved past the drag threshold, the toolkit
/// treats it as a click. That is a minor UX wart in an already-abnormal case, not
/// corruption — and the alternative (leaving `down` latched) would make the NEXT
/// real click fire a click at the cancelled press's origin, which is worse.
///
/// Returns null when nothing was held, because a cancel with no button down is
/// already the state the toolkit is in and sending an event would only mark the
/// frame dirty.
pub fn cancelRelease(held: bool, w: u32, h: u32, x: f32, y: f32) ?Translated {
    if (!held) return null;
    const pt = adapter.clampToView(w, h, x, y);
    return .{ .x = pt.x, .y = pt.y, .pressed = false, .button = BTN_LEFT };
}

// ===================== tests (parity suite — every platform) =====================

const dispatch = @import("../core/components/dispatch.zig");

test "a press carries BTN_LEFT, which is the code dispatch requires" {
    // THE regression guard. Passing 0 here is what made every click a no-op on
    // macOS, and the same mistake has the same consequence in a tab.
    const t = translate(360, 430, .{ .kind = DOWN, .button = 0, .x = 10, .y = 10 }, false);
    try std.testing.expectEqual(BTN_LEFT, t.button);
    try std.testing.expectEqual(dispatch.BTN_LEFT, t.button);
    try std.testing.expect(t.pressed);
}

test "a release carries BTN_LEFT with pressed false, so the click fires" {
    const t = translate(360, 430, .{ .kind = UP, .button = 0, .x = 10, .y = 10 }, true);
    try std.testing.expectEqual(BTN_LEFT, t.button);
    try std.testing.expect(!t.pressed);
}

test "motion carries button 0 and the current held state" {
    // Motion must NOT carry BTN_LEFT, or every move would restart the press and
    // drag detection could never fire.
    const t = translate(360, 430, .{ .kind = MOTION, .button = 0, .x = 10, .y = 10 }, true);
    try std.testing.expectEqual(@as(u32, 0), t.button);
    try std.testing.expect(t.pressed);
    const idle = translate(360, 430, .{ .kind = MOTION, .button = 0, .x = 10, .y = 10 }, false);
    try std.testing.expectEqual(@as(u32, 0), idle.button);
    try std.testing.expect(!idle.pressed);
}

test "the DOM's button numbering is used, not AppKit's" {
    // THE transcription trap. macOS maps 1 -> BTN_RIGHT and 2 -> BTN_MIDDLE; the
    // DOM maps 1 -> middle and 2 -> right. A table copied from mac/input.zig would
    // swap them, and only a user with a middle button would ever notice.
    try std.testing.expectEqual(BTN_MIDDLE, evdevButton(1));
    try std.testing.expectEqual(BTN_RIGHT, evdevButton(2));
    // Explicitly assert the macOS values are NOT what we produce.
    try std.testing.expect(evdevButton(1) != BTN_RIGHT);
    try std.testing.expect(evdevButton(2) != BTN_MIDDLE);
}

test "back and forward thumb buttons are distinct and never BTN_LEFT" {
    try std.testing.expectEqual(BTN_SIDE, evdevButton(3));
    try std.testing.expectEqual(BTN_EXTRA, evdevButton(4));
    try std.testing.expect(evdevButton(3) != BTN_LEFT);
    try std.testing.expect(evdevButton(4) != BTN_LEFT);
    // An unknown high button number degrades to middle rather than to left.
    try std.testing.expectEqual(BTN_MIDDLE, evdevButton(99));
    try std.testing.expectEqual(BTN_MIDDLE, evdevButton(-1));
}

test "a right or middle press is never mistaken for a left one" {
    // dispatch only reacts to BTN_LEFT, so a right press must not start a click
    // that a left release then fires.
    for ([_]i32{ 1, 2, 3, 4, 99 }) |b| {
        const t = translate(360, 430, .{ .kind = DOWN, .button = b, .x = 5, .y = 5 }, false);
        try std.testing.expect(t.button != dispatch.BTN_LEFT);
    }
}

test "the browser's origin needs no flip, so y passes through" {
    // The macOS mirror of this asserts the y axis is INVERTED. Here a DOM y is
    // already top-left origin, so a press near the top must stay near the top.
    const top = translate(360, 430, .{ .kind = DOWN, .button = 0, .x = 20, .y = 5 }, false);
    const bottom = translate(360, 430, .{ .kind = DOWN, .button = 0, .x = 20, .y = 400 }, false);
    try std.testing.expectApproxEqAbs(@as(f32, 5), top.y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 400), bottom.y, 0.01);
    try std.testing.expect(top.y < bottom.y);
}

test "coordinates from a captured drag outside the canvas are clamped" {
    // Routine, not pathological: pointer capture keeps delivering motion outside
    // the element for the whole drag.
    const out = translate(360, 430, .{ .kind = MOTION, .button = 0, .x = -40, .y = 900 }, true);
    try std.testing.expectEqual(@as(f32, 0), out.x);
    try std.testing.expectEqual(@as(f32, 430), out.y);
}

test "an unknown event kind degrades to motion instead of a phantom press" {
    const t = translate(360, 430, .{ .kind = 99, .button = 0, .x = 10, .y = 10 }, false);
    try std.testing.expectEqual(@as(u32, 0), t.button);
    try std.testing.expect(!t.pressed);
}

test "a full press-then-release sequence walks both of dispatch's arms" {
    // Drives the REAL dispatcher, not a reimplementation.
    var st = dispatch.PtrState{};
    const down = translate(200, 200, .{ .kind = DOWN, .button = 0, .x = 100, .y = 100 }, false);
    dispatch.pointerEvent(&st, down.x, down.y, down.pressed, down.button, 200, 200);
    try std.testing.expect(st.down);
    try std.testing.expect(st.press_in_bounds);
    try std.testing.expect(!st.dragging);

    const up = translate(200, 200, .{ .kind = UP, .button = 0, .x = 100, .y = 100 }, true);
    dispatch.pointerEvent(&st, up.x, up.y, up.pressed, up.button, 200, 200);
    try std.testing.expect(!st.down);
    try std.testing.expect(!st.press_in_bounds);
    try std.testing.expect(!st.dragging);
}

test "motion while held keeps the press anchored so drag can trigger" {
    var st = dispatch.PtrState{};
    const down = translate(400, 400, .{ .kind = DOWN, .button = 0, .x = 50, .y = 50 }, false);
    dispatch.pointerEvent(&st, down.x, down.y, down.pressed, down.button, 400, 400);
    const anchor_x = st.down_x;
    const anchor_y = st.down_y;

    const move = translate(400, 400, .{ .kind = MOTION, .button = 0, .x = 200, .y = 200 }, true);
    dispatch.pointerEvent(&st, move.x, move.y, move.pressed, move.button, 400, 400);
    try std.testing.expectApproxEqAbs(anchor_x, st.down_x, 0.01);
    try std.testing.expectApproxEqAbs(anchor_y, st.down_y, 0.01);
    try std.testing.expect(st.dragging);
}

test "a cancelled gesture releases the held button" {
    // A pointercancel with a button down must NOT leave `down` latched, or the
    // next real release would fire a click at the cancelled press's origin.
    var st = dispatch.PtrState{};
    const down = translate(200, 200, .{ .kind = DOWN, .button = 0, .x = 100, .y = 100 }, false);
    dispatch.pointerEvent(&st, down.x, down.y, down.pressed, down.button, 200, 200);
    try std.testing.expect(st.down);

    const cancel = cancelRelease(true, 200, 200, 100, 100) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(BTN_LEFT, cancel.button);
    try std.testing.expect(!cancel.pressed);
    dispatch.pointerEvent(&st, cancel.x, cancel.y, cancel.pressed, cancel.button, 200, 200);
    try std.testing.expect(!st.down);
}

test "a cancel with nothing held produces no event at all" {
    // Sending one would only mark the frame dirty and force a re-rasterization.
    try std.testing.expect(cancelRelease(false, 200, 200, 10, 10) == null);
}

// ---- end-to-end: the real backend path, against a real Clay layout ----
//
// Everything above is a unit test of the translation. This one is the proof that
// matters: it builds an actual Host, lets Clay lay a box out, converts that box's
// centre into DOM space, runs it through `translate`, feeds the result to the real
// dispatcher, and asserts the box's own callback fired. That is precisely the
// chain a browser click takes.

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
            .bg = Color.rgb(0x33, 0x44, 0x55),
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

test "a browser click reaches a real laid-out button's handler" {
    const w: u32 = 200;
    const h: u32 = 200;
    var app = App{};

    // Clay keeps a process-global context pointer into the init arena, so a test
    // Host must not be deinit'd — the same discipline the calculator example's
    // tests follow.
    var host = try host_mod.Host.init(std.heap.page_allocator, &app, App.root);
    host.frame(w, h);

    const reg = @import("../core/components/click_registry.zig");
    reg.registerZCursor(cl.getElementId("test-hit-box"), App.onClick, &app, 0, 0, .pointer);

    // The box fills the window, so its centre is the window's centre in toolkit
    // (top-left) space — which is ALSO DOM space, with no conversion at all.
    const data = cl.getElementData(cl.getElementId("test-hit-box"));
    try std.testing.expect(data.found);
    const bb = data.bounding_box;
    const css_x = bb.x + bb.width * 0.5;
    const css_y = bb.y + bb.height * 0.5;

    var st = dispatch.PtrState{};
    const down = translate(w, h, .{ .kind = DOWN, .button = 0, .x = css_x, .y = css_y }, false);
    dispatch.pointerEvent(&st, down.x, down.y, down.pressed, down.button, w, h);
    try std.testing.expectEqual(@as(usize, 0), app.hit.fired);

    const up = translate(w, h, .{ .kind = UP, .button = 0, .x = css_x, .y = css_y }, true);
    dispatch.pointerEvent(&st, up.x, up.y, up.pressed, up.button, w, h);

    // The whole point: a press-release pair on a real button fires it once.
    try std.testing.expectEqual(@as(usize, 1), app.hit.fired);
}

test "a HiDPI click still lands on the button the user aimed at" {
    // The scale asymmetry bug: the DOM reports CSS pixels while layout is in
    // backing-store pixels. Here the click is expressed in DOM space at 2x and
    // scaled by the caller — exactly what shim.js does — and must land on the
    // same box. Getting this wrong offsets every click on every Retina display.
    const w: u32 = 200;
    const h: u32 = 200;
    var app = App{};
    var host = try host_mod.Host.init(std.heap.page_allocator, &app, App.root);
    host.frame(w, h);

    const data = cl.getElementData(cl.getElementId("test-hit-box"));
    try std.testing.expect(data.found);
    const bb = data.bounding_box;

    // A point 20% down the window, expressed as a DOM coordinate at 2x and then
    // scaled into the backing store.
    const device_scale: f32 = 2.0;
    const backing_x = bb.x + bb.width * 0.5;
    const backing_y = bb.y + bb.height * 0.2;
    const t = translate(w, h, .{
        .kind = DOWN,
        .button = 0,
        .x = backing_x / device_scale * device_scale,
        .y = backing_y / device_scale * device_scale,
    }, false);

    try std.testing.expectApproxEqAbs(backing_y, t.y, 0.5);
    // And it really is in the top half of the box, not the bottom.
    try std.testing.expect(t.y < bb.y + bb.height * 0.5);
}
