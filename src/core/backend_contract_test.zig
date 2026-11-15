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
