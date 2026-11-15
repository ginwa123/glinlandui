//! The monotonic clock on Linux: CLOCK_MONOTONIC, read through the direct syscall so this backend needs no C runtime for a timestamp.
const std = @import("std");
const linux = std.os.linux;
const clock = @import("../core/clock.zig");

pub fn monoMs(_: ?*anyopaque) i64 {
    var ts: linux.timespec = undefined;
    if (linux.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return clock.fromTimespec(@intCast(ts.sec), @intCast(ts.nsec));
}
