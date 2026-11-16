//! The monotonic clock on macOS: CLOCK_MONOTONIC never runs backwards, and a wall-clock change cannot make two clicks look simultaneous.
const std = @import("std");
const clock = @import("../core/clock.zig");

pub fn monoMs(_: ?*anyopaque) i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return clock.fromTimespec(@intCast(ts.sec), @intCast(ts.nsec));
}
