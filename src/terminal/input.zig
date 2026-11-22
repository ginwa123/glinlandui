//! The input side: bytes from a terminal, decoded into the engine's key, pointer and text events.
const std = @import("std");
const keymap = @import("keymap.zig");
const term = @import("term.zig");

/// Where decoded events go. The window points its delegate at this, so the decoding stays testable without a terminal.
pub const Sink = struct {
    ctx: ?*anyopaque = null,
    key: *const fn (?*anyopaque, u32, bool) void,
    text: *const fn (?*anyopaque, []const u8) void,
    pointer: *const fn (?*anyopaque, i32, i32, bool, u32) void,
    scroll: *const fn (?*anyopaque, f32, f32) void,
};

const left_button: u16 = 272;
const middle_button: u16 = 274;
const right_button: u16 = 273;

const KEY_LEFTCTRL: u32 = 29;
const KEY_LEFTALT: u32 = 56;
const KEY_LEFTSHIFT: u32 = 42;

/// A streaming escape decoder: it holds an incomplete sequence until the rest of it arrives.
pub const Decoder = struct {
    buf: [128]u8 = undefined,
    len: usize = 0,
    buttons: u16 = 0,
    pasting: bool = false,

    /// Feed raw bytes; every complete event goes straight to `sink`.
    pub fn feed(self: *Decoder, bytes: []const u8, sink: Sink) void {
        for (bytes) |b| {
            if (self.len >= self.buf.len) self.len = 0;
            self.buf[self.len] = b;
            self.len += 1;
            self.drain(sink, false);
        }
    }

    /// The idle tick: a lone ESC is the Escape key, not the start of a sequence that never came.
    pub fn idle(self: *Decoder, sink: Sink) void {
        self.drain(sink, true);
    }

    fn drain(self: *Decoder, sink: Sink, force_escape: bool) void {
        var off: usize = 0;
        while (off < self.len) {
            const n = self.one(self.buf[off..self.len], sink, force_escape);
            if (n == 0) break;
            off += n;
        }
        if (off == 0) return;
        const left = self.len - off;
        std.mem.copyForwards(u8, self.buf[0..left], self.buf[off..self.len]);
        self.len = left;
    }

    fn press(sink: Sink, code: u32) void {
        if (code == 0) return;
        sink.key(sink.ctx, code, true);
        sink.key(sink.ctx, code, false);
    }

    fn withModifiers(sink: Sink, mods: keymap.Modifiers, code: u32) void {
        if (mods.ctrl) sink.key(sink.ctx, KEY_LEFTCTRL, true);
        if (mods.alt) sink.key(sink.ctx, KEY_LEFTALT, true);
        if (mods.shift) sink.key(sink.ctx, KEY_LEFTSHIFT, true);
        press(sink, code);
        if (mods.shift) sink.key(sink.ctx, KEY_LEFTSHIFT, false);
        if (mods.alt) sink.key(sink.ctx, KEY_LEFTALT, false);
        if (mods.ctrl) sink.key(sink.ctx, KEY_LEFTCTRL, false);
    }

    // Decode one event; 0 means the rest of the sequence has not arrived yet.
    fn one(self: *Decoder, s: []const u8, sink: Sink, force_escape: bool) usize {
        const b = s[0];
        if (self.pasting) return self.paste(s, sink);
        if (b != 0x1b) return self.plain(s, sink);
        if (s.len == 1) {
            if (!force_escape) return 0;
            press(sink, 1);
            return 1;
        }
        return switch (s[1]) {
            '[' => self.csi(s, sink),
            'O' => if (s.len < 3) 0 else blk: {
                press(sink, keymap.fromSS3(s[2]));
                break :blk 3;
            },
            // Alt+key: press Alt, then the key, then release Alt — the engine reads modifiers off the key chain.
            else => blk: {
                const n = self.plainWith(s[1..], sink, true);
                if (n == 0) break :blk 0;
                sink.key(sink.ctx, KEY_LEFTALT, false);
                break :blk 1 + n;
            },
        };
    }

    fn plain(self: *Decoder, s: []const u8, sink: Sink) usize {
        return self.plainWith(s, sink, false);
    }

    fn plainWith(self: *Decoder, s: []const u8, sink: Sink, alt: bool) usize {
        _ = self;
        const b = s[0];
        if (alt) sink.key(sink.ctx, KEY_LEFTALT, true);
        if (b < 0x20 or b == 0x7f) {
            const code = keymap.fromControl(b);
            // A control byte IS Ctrl+letter on a terminal, so the modifier is announced and released around the key.
            if (b >= 0x01 and b <= 0x1a and b != 0x08 and b != 0x09 and b != 0x0d and b != 0x1b) {
                sink.key(sink.ctx, KEY_LEFTCTRL, true);
                press(sink, code);
                sink.key(sink.ctx, KEY_LEFTCTRL, false);
            } else {
                press(sink, code);
            }
            return 1;
        }
        if (b < 0x80) {
            press(sink, keymap.fromAscii(b));
            sink.text(sink.ctx, s[0..1]);
            return 1;
        }
        const n = std.unicode.utf8ByteSequenceLength(b) catch 1;
        if (s.len < n) return 0;
        sink.text(sink.ctx, s[0..n]);
        return n;
    }

    // Bracketed paste: everything up to `ESC [ 201 ~` is text, never a shortcut.
    fn paste(self: *Decoder, s: []const u8, sink: Sink) usize {
        const end = std.mem.indexOf(u8, s, "\x1b[201~");
        if (end) |e| {
            if (e > 0) sink.text(sink.ctx, s[0..e]);
            self.pasting = false;
            return e + 6;
        }
        // Keep the last five bytes back, because the terminator may be split across reads.
        if (s.len <= 5) return 0;
        sink.text(sink.ctx, s[0 .. s.len - 5]);
        return s.len - 5;
    }

    fn csi(self: *Decoder, s: []const u8, sink: Sink) usize {
        var i: usize = 2;
        var plen: usize = 0;
        var params: [40]u8 = undefined;
        while (i < s.len) : (i += 1) {
            const c = s[i];
            if (c >= 0x40 and c <= 0x7e) return self.final(s, params[0..plen], c, i + 1, sink);
            if (plen < params.len) {
                params[plen] = c;
                plen += 1;
            }
        }
        return 0;
    }

    fn final(self: *Decoder, s: []const u8, params: []const u8, f: u8, consumed: usize, sink: Sink) usize {
        _ = s;
        if (params.len >= 2 and params[0] == '<') return self.mouse(params[1..], f, consumed, sink);
        if (params.len != 0 and params[0] == '?') return consumed;
        var nums = [4]u32{ 0, 0, 0, 0 };
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, params, ';');
        while (it.next()) |part| {
            if (n == nums.len) break;
            if (part.len == 0) {
                nums[n] = 0;
            } else {
                nums[n] = std.fmt.parseInt(u32, part, 10) catch 0;
            }
            n += 1;
        }
        // `ESC [ 200 ~` / `201 ~` bracket a paste; the bytes in between are text, not keystrokes.
        if (f == '~' and nums[0] == 200) {
            self.pasting = true;
            return consumed;
        }
        if (f == '~' and nums[0] == 201) {
            self.pasting = false;
            return consumed;
        }
        const mods = if (n >= 2) keymap.Modifiers.fromParam(nums[1]) else keymap.Modifiers{};
        const code = if (f == '~') keymap.fromTilde(nums[0]) else keymap.fromFinal(f);
        withModifiers(sink, mods, code);
        return consumed;
    }

    // SGR mouse: `ESC [ < button ; x ; y M` for motion and presses, `m` for a release.
    fn mouse(self: *Decoder, params: []const u8, f: u8, consumed: usize, sink: Sink) usize {
        var nums = [3]u32{ 0, 0, 0 };
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, params, ';');
        while (it.next()) |part| {
            if (n == nums.len) break;
            nums[n] = std.fmt.parseInt(u32, part, 10) catch 0;
            n += 1;
        }
        if (n < 3) return consumed;
        const x: i32 = @as(i32, @intCast(nums[1])) - 1;
        const y: i32 = @as(i32, @intCast(nums[2])) - 1;
        const px = x * @as(i32, term.cell_w) + @as(i32, term.cell_w) / 2;
        const py = y * @as(i32, term.cell_h) + @as(i32, term.cell_h) / 2;
        const bits = nums[0];
        if (bits & 64 != 0) {
            const dir = bits & 3;
            const dy: f32 = if (dir == 0) -1 else if (dir == 1) 1 else 0;
            const dx: f32 = if (dir == 2) -1 else if (dir == 3) 1 else 0;
            sink.scroll(sink.ctx, dx, dy);
            return consumed;
        }
        const motion = bits & 32 != 0;
        const button: u16 = switch (bits & 3) {
            0 => left_button,
            1 => middle_button,
            2 => right_button,
            else => 0,
        };
        const released = f == 'm' or button == 0;
        if (motion) {
            const pressed = self.buttons != 0;
            sink.pointer(sink.ctx, px, py, pressed, 0);
            return consumed;
        }
        if (released) {
            self.buttons = 0;
            sink.pointer(sink.ctx, px, py, false, @intCast(button));
        } else {
            self.buttons = button;
            sink.pointer(sink.ctx, px, py, true, @intCast(button));
        }
        return consumed;
    }
};

