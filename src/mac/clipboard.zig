//! macOS clipboard: the general pasteboard, through the shim.
const std = @import("std");

const c = @cImport({
    @cInclude("shim.h");
});

/// Largest run the host will read or write in one call; anything longer is truncated rather than allocated.
pub const max_bytes: usize = 1 << 20;

/// The pasteboard's text as UTF-8, copied into `buf`; empty when the pasteboard holds no text.
pub fn read(buf: []u8) []const u8 {
    if (buf.len == 0) return buf[0..0];
    const cap: c_int = @intCast(@min(buf.len, max_bytes));
    const n = c.glin_cocoa_clipboard_read(buf.ptr, cap);
    if (n <= 0) return buf[0..0];
    return buf[0..@intCast(n)];
}

/// Replace the pasteboard's text with `text`.
pub fn write(text: []const u8) void {
    const n: c_int = @intCast(@min(text.len, max_bytes));
    c.glin_cocoa_clipboard_write(text.ptr, n);
}

test "clipboard: an empty buffer reads nothing and never calls the pasteboard" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), read(buf[0..0]).len);
}
