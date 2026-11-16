//! The monotonic millisecond clock: what tells two clicks apart, and how long a caret has been still.
const std = @import("std");
const select = @import("select.zig");
const Ctx = @import("erased.zig").Ctx;

/// Milliseconds from a monotonic source, or 0 when the host has none: a double click is then never guessed at and a frame keeps its fixed delta.
pub const monoMs = select.Clock.monoMs;

/// Milliseconds from a seconds/nanoseconds pair, which is the shape every POSIX clock reports. Pure, so the arithmetic runs on every platform.
pub fn fromTimespec(sec: i64, nsec: i64) i64 {
    return sec * std.time.ms_per_s + @divTrunc(nsec, std.time.ns_per_ms);
}

/// True when a reading can be used: a clock that failed reports 0, and two of those are not a double click.
pub fn usable(ms: i64) bool {
    return ms > 0;
}

test "a seconds/nanoseconds reading becomes whole milliseconds" {
    try std.testing.expectEqual(@as(i64, 1_234_567), fromTimespec(1234, 567_890_000));
    try std.testing.expectEqual(@as(i64, 0), fromTimespec(0, 0));
    try std.testing.expectEqual(@as(i64, 999), fromTimespec(0, 999_999_999));
}

test "a reading from the epoch is not usable as a clock" {
    try std.testing.expect(!usable(0));
    try std.testing.expect(usable(1));
}

test "a host with no clock reports 0 rather than a guessed time" {
    try std.testing.expectEqual(@as(i64, 0), monoMs(Ctx.none));
}