// ===================== tests =====================

const Log = struct {
    keys: std.ArrayList(u32) = .empty,
    texts: std.ArrayList(u8) = .empty,
    ptrs: std.ArrayList(i32) = .empty,
    scrolls: std.ArrayList(i32) = .empty,

    fn key(ctx: ?*anyopaque, code: u32, pressed: bool) void {
        const self: *Log = @ptrCast(@alignCast(ctx.?));
        // Only presses are recorded, with the code negated for a release, so an order test still sees both.
        self.keys.append(std.testing.allocator, if (pressed) code else ~code) catch {};
    }
    fn text(ctx: ?*anyopaque, bytes: []const u8) void {
        const self: *Log = @ptrCast(@alignCast(ctx.?));
        self.texts.appendSlice(std.testing.allocator, bytes) catch {};
    }
    fn pointer(ctx: ?*anyopaque, x: i32, y: i32, pressed: bool, button: u32) void {
        const self: *Log = @ptrCast(@alignCast(ctx.?));
        self.ptrs.appendSlice(std.testing.allocator, &.{ x, y, @intFromBool(pressed), @intCast(button) }) catch {};
    }
    fn scroll(ctx: ?*anyopaque, dx: f32, dy: f32) void {
        const self: *Log = @ptrCast(@alignCast(ctx.?));
        self.scrolls.appendSlice(std.testing.allocator, &.{ @intFromFloat(dx), @intFromFloat(dy) }) catch {};
    }
    fn sink(self: *Log) Sink {
        return .{ .ctx = self, .key = key, .text = text, .pointer = pointer, .scroll = scroll };
    }
    fn deinit(self: *Log) void {
        self.keys.deinit(std.testing.allocator);
        self.texts.deinit(std.testing.allocator);
        self.ptrs.deinit(std.testing.allocator);
        self.scrolls.deinit(std.testing.allocator);
    }
};

