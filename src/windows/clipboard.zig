//! The Windows clipboard: the Win32 clipboard, through the shim (which owns the UTF-16 conversion Win32 requires).
const std = @import("std");
const contract = @import("../core/clipboard_contract.zig");

const c = @cImport({
    @cInclude("shim.h");
});

/// Largest run the host will read or write in one call; anything longer is truncated rather than allocated.
pub const max_bytes: usize = contract.max_bytes;

/// The clipboard's text as UTF-8, copied into `buf`; empty when it holds no text, or when another process has it open.
pub fn read(buf: []u8) []const u8 {
    if (buf.len == 0) return buf[0..0];
    const cap: c_int = @intCast(contract.cap(buf.len));
    const got = c.glin_win_clipboard_read(buf.ptr, cap);
    return buf[0..contract.trim(@as(isize, got), buf.len)];
}

/// Replace the clipboard's text with `text`.
pub fn write(text: []const u8) void {
    const n = contract.cap(text.len);
    if (n == 0) return;
    c.glin_win_clipboard_write(text.ptr, @intCast(n));
}
