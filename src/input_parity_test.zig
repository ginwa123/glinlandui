//! The pointer contract every backend must meet: the same vocabulary, and the same press/release for one gesture.
const std = @import("std");
const mac = @import("mac/input.zig");
const linux = @import("linux/input.zig");
const windows = @import("windows/input.zig");
const web = @import("web/input.zig");
const dispatch = @import("core/components/dispatch.zig");

fn expectSamePointerEvent(want: windows.Translated, got: anytype) !void {
    try std.testing.expectEqual(want.x, got.x);
    try std.testing.expectEqual(want.y, got.y);
    try std.testing.expectEqual(want.pressed, got.pressed);
    try std.testing.expectEqual(want.button, got.button);
}

test "every backend agrees on the pointer vocabulary, so one Host serves them all" {
    // These are contract values, not per-backend choices: a renumbered kind lands a click in another backend's arm.
    inline for (.{ mac, linux, windows, web }) |backend| {
        try std.testing.expectEqual(@as(u8, 0), backend.MOTION);
        try std.testing.expectEqual(@as(u8, 1), backend.DOWN);
        try std.testing.expectEqual(@as(u8, 2), backend.UP);
        try std.testing.expectEqual(dispatch.BTN_LEFT, backend.BTN_LEFT);
        try std.testing.expectEqual(dispatch.BTN_RIGHT, backend.BTN_RIGHT);
        // The toolkit has no middle-button arm of its own, but every backend still has to agree on the code.
        try std.testing.expectEqual(@as(u32, 274), backend.BTN_MIDDLE);
    }
}

test "a double click is the same press and release on mac, Windows and the browser" {
    const w: u32 = 360;
    const h: u32 = 430;
    const x: f32 = 40;
    // One physical point in each backend's own origin: AppKit counts y from the bottom, Win32 and the DOM from the top.
    const top_y: f32 = 12;
    const bottom_y: f32 = @as(f32, @floatFromInt(h)) - top_y;
    const windows_press = windows.translate(w, h, .{ .kind = windows.DOWN, .button_number = 0, .x = x, .y = top_y }, false);
    const windows_release = windows.translate(w, h, .{ .kind = windows.UP, .button_number = 0, .x = x, .y = top_y }, true);
    const mac_press = mac.translate(w, h, .{ .kind = mac.DOWN, .button_number = 0, .x = x, .y = bottom_y }, false);
    const mac_release = mac.translate(w, h, .{ .kind = mac.UP, .button_number = 0, .x = x, .y = bottom_y }, true);
    const web_press = web.translate(w, h, .{ .kind = web.DOWN, .button = 0, .x = x, .y = top_y }, false);
    const web_release = web.translate(w, h, .{ .kind = web.UP, .button = 0, .x = x, .y = top_y }, true);
    // A press is a press with the LEFT button at the same toolkit point, and a release is its opposite.
    try std.testing.expect(windows_press.pressed);
    try std.testing.expect(!windows_release.pressed);
    try std.testing.expectEqual(dispatch.BTN_LEFT, windows_press.button);
    try std.testing.expectEqual(dispatch.BTN_LEFT, windows_release.button);
    try expectSamePointerEvent(windows_press, mac_press);
    try expectSamePointerEvent(windows_press, web_press);
    try expectSamePointerEvent(windows_release, mac_release);
    try expectSamePointerEvent(windows_release, web_release);
    // Wayland's half of the same contract: a pressed button is DOWN, a released one is UP.
    try std.testing.expectEqual(linux.DOWN, linux.kindFromState(1));
    try std.testing.expectEqual(linux.UP, linux.kindFromState(0));
    try std.testing.expectEqual(dispatch.BTN_LEFT, linux.evdevButton(linux.BTN_LEFT));
}