test "a printable byte is a key press and a piece of text" {
    var log = Log{};
    defer log.deinit();
    var d = Decoder{};
    d.feed("a", log.sink());
    try std.testing.expectEqual(@as(usize, 2), log.keys.items.len);
    try std.testing.expectEqual(@as(u32, 30), log.keys.items[0]);
    try std.testing.expectEqual(@as(u32, ~@as(u32, 30)), log.keys.items[1]);
    try std.testing.expectEqualStrings("a", log.texts.items);
}

test "the arrow keys decode from CSI, and a split sequence waits for its tail" {
    var log = Log{};
    defer log.deinit();
    var d = Decoder{};
    d.feed("\x1b[", log.sink());
    try std.testing.expectEqual(@as(usize, 0), log.keys.items.len);
    d.feed("A", log.sink());
    try std.testing.expectEqual(@as(u32, 103), log.keys.items[0]);
    try std.testing.expectEqual(@as(usize, 0), log.texts.items.len);
}

test "a lone escape is Escape, but only once the idle tick says so" {
    var log = Log{};
    defer log.deinit();
    var d = Decoder{};
    d.feed("\x1b", log.sink());
    try std.testing.expectEqual(@as(usize, 0), log.keys.items.len);
    d.idle(log.sink());
    try std.testing.expectEqual(@as(u32, 1), log.keys.items[0]);
}

