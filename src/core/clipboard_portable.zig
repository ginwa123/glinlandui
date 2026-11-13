//! Clipboard stub for a platform with no backend yet: it reads nothing and drops every write.
//!
//! Kept in `core/` so the port has a shape on every target: an app calls `ui.clipboard.read` /
//! `write` and compiles everywhere, and only the platform that implements it does anything.
pub const max_bytes: usize = 1 << 20;

/// Nothing to read: an empty slice.
pub fn read(buf: []u8) []const u8 {
    _ = buf;
    return &.{};
}

/// Nothing to write.
pub fn write(text: []const u8) void {
    _ = text;
}

test "clipboard portable: reads empty and swallows writes" {
    var buf: [8]u8 = undefined;
    try @import("std").testing.expectEqual(@as(usize, 0), read(&buf).len);
    write("ignored");
}
