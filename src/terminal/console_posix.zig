//! The POSIX console: raw mode, a cell size from ioctl, a read with a deadline, unbuffered writes.
const std = @import("std");
const posix = std.posix;
const term = @import("term.zig");

/// The kernel's struct winsize, in the field order every POSIX host agrees on.
pub const Winsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

/// One terminal. `open` fails when the process has no tty, which is exactly when the caller should render headless.
pub const Console = struct {
    fd: posix.fd_t,
    saved: std.c.termios,
    raw: bool = false,

    pub fn open() !Console {
        const fd = posix.STDIN_FILENO;
        var t: std.c.termios = undefined;
        // tcgetattr through libc, not std.posix: the POSIX wrapper turns EBADF into unreachable, and a closed stdin must be an error here.
        if (std.c.tcgetattr(fd, &t) != 0) return error.NotATerminal;
        return .{ .fd = fd, .saved = t };
    }

    pub fn enableRaw(self: *Console) !void {
        var raw = self.saved;
        raw.iflag.IGNBRK = true;
        raw.iflag.BRKINT = false;
        raw.iflag.PARMRK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.INLCR = false;
        raw.iflag.IGNCR = false;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;
        raw.oflag.OPOST = false;
        raw.lflag.ECHO = false;
        raw.lflag.ECHONL = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.cflag.CSIZE = .CS8;
        raw.cc[@intFromEnum(posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;
        if (std.c.tcsetattr(self.fd, .NOW, &raw) != 0) return error.RawModeFailed;
        self.raw = true;
    }

    pub fn disableRaw(self: *Console) void {
        if (!self.raw) return;
        _ = std.c.tcsetattr(self.fd, .NOW, &self.saved);
        self.raw = false;
    }

    pub fn size(self: *Console) ?term.Size {
        var ws: Winsize = std.mem.zeroes(Winsize);
        if (posix.system.ioctl(self.fd, posix.T.IOCGWINSZ, @intFromPtr(&ws)) != 0) return null;
        return term.sizeFromWinsize(ws.ws_row, ws.ws_col, ws.ws_xpixel, ws.ws_ypixel);
    }

    /// Read whatever is available within `timeout_ms`; 0 means "nothing arrived", not an error.
    pub fn read(self: *Console, buf: []u8, timeout_ms: i32) !usize {
        var fds = [_]posix.pollfd{.{ .fd = self.fd, .events = posix.POLL.IN, .revents = 0 }};
        const ready = posix.poll(&fds, timeout_ms) catch return 0;
        if (ready == 0) return 0;
        return posix.read(self.fd, buf) catch |e| switch (e) {
            error.WouldBlock => 0,
            else => e,
        };
    }

    pub fn write(self: *Console, bytes: []const u8) void {
        _ = self;
        var off: usize = 0;
        while (off < bytes.len) {
            const n = std.c.write(posix.STDOUT_FILENO, bytes.ptr + off, bytes.len - off);
            if (n <= 0) return;
            off += @intCast(n);
        }
    }

    /// Monotonic microseconds, for the frame statistics line.
    pub fn nowUs(self: *Console) i64 {
        _ = self;
        var ts: std.c.timespec = undefined;
        if (std.c.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts) != 0) return 0;
        return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1000);
    }

    pub fn close(self: *Console) void {
        self.disableRaw();
    }
};
