//! The Windows console: a thin wrapper over the C shim, which is the only part that touches Win32.
const std = @import("std");
const term = @import("term.zig");

extern fn glin_term_open(cols: *c_ulong, rows: *c_ulong) c_int;
extern fn glin_term_size(cols: *c_ulong, rows: *c_ulong) c_int;
extern fn glin_term_read(buf: [*]u8, len: c_int, timeout_ms: c_int) c_int;
extern fn glin_term_write(buf: [*]const u8, len: c_int) c_int;
extern fn glin_term_restore() void;
extern fn glin_term_now_us() i64;

pub const Console = struct {
    cols: u16 = 80,
    rows: u16 = 24,
    opened: bool = false,

    pub fn open() !Console {
        var cols: c_ulong = 0;
        var rows: c_ulong = 0;
        if (glin_term_open(&cols, &rows) == 0) return error.NotATerminal;
        return .{ .cols = @intCast(cols), .rows = @intCast(rows), .opened = true };
    }

    pub fn enableRaw(self: *Console) !void {
        // `open` already switched the console into VT mode; there is nothing left to do.
        _ = self;
    }

    pub fn disableRaw(self: *Console) void {
        _ = self;
    }

    pub fn size(self: *Console) ?term.Size {
        var cols: c_ulong = 0;
        var rows: c_ulong = 0;
        if (glin_term_size(&cols, &rows) == 0) return null;
        self.cols = @intCast(cols);
        self.rows = @intCast(rows);
        return term.sizeFromWinsize(self.rows, self.cols, 0, 0);
    }

    pub fn read(self: *Console, buf: []u8, timeout_ms: i32) !usize {
        _ = self;
        const n = glin_term_read(buf.ptr, @intCast(@min(buf.len, 4096)), timeout_ms);
        if (n < 0) return 0;
        return @intCast(n);
    }

    pub fn write(self: *Console, bytes: []const u8) void {
        _ = self;
        var off: usize = 0;
        while (off < bytes.len) {
            const chunk = @min(bytes.len - off, 8192);
            const n = glin_term_write(bytes.ptr + off, @intCast(chunk));
            if (n <= 0) return;
            off += @intCast(n);
        }
    }

    /// Monotonic microseconds, for the frame statistics line.
    pub fn nowUs(self: *Console) i64 {
        _ = self;
        return glin_term_now_us();
    }

    pub fn close(self: *Console) void {
        if (self.opened) glin_term_restore();
    }
};
