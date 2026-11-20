//! The backend contract: every module `platform.zig` can select must expose the same public surface, checked through the composition root on every CI leg.
const std = @import("std");
const platform = @import("../platform.zig");
const contract = @import("window_contract.zig");

fn hasField(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |s| blk: {
            inline for (s.fields) |f| {
                if (std.mem.eql(u8, f.name, name)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn isFn(comptime T: type, comptime name: []const u8) bool {
    if (!@hasDecl(T, name)) return false;
    return @typeInfo(@TypeOf(@field(T, name))) == .@"fn";
}

fn arity(comptime T: type, comptime name: []const u8) usize {
    return @typeInfo(@TypeOf(@field(T, name))).@"fn".params.len;
}

test "the selected window backend satisfies the window contract" {
    const B = platform.window;
    try std.testing.expect(@hasDecl(B, "Window"));
    try std.testing.expect(@hasDecl(B, "WindowConfig"));
    try std.testing.expect(@hasDecl(B, "Delegate"));

    const W = B.Window;
    // `Window.init(alloc, config)` — the allocator comes from main, and the config carries the app id, title and size.
    try std.testing.expect(isFn(W, "init"));
    try std.testing.expectEqual(@as(usize, 2), arity(W, "init"));
    // `window.delegate = host.delegate(); try window.run();`
    try std.testing.expect(isFn(W, "run"));
    try std.testing.expectEqual(@as(usize, 1), arity(W, "run"));
    try std.testing.expect(hasField(W, "delegate"));
    // The headless driver and the verify tooling reach for this; a backend without it cannot be inspected.
    try std.testing.expect(isFn(W, "renderHeadless"));
}

test "the selected renderer satisfies the renderer contract" {
    const R = platform.render_impl.Renderer;
    try std.testing.expect(isFn(R, "init"));
    try std.testing.expectEqual(@as(usize, 1), arity(R, "init"));
    try std.testing.expect(isFn(R, "deinit"));
    try std.testing.expectEqual(@as(usize, 1), arity(R, "deinit"));
    // `drawCommands(commands, win_w, win_h)` — the one entry point the frame path drives.
    try std.testing.expect(isFn(R, "drawCommands"));
    try std.testing.expectEqual(@as(usize, 4), arity(R, "drawCommands"));
}

test "WindowConfig carries every field an app's main sets" {
    inline for (.{ "app_id", "title", "width", "height", "min_width", "min_height" }) |name| {
        try std.testing.expect(hasField(platform.window.WindowConfig, name));
    }
}

test "the Delegate has every callback a Host wires, so one Host works on all backends" {
    inline for (.{ "ptr", "on_frame", "on_pointer", "on_scroll", "on_key", "on_resize", "on_close" }) |name| {
        try std.testing.expect(hasField(platform.window.Delegate, name));
    }
}

test "every backend re-exports the shared pure window contract" {
    // A clamp, a placement rule or the test-frame parser must not drift per platform: they all come from `window_contract`.
    try std.testing.expectEqual(contract.min_width, platform.window.min_width);
    try std.testing.expectEqual(contract.min_height, platform.window.min_height);
    inline for (.{ 0, 100, 520, 4000 }) |w| {
        inline for (.{ 0, 100, 360, 3000 }) |h| {
            const a = contract.clampSize(w, h);
            const b = platform.window.clampSize(w, h);
            try std.testing.expectEqual(a.w, b.w);
            try std.testing.expectEqual(a.h, b.h);
        }
    }
    try std.testing.expectEqual(contract.keyToClose(53), platform.window.keyToClose(53));
}

test "an optional capability is a whole function or absent, never half-declared" {
    if (@hasDecl(platform.window.Window, "setAnimating")) {
        try std.testing.expect(isFn(platform.window.Window, "setAnimating"));
    }
}

const mac_input = @import("../mac/input.zig");
const linux_input = @import("../linux/input.zig");
const windows_input = @import("../windows/input.zig");
const web_input = @import("../web/input.zig");
const pointer_dispatch = @import("component.zig").dispatch;

fn expectSamePointerEvent(want: windows_input.Translated, got: anytype) !void {
    try std.testing.expectEqual(want.x, got.x);
    try std.testing.expectEqual(want.y, got.y);
    try std.testing.expectEqual(want.pressed, got.pressed);
    try std.testing.expectEqual(want.button, got.button);
}

test "every backend agrees on the pointer vocabulary, so one Host serves them all" {
    // These are contract values, not per-backend choices: a renumbered kind lands a click in another backend's arm.
    inline for (.{ mac_input, linux_input, windows_input, web_input }) |backend| {
        try std.testing.expectEqual(@as(u8, 0), backend.MOTION);
        try std.testing.expectEqual(@as(u8, 1), backend.DOWN);
        try std.testing.expectEqual(@as(u8, 2), backend.UP);
        try std.testing.expectEqual(pointer_dispatch.BTN_LEFT, backend.BTN_LEFT);
        try std.testing.expectEqual(pointer_dispatch.BTN_RIGHT, backend.BTN_RIGHT);
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
    const windows_press = windows_input.translate(w, h, .{ .kind = windows_input.DOWN, .button_number = 0, .x = x, .y = top_y }, false);
    const windows_release = windows_input.translate(w, h, .{ .kind = windows_input.UP, .button_number = 0, .x = x, .y = top_y }, true);
    const mac_press = mac_input.translate(w, h, .{ .kind = mac_input.DOWN, .button_number = 0, .x = x, .y = bottom_y }, false);
    const mac_release = mac_input.translate(w, h, .{ .kind = mac_input.UP, .button_number = 0, .x = x, .y = bottom_y }, true);
    const web_press = web_input.translate(w, h, .{ .kind = web_input.DOWN, .button = 0, .x = x, .y = top_y }, false);
    const web_release = web_input.translate(w, h, .{ .kind = web_input.UP, .button = 0, .x = x, .y = top_y }, true);
    // A press is a press with the LEFT button at the same toolkit point, and a release is its opposite.
    try std.testing.expect(windows_press.pressed);
    try std.testing.expect(!windows_release.pressed);
    try std.testing.expectEqual(pointer_dispatch.BTN_LEFT, windows_press.button);
    try std.testing.expectEqual(pointer_dispatch.BTN_LEFT, windows_release.button);
    try expectSamePointerEvent(windows_press, mac_press);
    try expectSamePointerEvent(windows_press, web_press);
    try expectSamePointerEvent(windows_release, mac_release);
    try expectSamePointerEvent(windows_release, web_release);
    // Wayland's half of the same contract: a pressed button is DOWN, a released one is UP.
    try std.testing.expectEqual(linux_input.DOWN, linux_input.kindFromState(1));
    try std.testing.expectEqual(linux_input.UP, linux_input.kindFromState(0));
    try std.testing.expectEqual(pointer_dispatch.BTN_LEFT, linux_input.evdevButton(linux_input.BTN_LEFT));
}
