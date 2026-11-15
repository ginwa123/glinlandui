//! What every clipboard backend agrees on: the size ceiling, and how a host's answer is turned into a slice length.
const std = @import("std");

/// The most any one read or write moves. A pasteboard holding something enormous is truncated, never allocated whole.
pub const max_bytes: usize = 1 << 20;

/// How many bytes of a `want`-byte run may be moved: the caller's buffer, under the ceiling.
pub fn cap(want: usize) usize {
    return @min(want, max_bytes);
}

// A host reports its own length, which may be negative (empty/failed) and may overstate the buffer.
pub fn trim(raw_len: isize, limit: usize) usize {
    if (raw_len <= 0) return 0;
    const n: usize = @intCast(raw_len);
    return @min(n, limit);
}

test "cap keeps a run under the ceiling and never grows one" {
    try std.testing.expectEqual(@as(usize, 5), cap(5));
    try std.testing.expectEqual(@as(usize, 0), cap(0));
    try std.testing.expectEqual(@as(usize, max_bytes), cap(max_bytes));
    try std.testing.expectEqual(@as(usize, max_bytes), cap(max_bytes * 8));
}

test "trim turns a host's length into a slice length, and refuses the impossible ones" {
    try std.testing.expectEqual(@as(usize, 0), trim(-1, 16));
    try std.testing.expectEqual(@as(usize, 0), trim(0, 16));
    try std.testing.expectEqual(@as(usize, 7), trim(7, 16));
    // A host that claims more than the buffer it was given cannot be believed.
    try std.testing.expectEqual(@as(usize, 16), trim(99, 16));
}