test "enter, tab, backspace and ctrl+c are control bytes" {
    var log = Log{};
    defer log.deinit();
    var d = Decoder{};
    d.feed("\r\t\x7f\x03", log.sink());
    try std.testing.expectEqual(@as(u32, 28), log.keys.items[0]);
    try std.testing.expectEqual(@as(u32, 15), log.keys.items[2]);
    try std.testing.expectEqual(@as(u32, 14), log.keys.items[4]);
    // Ctrl+C arrives as a control byte, so the engine first sees Ctrl go down.
    try std.testing.expectEqual(@as(u32, 29), log.keys.items[6]);
    try std.testing.expectEqual(@as(u32, 46), log.keys.items[7]);
}

test "a modified arrow presses its modifier first and releases it last" {
    var log = Log{};
    defer log.deinit();
    var d = Decoder{};
    d.feed("\x1b[1;5C", log.sink());
    try std.testing.expectEqual(@as(u32, 29), log.keys.items[0]);
    try std.testing.expectEqual(@as(u32, 106), log.keys.items[1]);
    try std.testing.expectEqual(@as(u32, ~@as(u32, 29)), log.keys.items[3]);
}

test "the function keys arrive in both their SS3 and tilde forms" {
    var log = Log{};
    defer log.deinit();
    var d = Decoder{};
    d.feed("\x1bOP", log.sink());
    try std.testing.expectEqual(@as(u32, 59), log.keys.items[0]);
    d.feed("\x1b[24~", log.sink());
    try std.testing.expectEqual(@as(u32, 88), log.keys.items[2]);
}

test "a left click reports a press at the cell's centre, then a release" {
    var log = Log{};
    defer log.deinit();
    var d = Decoder{};
    d.feed("\x1b[<0;3;2M", log.sink());
    try std.testing.expectEqual(@as(i32, 20), log.ptrs.items[0]);
    try std.testing.expectEqual(@as(i32, 24), log.ptrs.items[1]);
    try std.testing.expectEqual(@as(i32, 1), log.ptrs.items[2]);
    try std.testing.expectEqual(@as(i32, 272), log.ptrs.items[3]);
    d.feed("\x1b[<0;3;2m", log.sink());
    try std.testing.expectEqual(@as(i32, 0), log.ptrs.items[6]);
}

test "the wheel becomes a scroll, up being negative" {
    var log = Log{};
    defer log.deinit();
    var d = Decoder{};
    d.feed("\x1b[<64;1;1M\x1b[<65;1;1M", log.sink());
    try std.testing.expectEqual(@as(i32, -1), log.scrolls.items[1]);
    try std.testing.expectEqual(@as(i32, 1), log.scrolls.items[3]);
}

test "motion carries button 0 so a drag stays a drag" {
    var log = Log{};
    defer log.deinit();
    var d = Decoder{};
    d.feed("\x1b[<0;2;2M\x1b[<32;4;4M", log.sink());
    // The motion event is the third recorded pointer: same press state, button 0.
    try std.testing.expectEqual(@as(i32, 28), log.ptrs.items[4]);
    try std.testing.expectEqual(@as(i32, 1), log.ptrs.items[6]);
    try std.testing.expectEqual(@as(i32, 0), log.ptrs.items[7]);
}

test "a bracketed paste is text, even when it contains an escape" {
    var log = Log{};
    defer log.deinit();
    var d = Decoder{};
    d.feed("\x1b[200~hi\x1b[Athere\x1b[201~", log.sink());
    try std.testing.expectEqualStrings("hi\x1b[Athere", log.texts.items);
    try std.testing.expectEqual(@as(usize, 0), log.keys.items.len);
}

test "UTF-8 text arrives whole" {
    var log = Log{};
    defer log.deinit();
    var d = Decoder{};
    d.feed("é", log.sink());
    try std.testing.expectEqualStrings("é", log.texts.items);
}
