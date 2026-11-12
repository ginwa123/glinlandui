//! A single-line text input: the buffer, the caret, the selection, and every edit.

const std = @import("std");

/// What a key did.
pub const Action = enum {
    /// The key was not for this input.
    ignored,
    /// The text or the selection changed.
    edited,
    /// Enter: the caller decides what "submit" means.
    submitted,
};

/// Evdev key codes, so a caller can route raw keycodes without a translation table.
pub const KEY_BACKSPACE: u32 = 14;
pub const KEY_TAB: u32 = 15;
pub const KEY_ENTER: u32 = 28;
pub const KEY_LEFTCTRL: u32 = 29;
pub const KEY_A: u32 = 30;
pub const KEY_LEFTSHIFT: u32 = 42;
pub const KEY_HOME: u32 = 102;
pub const KEY_UP: u32 = 103;
pub const KEY_LEFT: u32 = 105;
pub const KEY_RIGHT: u32 = 106;
pub const KEY_END: u32 = 107;
pub const KEY_DOWN: u32 = 108;
pub const KEY_DELETE: u32 = 111;

pub const TextInput = struct {
    /// Caller-owned storage. The input never allocates and never grows it.
    buf: []u8,
    len: usize = 0,
    /// Byte offset of the caret.
    caret: usize = 0,
    /// The other end of the selection. Equal to `caret` when nothing is selected.
    anchor: usize = 0,
    /// Seconds since the caret last moved, which is what the view blinks on.
    idle: f32 = 0,
    /// Horizontal scroll in pixels, for text wider than the field.
    scroll_x: f32 = 0,

    pub fn init(buf: []u8) TextInput {
        return .{ .buf = buf };
    }

    pub fn text(self: *const TextInput) []const u8 {
        return self.buf[0..self.len];
    }

    /// Replace the whole value and put the caret at the end.
    pub fn setText(self: *TextInput, s: []const u8) void {
        const n = @min(s.len, self.buf.len);
        @memmove(self.buf[0..n], s[0..n]);
        self.len = n;
        self.caret = n;
        self.anchor = n;
        self.scroll_x = 0;
        self.idle = 0;
    }

    pub fn clear(self: *TextInput) void {
        self.len = 0;
        self.caret = 0;
        self.anchor = 0;
        self.scroll_x = 0;
        self.idle = 0;
    }

    // ---- selection ----

    pub fn hasSelection(self: *const TextInput) bool {
        return self.caret != self.anchor;
    }

    pub fn selStart(self: *const TextInput) usize {
        return @min(self.caret, self.anchor);
    }

    pub fn selEnd(self: *const TextInput) usize {
        return @max(self.caret, self.anchor);
    }

    pub fn selectAll(self: *TextInput) void {
        self.anchor = 0;
        self.caret = self.len;
        self.idle = 0;
    }

    /// Drop the selection, keeping the caret where it is.
    pub fn collapse(self: *TextInput) void {
        self.anchor = self.caret;
    }

    /// Delete the selected run, if any. Returns whether anything was removed.
    pub fn deleteSelection(self: *TextInput) bool {
        if (!self.hasSelection()) return false;
        const s = self.selStart();
        const e = self.selEnd();
        const tail = self.len - e;
        @memmove(self.buf[s..][0..tail], self.buf[e..self.len]);
        self.len -= e - s;
        self.caret = s;
        self.anchor = s;
        self.idle = 0;
        return true;
    }

    // ---- editing ----

    /// Insert `bytes` at the caret, replacing the selection. Truncates at the buffer's end.
    pub fn insert(self: *TextInput, bytes: []const u8) void {
        _ = self.deleteSelection();
        const room = self.buf.len - self.len;
        const n = @min(bytes.len, room);
        if (n == 0) return;
        const tail = self.len - self.caret;
        @memmove(self.buf[self.caret + n ..][0..tail], self.buf[self.caret..self.len]);
        @memcpy(self.buf[self.caret..][0..n], bytes[0..n]);
        self.len += n;
        self.caret += n;
        self.anchor = self.caret;
        self.idle = 0;
    }

    /// Delete the selection, or the character before the caret.
    pub fn backspace(self: *TextInput) bool {
        if (self.deleteSelection()) return true;
        if (self.caret == 0) return false;
        const from = self.prevBoundary(self.caret);
        const tail = self.len - self.caret;
        @memmove(self.buf[from..][0..tail], self.buf[self.caret..self.len]);
        self.len -= self.caret - from;
        self.caret = from;
        self.anchor = from;
        self.idle = 0;
        return true;
    }

    /// Delete the selection, or the character after the caret.
    pub fn delete(self: *TextInput) bool {
        if (self.deleteSelection()) return true;
        if (self.caret >= self.len) return false;
        const to = self.nextBoundary(self.caret);
        const tail = self.len - to;
        @memmove(self.buf[self.caret..][0..tail], self.buf[to..self.len]);
        self.len -= to - self.caret;
        self.anchor = self.caret;
        self.idle = 0;
        return true;
    }

    // ---- movement ----

    pub fn moveLeft(self: *TextInput, extend: bool) void {
        if (!extend and self.hasSelection()) {
            self.caret = self.selStart();
            self.anchor = self.caret;
        } else if (self.caret > 0) {
            self.caret = self.prevBoundary(self.caret);
            if (!extend) self.anchor = self.caret;
        }
        self.idle = 0;
    }

    pub fn moveRight(self: *TextInput, extend: bool) void {
        if (!extend and self.hasSelection()) {
            self.caret = self.selEnd();
            self.anchor = self.caret;
        } else if (self.caret < self.len) {
            self.caret = self.nextBoundary(self.caret);
            if (!extend) self.anchor = self.caret;
        }
        self.idle = 0;
    }

    pub fn moveWordLeft(self: *TextInput, extend: bool) void {
        var i = self.caret;
        while (i > 0 and !isWordByte(self.buf[i - 1])) i -= 1;
        while (i > 0 and isWordByte(self.buf[i - 1])) i -= 1;
        self.caret = i;
        if (!extend) self.anchor = i;
        self.idle = 0;
    }

    pub fn moveWordRight(self: *TextInput, extend: bool) void {
        var i = self.caret;
        while (i < self.len and isWordByte(self.buf[i])) i += 1;
        while (i < self.len and !isWordByte(self.buf[i])) i += 1;
        self.caret = i;
        if (!extend) self.anchor = i;
        self.idle = 0;
    }

    pub fn moveHome(self: *TextInput, extend: bool) void {
        self.caret = 0;
        if (!extend) self.anchor = 0;
        self.idle = 0;
    }

    pub fn moveEnd(self: *TextInput, extend: bool) void {
        self.caret = self.len;
        if (!extend) self.anchor = self.len;
        self.idle = 0;
    }

    // ---- pointer ----

    /// The byte offset nearest to a horizontal position, given a fixed character width.
    pub fn caretAtX(self: *const TextInput, x: f32, char_w: f32) usize {
        if (char_w <= 0) return self.caret;
        const col_f = @max(x, 0) / char_w;
        const col: usize = @intFromFloat(@round(col_f));
        return @min(col, self.len);
    }

    /// Place the caret from a click. `extend` keeps the anchor, which is what a shift-click does.
    pub fn clickAt(self: *TextInput, x: f32, char_w: f32, extend: bool) void {
        self.caret = self.caretAtX(x, char_w);
        if (!extend) self.anchor = self.caret;
        self.idle = 0;
    }

    /// Extend the selection to a drag position.
    pub fn dragTo(self: *TextInput, x: f32, char_w: f32) void {
        self.caret = self.caretAtX(x, char_w);
        self.idle = 0;
    }

    /// Select the word under a position, which is what a double-click does.
    pub fn selectWordAt(self: *TextInput, x: f32, char_w: f32) void {
        const at = self.caretAtX(x, char_w);
        var s = at;
        var e = at;
        while (s > 0 and isWordByte(self.buf[s - 1])) s -= 1;
        while (e < self.len and isWordByte(self.buf[e])) e += 1;
        self.anchor = s;
        self.caret = e;
        self.idle = 0;
    }

    // ---- keys ----

    /// Route one key. `ctrl` is the platform's command modifier.
    pub fn handleKey(self: *TextInput, keycode: u32, shift: bool, ctrl: bool) Action {
        switch (keycode) {
            KEY_ENTER => return .submitted,
            KEY_BACKSPACE => return if (self.backspace()) .edited else .ignored,
            KEY_DELETE => return if (self.delete()) .edited else .ignored,
            KEY_LEFT => {
                if (ctrl) self.moveWordLeft(shift) else self.moveLeft(shift);
                return .edited;
            },
            KEY_RIGHT => {
                if (ctrl) self.moveWordRight(shift) else self.moveRight(shift);
                return .edited;
            },
            KEY_HOME => {
                self.moveHome(shift);
                return .edited;
            },
            KEY_END => {
                self.moveEnd(shift);
                return .edited;
            },
            KEY_A => {
                if (!ctrl) return .ignored;
                self.selectAll();
                return .edited;
            },
            else => {},
        }
        return .ignored;
    }

    // ---- helpers ----

    /// Step back one UTF-8 codepoint, so Backspace never splits a multi-byte character.
    fn prevBoundary(self: *const TextInput, at: usize) usize {
        if (at == 0) return 0;
        var i = at - 1;
        while (i > 0 and (self.buf[i] & 0xC0) == 0x80) i -= 1;
        return i;
    }

    /// Step forward one UTF-8 codepoint.
    fn nextBoundary(self: *const TextInput, at: usize) usize {
        if (at >= self.len) return self.len;
        var i = at + 1;
        while (i < self.len and (self.buf[i] & 0xC0) == 0x80) i += 1;
        return i;
    }
};

