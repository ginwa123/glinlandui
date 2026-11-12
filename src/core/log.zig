//! The library's log sink: silent in a test, stderr in production, replaceable by the app.

const std = @import("std");
const builtin = @import("builtin");

/// How loud a message is.
pub const Level = enum { warn, err };

/// Where a message goes. The app installs one; the library never assumes a destination.
pub const Sink = *const fn (level: Level, message: []const u8) void;

/// The default: stderr in production, nothing in a test.
fn stderrSink(level: Level, message: []const u8) void {
    if (builtin.is_test) return;
    std.debug.print("[glinlandui] {s}: {s}\n", .{ @tagName(level), message });
}

var sink: ?Sink = &stderrSink;

/// Route the library's messages. Pass null to silence it entirely.
pub fn setSink(s: ?Sink) void {
    sink = s;
}

/// Report a degraded-but-working condition.
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    emit(.warn, fmt, args);
}

/// Report a failure the caller may not be able to see.
pub fn err(comptime fmt: []const u8, args: anytype) void {
    emit(.err, fmt, args);
}

fn emit(comptime level: Level, comptime fmt: []const u8, args: anytype) void {
    const s = sink orelse return;
    var buf: [512]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, fmt, args) catch return;
    s(level, message);
}

test "a message with no sink installed goes nowhere" {
    setSink(null);
    defer setSink(&stderrSink);
    warn("this must not reach stderr", .{});
}

test "an installed sink receives the formatted message" {
    const Capture = struct {
        var level: Level = .warn;
        var text: [128]u8 = undefined;
        var len: usize = 0;
        fn take(l: Level, message: []const u8) void {
            level = l;
            len = @min(message.len, text.len);
            @memcpy(text[0..len], message[0..len]);
        }
    };
    setSink(&Capture.take);
    defer setSink(&stderrSink);

    warn("pool {d} exhausted", .{7});
    try std.testing.expectEqual(Level.warn, Capture.level);
    try std.testing.expectEqualStrings("pool 7 exhausted", Capture.text[0..Capture.len]);
}
