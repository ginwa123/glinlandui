//! The pointer entry: one translation, chosen by platform.zig, so no caller and no test names a platform here.
const std = @import("std");
const platform = @import("platform.zig");
const contract = @import("core/pointer_contract.zig");
const dispatch = @import("core/component.zig").dispatch;

pub const translate = platform.input.translate;
pub const Raw = platform.input.Raw;
pub const Translated = platform.input.Translated;
pub const MOTION = platform.input.MOTION;
pub const DOWN = platform.input.DOWN;
pub const UP = platform.input.UP;

/// The same translation, bound to a named adapter — how the parity tests hold all four to one answer.
pub fn translateFor(comptime Adapter: type, w: u32, h: u32, raw: Raw, held: bool) Translated {
    return contract.translate(Adapter, w, h, raw, held);
}

const backends = platform.input_backends;

fn expectSame(want: Translated, got: Translated) !void {
    try std.testing.expectEqual(want.x, got.x);
    try std.testing.expectEqual(want.y, got.y);
    try std.testing.expectEqual(want.pressed, got.pressed);
    try std.testing.expectEqual(want.button, got.button);
}

test "every backend agrees on the pointer vocabulary, so one Host serves them all" {
    // These are contract values, not per-backend choices: a renumbered kind lands a click in another backend's arm.
    inline for (.{ backends.mac, backends.linux, backends.windows, backends.web }) |backend| {
        try std.testing.expectEqual(MOTION, backend.MOTION);
        try std.testing.expectEqual(DOWN, backend.DOWN);
        try std.testing.expectEqual(UP, backend.UP);
        try std.testing.expectEqual(dispatch.BTN_LEFT, backend.BTN_LEFT);
        try std.testing.expectEqual(dispatch.BTN_RIGHT, backend.BTN_RIGHT);
        // The toolkit has no middle-button arm of its own, but every backend still has to agree on the code.
        try std.testing.expectEqual(@as(u32, 274), backend.BTN_MIDDLE);
    }
}

test "the same physical point is the same press and release on mac, Win32 and the DOM" {
    const w: u32 = 360;
    const h: u32 = 430;
    const x: f32 = 40;
    // One point in each backend's own origin: AppKit counts y from the bottom, Win32 and the DOM from the top.
    const top_y: f32 = 12;
    const bottom_y: f32 = @as(f32, @floatFromInt(h)) - top_y;
    const win_press = translateFor(backends.windows, w, h, .{ .kind = DOWN, .button_number = 0, .x = x, .y = top_y }, false);
    const win_release = translateFor(backends.windows, w, h, .{ .kind = UP, .button_number = 0, .x = x, .y = top_y }, true);
    const mac_press = translateFor(backends.mac, w, h, .{ .kind = DOWN, .button_number = 0, .x = x, .y = bottom_y }, false);
    const mac_release = translateFor(backends.mac, w, h, .{ .kind = UP, .button_number = 0, .x = x, .y = bottom_y }, true);
    const web_press = translateFor(backends.web, w, h, .{ .kind = DOWN, .button_number = 0, .x = x, .y = top_y }, false);
    const web_release = translateFor(backends.web, w, h, .{ .kind = UP, .button_number = 0, .x = x, .y = top_y }, true);
    // A press is a press with the LEFT button at the same toolkit point, and a release is its opposite.
    try std.testing.expect(win_press.pressed);
    try std.testing.expect(!win_release.pressed);
    try std.testing.expectEqual(dispatch.BTN_LEFT, win_press.button);
    try std.testing.expectEqual(dispatch.BTN_LEFT, win_release.button);
    try expectSame(win_press, mac_press);
    try expectSame(win_press, web_press);
    try expectSame(win_release, mac_release);
    try expectSame(win_release, web_release);
    // Wayland's half of the same contract: a pressed button is DOWN, a released one is UP.
    try std.testing.expectEqual(DOWN, backends.linux.kindFromState(1));
    try std.testing.expectEqual(UP, backends.linux.kindFromState(0));
    try std.testing.expectEqual(dispatch.BTN_LEFT, backends.linux.evdevButton(backends.linux.BTN_LEFT));
}