fn isWordByte(b: u8) bool {
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9') or b == '_';
}

// ---- tests ----

const testing = std.testing;

fn make(buf: []u8, s: []const u8) TextInput {
    var t = TextInput.init(buf);
    t.setText(s);
    return t;
}

test "setText puts the caret at the end and selects nothing" {
    var buf: [32]u8 = undefined;
    const t = make(&buf, "hello");
    try testing.expectEqualStrings("hello", t.text());
    try testing.expectEqual(@as(usize, 5), t.caret);
    try testing.expect(!t.hasSelection());
}

test "typing inserts at the caret and moves it" {
    var buf: [32]u8 = undefined;
    var t = make(&buf, "ac");
    t.caret = 1;
    t.anchor = 1;
    t.insert("b");
    try testing.expectEqualStrings("abc", t.text());
    try testing.expectEqual(@as(usize, 2), t.caret);
}

test "typing over a selection replaces it" {
    var buf: [32]u8 = undefined;
    var t = make(&buf, "hello world");
    t.anchor = 0;
    t.caret = 5;
    t.insert("bye");
    try testing.expectEqualStrings("bye world", t.text());
    try testing.expectEqual(@as(usize, 3), t.caret);
}

test "backspace deletes the character before the caret" {
    var buf: [32]u8 = undefined;
    var t = make(&buf, "abc");
    try testing.expect(t.backspace());
    try testing.expectEqualStrings("ab", t.text());
    try testing.expectEqual(@as(usize, 2), t.caret);
}

