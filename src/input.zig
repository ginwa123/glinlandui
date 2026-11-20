//! The pointer entry: one translation, bound to the adapter this build runs on, so no caller names a platform.
const std = @import("std");
const builtin = @import("builtin");
const contract = @import("core/pointer_contract.zig");
const dispatch = @import("core/components/dispatch.zig");

pub const mac = @import("mac/input.zig");
pub const linux = @import("linux/input.zig");
pub const windows = @import("windows/input.zig");
pub const web = @import("web/input.zig");

/// The adapter this build translates with; a test build takes the OS-independent one.
pub const active = if (builtin.is_test) windows else switch (builtin.os.tag) {
    .macos => mac,
    .linux => linux,
    .windows => windows,
    else => web,
};

pub const Raw = contract.Raw;
pub const Translated = contract.Translated;
pub const MOTION = contract.MOTION;
pub const DOWN = contract.DOWN;
pub const UP = contract.UP;

/// What an app or a test calls: the one translation, for the platform this build runs on.
pub const translate = active.translate;

/// The same translation, bound to a named adapter — how the parity tests hold all four to one answer.
pub fn translateFor(comptime Adapter: type, w: u32, h: u32, raw: Raw, held: bool) Translated {
    return contract.translate(Adapter, w, h, raw, held);
}

fn expectSame(want: Translated, got: Translated) !void {
    try std.testing.expectEqual(want.x, got.x);
    try std.testing.expectEqual(want.y, got.y);
    try std.testing.expectEqual(want.pressed, got.pressed);
    try std.testing.expectEqual(want.button, got.button);
}

test "every backend agrees on the pointer vocabulary, so one Host serves them all" {
    // These are contract values, not per-backend choices: a renumbered kind lands a click in another backend's arm.
    inline for (.{ mac, linux, windows, web }) |backend| {
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
    const win_press = translateFor(windows, w, h, .{ .kind = DOWN, .button_number = 0, .x = x, .y = top_y }, false);
    const win_release = translateFor(windows, w, h, .{ .kind = UP, .button_number = 0, .x = x, .y = top_y }, true);
    const mac_press = translateFor(mac, w, h, .{ .kind = DOWN, .button_number = 0, .x = x, .y = bottom_y }, false);
    const mac_release = translateFor(mac, w, h, .{ .kind = UP, .button_number = 0, .x = x, .y = bottom_y }, true);
    const web_press = translateFor(web, w, h, .{ .kind = DOWN, .button_number = 0, .x = x, .y = top_y }, false);
    const web_release = translateFor(web, w, h, .{ .kind = UP, .button_number = 0, .x = x, .y = top_y }, true);
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
    try std.testing.expectEqual(DOWN, linux.kindFromState(1));
    try std.testing.expectEqual(UP, linux.kindFromState(0));
    try std.testing.expectEqual(dispatch.BTN_LEFT, linux.evdevButton(linux.BTN_LEFT));
}
