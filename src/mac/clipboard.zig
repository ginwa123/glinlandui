//! macOS clipboard: the general pasteboard, through the shim.
const std = @import("std");

const c = @cImport({
    @cInclude("shim.h");
});

const contract = @import("../core/clipboard_contract.zig");

/// Largest run the host will read or write in one call; anything longer is truncated rather than allocated.
pub const max_bytes: usize = contract.max_bytes;

/// The pasteboard's text as UTF-8, copied into `buf`; empty when the pasteboard holds no text.
pub fn read(buf: []u8) []const u8 {
    if (buf.len == 0) return buf[0..0];
    const cap: c_int = @intCast(contract.cap(buf.len));
    const n = c.glin_cocoa_clipboard_read(buf.ptr, cap);
    return buf[0..contract.trim(@as(isize, n), buf.len)];
}

/// Replace the pasteboard's text with `text`.
pub fn write(text: []const u8) void {
    const n = contract.cap(text.len);
    if (n == 0) return;
    c.glin_cocoa_clipboard_write(text.ptr, @intCast(n));
}

test "clipboard: an empty buffer reads nothing and never calls the pasteboard" {
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), read(buf[0..0]).len);
}