test "backspace at the start does nothing" {
    var buf: [32]u8 = undefined;
    var t = make(&buf, "abc");
    t.caret = 0;
    t.anchor = 0;
    try testing.expect(!t.backspace());
    try testing.expectEqualStrings("abc", t.text());
}

test "backspace deletes a whole selection, not one character" {
    var buf: [32]u8 = undefined;
    var t = make(&buf, "hello world");
    t.anchor = 5;
    t.caret = 11;
    try testing.expect(t.backspace());
    try testing.expectEqualStrings("hello", t.text());
    try testing.expectEqual(@as(usize, 5), t.caret);
}

test "delete removes the character after the caret" {
    var buf: [32]u8 = undefined;
    var t = make(&buf, "abc");
    t.caret = 1;
    t.anchor = 1;
    try testing.expect(t.delete());
    try testing.expectEqualStrings("ac", t.text());
}

test "left and right move by one, and collapse a selection first" {
    var buf: [32]u8 = undefined;
    var t = make(&buf, "abcdef");
    t.anchor = 1;
    t.caret = 4;
    t.moveLeft(false);
    try testing.expectEqual(@as(usize, 1), t.caret);
    try testing.expect(!t.hasSelection());

    t.moveRight(false);
    try testing.expectEqual(@as(usize, 2), t.caret);
}

test "shift+left extends the selection instead of collapsing it" {
    var buf: [32]u8 = undefined;
    var t = make(&buf, "abcdef");
    t.moveLeft(true);
    t.moveLeft(true);
    try testing.expectEqual(@as(usize, 4), t.caret);
    try testing.expectEqual(@as(usize, 6), t.anchor);
    try testing.expectEqual(@as(usize, 4), t.selStart());
    try testing.expectEqual(@as(usize, 6), t.selEnd());
}

test "home and end go to the ends" {
    var buf: [32]u8 = undefined;
    var t = make(&buf, "abcdef");
    t.moveHome(false);
    try testing.expectEqual(@as(usize, 0), t.caret);
    t.moveEnd(false);
    try testing.expectEqual(@as(usize, 6), t.caret);
}

test "ctrl+left and ctrl+right move by word" {
    var buf: [32]u8 = undefined;
    var t = make(&buf, "select * from users");
    t.moveWordLeft(false);
    try testing.expectEqual(@as(usize, 14), t.caret);
    t.moveWordLeft(false);
    try testing.expectEqual(@as(usize, 9), t.caret);
    t.moveWordRight(false);
    try testing.expectEqual(@as(usize, 14), t.caret);
}

test "select all, then typing replaces everything" {
    var buf: [32]u8 = undefined;
    var t = make(&buf, "old text");
    t.selectAll();
    try testing.expect(t.hasSelection());
    t.insert("new");
    try testing.expectEqualStrings("new", t.text());
}

test "a click places the caret at the nearest character" {
    var buf: [32]u8 = undefined;
    var t = make(&buf, "abcdef");
    t.clickAt(21, 7, false);
    try testing.expectEqual(@as(usize, 3), t.caret);
    try testing.expect(!t.hasSelection());
}

test "a shift-click extends the selection from the anchor" {
    var buf: [32]u8 = undefined;
    var t = make(&buf, "abcdef");
    t.clickAt(0, 7, false);
    t.clickAt(28, 7, true);
    try testing.expectEqual(@as(usize, 0), t.selStart());
    try testing.expectEqual(@as(usize, 4), t.selEnd());
}

test "a double-click selects the word under the pointer" {
    var buf: [32]u8 = undefined;
    var t = make(&buf, "select * from users");
    t.selectWordAt(63, 7);
    try testing.expectEqualStrings("from", t.text()[t.selStart()..t.selEnd()]);
}

test "a click past the end clamps to the end" {
    var buf: [32]u8 = undefined;
    var t = make(&buf, "abc");
    t.clickAt(9999, 7, false);
    try testing.expectEqual(@as(usize, 3), t.caret);
}

test "insert truncates at the buffer's end instead of overflowing" {
    var buf: [4]u8 = undefined;
    var t = TextInput.init(&buf);
    t.insert("abcdefgh");
    try testing.expectEqualStrings("abcd", t.text());
    try testing.expectEqual(@as(usize, 4), t.caret);
}

test "backspace never splits a multi-byte character" {
    var buf: [32]u8 = undefined;
    // "é" is two bytes.
    var t = make(&buf, "aé");
    try testing.expect(t.backspace());
    try testing.expectEqualStrings("a", t.text());
}

test "handleKey reports submitted on Enter and edited on typing keys" {
    var buf: [32]u8 = undefined;
    var t = make(&buf, "abc");
    try testing.expectEqual(Action.submitted, t.handleKey(KEY_ENTER, false, false));
    try testing.expectEqual(Action.edited, t.handleKey(KEY_BACKSPACE, false, false));
    try testing.expectEqual(Action.ignored, t.handleKey(999, false, false));
}

test "ctrl+a selects everything, plain a does not" {
    var buf: [32]u8 = undefined;
    var t = make(&buf, "abc");
    try testing.expectEqual(Action.ignored, t.handleKey(KEY_A, false, false));
    try testing.expectEqual(Action.edited, t.handleKey(KEY_A, false, true));
    try testing.expect(t.hasSelection());
}
