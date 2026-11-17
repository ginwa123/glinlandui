// The single-line draft buffer: the caller's bytes, a caret, a selection, and what each key does to them; `input.zig` builds the Field on it.
const std = @import("std");
const text_editor = @import("../text_editor.zig");
const keyboard = @import("../keyboard_constant.zig");

// Raw evdev keycode → printable ASCII under the US layout.
pub fn keyChar(evdev: u32, shift: bool) ?u8 {
    // Letters: Q..P, A..L, Z..M rows.
    const lower = "qwertyuiopasdfghjklzxcvbnm";
    const codes = [_]u32{ 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 30, 31, 32, 33, 34, 35, 36, 37, 38, 44, 45, 46, 47, 48, 49, 50 };
    for (codes, 0..) |code, i| {
        if (evdev == code) {
            const c = lower[i];
            return if (shift) std.ascii.toUpper(c) else c;
        }
    }
    // Digits row (shifted: symbols).
    const digits = "1234567890";
    const shifted = "!@#$%^&*()";
    const dcodes = [_]u32{ 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    for (dcodes, 0..) |code, i| {
        if (evdev == code) return if (shift) shifted[i] else digits[i];
    }
    // Punctuation (unshifted, shifted).
    const punct = [_]struct { code: u32, plain: u8, shifted: u8 }{
        .{ .code = 12, .plain = '-', .shifted = '_' },
        .{ .code = 13, .plain = '=', .shifted = '+' },
        .{ .code = 26, .plain = '[', .shifted = '{' },
        .{ .code = 27, .plain = ']', .shifted = '}' },
        .{ .code = 39, .plain = ';', .shifted = ':' },
        .{ .code = 40, .plain = '\'', .shifted = '"' },
        .{ .code = 41, .plain = '`', .shifted = '~' },
        .{ .code = 43, .plain = '\\', .shifted = '|' },
        .{ .code = 51, .plain = ',', .shifted = '<' },
        .{ .code = 52, .plain = '.', .shifted = '>' },
        .{ .code = 53, .plain = '/', .shifted = '?' },
        .{ .code = 57, .plain = ' ', .shifted = ' ' },
    };
    for (punct) |p| {
        if (evdev == p.code) return if (shift) p.shifted else p.plain;
    }
    return null;
}

// Append a char to a caller-owned draft buffer.
pub fn insert(buf: []u8, len: *usize, c: u8) bool {
    if (len.* >= buf.len) return false;
    buf[len.*] = c;
    len.* += 1;
    return true;
}

// Drop the last byte (keymap is ASCII-only, so byte == char).
pub fn backspace(len: *usize) void {
    if (len.* > 0) len.* -= 1;
}

// ---- HTML-like caret + keyboard selection (single-line, ASCII) ---- The field used to be append-only (caret pinned at end).

// Navigation keys, from the one table: the number a backend reports is `Key`'s own tag.
pub const KEY_LEFT: u32 = keyboard.KEY_LEFT;
pub const KEY_RIGHT: u32 = keyboard.KEY_RIGHT;
pub const KEY_UP: u32 = keyboard.KEY_UP;
pub const KEY_DOWN: u32 = keyboard.KEY_DOWN;
pub const KEY_HOME: u32 = keyboard.KEY_HOME;
pub const KEY_END: u32 = keyboard.KEY_END;
pub const KEY_DELETE: u32 = keyboard.KEY_DELETE;
pub const KEY_BACKSPACE: u32 = keyboard.KEY_BACKSPACE;

// Caret + keyboard-selection state (owner-held, one per draft buffer).
pub const EditState = struct {
    caret: usize = 0,
    anchor: ?usize = null,
};

// Normalized selection span (start < end), or null when caret-only.
pub const Span = struct {
    start: usize,
    end: usize,
};

pub fn selection(st: EditState) ?Span {
    const a = st.anchor orelse return null;
    if (a == st.caret) return null;
    return .{ .start = @min(a, st.caret), .end = @max(a, st.caret) };
}

pub fn hasSelection(st: EditState) bool {
    return selection(st) != null;
}

// Clamp caret/anchor into 0..len (call after external len edits).
pub fn clampEdit(st: *EditState, len: usize) void {
    st.caret = @min(st.caret, len);
    if (st.anchor) |a| st.anchor = @min(a, len);
}

fn moveCaret(st: *EditState, len: usize, new_caret: usize, shift: bool) void {
    const c = @min(new_caret, len);
    if (shift) {
        if (st.anchor == null) st.anchor = st.caret;
        st.caret = c;
        // Shift+move back onto the anchor clears (HTML behavior).
        if (st.anchor == st.caret) st.anchor = null;
    } else {
        st.caret = c;
        st.anchor = null;
    }
}

// Arrow left: with an active selection and no Shift, collapses to the selection start (HTML); otherwise steps one byte left.
pub fn moveLeft(st: *EditState, len: usize, shift: bool) void {
    if (!shift) {
        if (selection(st.*)) |sp| {
            st.caret = sp.start;
            st.anchor = null;
            return;
        }
    }
    clampEdit(st, len);
    moveCaret(st, len, if (st.caret > 0) st.caret - 1 else 0, shift);
}

// Arrow right: mirror of moveLeft (collapses to selection end).
pub fn moveRight(st: *EditState, len: usize, shift: bool) void {
    if (!shift) {
        if (selection(st.*)) |sp| {
            st.caret = sp.end;
            st.anchor = null;
            return;
        }
    }
    clampEdit(st, len);
    moveCaret(st, len, st.caret + 1, shift);
}

pub fn moveHome(st: *EditState, shift: bool) void {
    moveCaret(st, st.caret, 0, shift);
}

pub fn moveEnd(st: *EditState, len: usize, shift: bool) void {
    moveCaret(st, len, len, shift);
}

// Ctrl+A: select the whole buffer (empty buffer selects nothing).
pub fn selectAll(st: *EditState, len: usize) void {
    clampEdit(st, len);
    st.caret = len;
    st.anchor = if (len > 0) 0 else null;
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

// Ctrl+Left target: skip non-word bytes leftward, then word bytes.
pub fn wordLeftEnd(buf: []const u8, len: usize, caret: usize) usize {
    var c = @min(caret, len);
    while (c > 0 and !isWordChar(buf[c - 1])) : (c -= 1) {}
    while (c > 0 and isWordChar(buf[c - 1])) : (c -= 1) {}
    return c;
}

// Ctrl+Right target: skip word bytes rightward, then non-word bytes (lands at the end of the current/next word, like browsers).
pub fn wordRightEnd(buf: []const u8, len: usize, caret: usize) usize {
    var c = @min(caret, len);
    while (c < len and isWordChar(buf[c])) : (c += 1) {}
    while (c < len and !isWordChar(buf[c])) : (c += 1) {}
    return c;
}

pub fn moveWordLeft(st: *EditState, buf: []const u8, len: usize, shift: bool) void {
    clampEdit(st, len);
    moveCaret(st, len, wordLeftEnd(buf, len, st.caret), shift);
}

pub fn moveWordRight(st: *EditState, buf: []const u8, len: usize, shift: bool) void {
    clampEdit(st, len);
    moveCaret(st, len, wordRightEnd(buf, len, st.caret), shift);
}

// Delete span [start,end), shifting the tail left. Returns the new len.
fn deleteSpan(buf: []u8, len: usize, start: usize, end: usize) usize {
    std.debug.assert(start <= end and end <= len);
    std.mem.copyForwards(u8, buf[start .. len - (end - start)], buf[end..len]);
    return len - (end - start);
}

// Type a char: replaces the selection when present, else inserts at the caret.
pub fn insertAt(buf: []u8, len: *usize, st: *EditState, c: u8) bool {
    if (selection(st.*)) |sp| {
        len.* = deleteSpan(buf, len.*, sp.start, sp.end);
        st.caret = sp.start;
        st.anchor = null;
    }
    clampEdit(st, len.*);
    if (len.* >= buf.len) return false;
    std.mem.copyBackwards(u8, buf[st.caret + 1 .. len.* + 1], buf[st.caret..len.*]);
    buf[st.caret] = c;
    len.* += 1;
    st.caret += 1;
    return true;
}

// Backspace: deletes the selection when present, else the byte before the caret (no-op at 0).
pub fn backspaceAt(buf: []u8, len: *usize, st: *EditState) void {
    if (selection(st.*)) |sp| {
        len.* = deleteSpan(buf, len.*, sp.start, sp.end);
        st.caret = sp.start;
        st.anchor = null;
        return;
    }
    clampEdit(st, len.*);
    if (st.caret == 0) return;
    // A whole codepoint, so Backspace over `\xc3\xa9` cannot leave half a character behind.
    const start = text_editor.prevCodepoint(buf[0..len.*], st.caret);
    len.* = deleteSpan(buf, len.*, start, st.caret);
    st.caret = start;
}

// Forward Delete: deletes the selection when present, else the byte at the caret (no-op at end).
pub fn deleteAt(buf: []u8, len: *usize, st: *EditState) void {
    if (selection(st.*)) |sp| {
        len.* = deleteSpan(buf, len.*, sp.start, sp.end);
        st.caret = sp.start;
        st.anchor = null;
        return;
    }
    clampEdit(st, len.*);
    if (st.caret >= len.*) return;
    const n = text_editor.codepointLen(buf[0..len.*], st.caret);
    len.* = deleteSpan(buf, len.*, st.caret, st.caret + n);
}

// Arrow/Home/End dispatch for a single-line field (Up/Down ignored).
pub fn handleNavKey(st: *EditState, buf: []const u8, len: usize, evdev: u32, shift: bool, ctrl: bool) bool {
    switch (evdev) {
        KEY_LEFT => {
            if (ctrl) moveWordLeft(st, buf, len, shift) else moveLeft(st, len, shift);
            return true;
        },
        KEY_RIGHT => {
            if (ctrl) moveWordRight(st, buf, len, shift) else moveRight(st, len, shift);
            return true;
        },
        KEY_HOME => {
            moveHome(st, shift);
            return true;
        },
        KEY_END => {
            moveEnd(st, len, shift);
            return true;
        },
        else => return false,
    }
}

// ---- Key-event state machine (component owns interpretation) ---- Why this lives here instead of views.zig: the Wayland loop delivers raw evdev to.

// Modifier latch: one per window (a single keyboard).
pub const Mods = struct {
    shift: bool = false,
    ctrl: bool = false,
    // Cmd on macOS, the Super/Windows key elsewhere. Its own flag, so an app can tell Cmd from Ctrl.
    super: bool = false,

    pub fn track(m: *Mods, evdev: u32, pressed: bool) bool {
        const key = keyboard.Key.fromCode(evdev) orelse return false;
        if (key.isShift()) {
            m.shift = pressed;
            return true;
        }
        if (key.isCtrl()) {
            m.ctrl = pressed;
            return true;
        }
        // Cmd/Meta is where macOS puts Cmd, so Cmd+C is no longer a plain `c`.
        if (key.isMeta()) {
            m.super = pressed;
            return true;
        }
        return false;
    }

    // True while either shortcut modifier is held: Cmd on macOS, Ctrl everywhere else.
    pub fn shortcut(m: Mods) bool {
        return m.ctrl or m.super;
    }
};

// What a key event means for the draft.
pub const Action = enum { ignored, edited, confirm };

pub const KEY_ENTER: u32 = keyboard.KEY_ENTER;
pub const KEY_A: u32 = keyboard.KEY_A;

// Full key handling for one draft buffer: arrows/Home/End (via handleNavKey), Backspace/Delete-at-caret, Ctrl+A select-all, Enter, printables.
pub fn handleKey(buf: []u8, len: *usize, st: *EditState, mods: Mods, evdev: u32, pressed: bool) Action {
    if (!pressed) return .ignored;
    if (handleNavKey(st, buf, len.*, evdev, mods.shift, mods.ctrl)) return .edited;
    switch (evdev) {
        KEY_BACKSPACE => {
            backspaceAt(buf, len, st);
            return .edited;
        },
        KEY_DELETE => {
            deleteAt(buf, len, st);
            return .edited;
        },
        KEY_ENTER => return .confirm,
        else => {},
    }
    // Ctrl held: only Ctrl+A selects here, and every other combo inserts nothing. Copy/cut/paste live in `dispatchKey`, which owns the field's clipboard.
    if (mods.ctrl) {
        if (keyChar(evdev, false)) |c| {
            if (c == 'a') {
                selectAll(st, len.*);
                return .edited;
            }
        }
        return .ignored;
    }
    if (keyChar(evdev, mods.shift)) |c| {
        return if (insertAt(buf, len, st, c)) .edited else .ignored;
    }
    return .ignored;
}

// Insert a run the platform already composed -- Caps Lock `A`, `*`, `(`, `\xc3\xa9` -- at the caret, replacing any selection.
pub fn handleText(buf: []u8, len: *usize, st: *EditState, text: []const u8) Action {
    if (text.len == 0) return .ignored;
    var inserted = false;
    for (text) |c| {
        if (insertAt(buf, len, st, c)) inserted = true;
    }
    return if (inserted) .edited else .ignored;
}

// ---- tests -------------------------------------------------------------------------------------------------

const testing = std.testing;

test "handleText inserts a composed run and Backspace removes a whole codepoint" {
    var buf: [16]u8 = undefined;
    var len: usize = 0;
    var st = EditState{};
    try std.testing.expectEqual(Action.edited, handleText(&buf, &len, &st, "A*("));
    try std.testing.expectEqualStrings("A*(", buf[0..len]);
    try std.testing.expectEqual(Action.edited, handleText(&buf, &len, &st, "\xc3\xa9"));
    try std.testing.expectEqual(@as(usize, 5), len);
    backspaceAt(&buf, &len, &st);
    try std.testing.expectEqualStrings("A*(", buf[0..len]);
    try std.testing.expectEqual(Action.ignored, handleText(&buf, &len, &st, ""));
}

test "keyChar maps evdev codes with and without shift" {
    // Letters.
    try std.testing.expectEqual(@as(?u8, 'a'), keyChar(30, false));
    try std.testing.expectEqual(@as(?u8, 'A'), keyChar(30, true));
    try std.testing.expectEqual(@as(?u8, 'z'), keyChar(44, false));
    try std.testing.expectEqual(@as(?u8, 'Z'), keyChar(44, true));
    try std.testing.expectEqual(@as(?u8, 'm'), keyChar(50, false));
    // Digits + shifted symbols.
    try std.testing.expectEqual(@as(?u8, '1'), keyChar(2, false));
    try std.testing.expectEqual(@as(?u8, '!'), keyChar(2, true));
    try std.testing.expectEqual(@as(?u8, '0'), keyChar(11, false));
    try std.testing.expectEqual(@as(?u8, ')'), keyChar(11, true));
    // Timezone/format punctuation.
    try std.testing.expectEqual(@as(?u8, '/'), keyChar(53, false));
    try std.testing.expectEqual(@as(?u8, '-'), keyChar(12, false));
    try std.testing.expectEqual(@as(?u8, '_'), keyChar(12, true));
    try std.testing.expectEqual(@as(?u8, ':'), keyChar(39, true));
    try std.testing.expectEqual(@as(?u8, '.'), keyChar(52, false));
    try std.testing.expectEqual(@as(?u8, ' '), keyChar(57, false));
    try std.testing.expectEqual(@as(?u8, ' '), keyChar(57, true));
    // Non-printables.
    try std.testing.expect(keyChar(1, false) == null); // Escape
    try std.testing.expect(keyChar(14, false) == null); // Backspace
    try std.testing.expect(keyChar(28, false) == null); // Enter
    try std.testing.expect(keyChar(42, false) == null); // Shift
    try std.testing.expect(keyChar(59, false) == null); // F1
}

test "insert appends until full, backspace drops bytes" {
    var buf: [4]u8 = undefined;
    var len: usize = 0;
    try std.testing.expect(insert(&buf, &len, 'a'));
    try std.testing.expect(insert(&buf, &len, 'b'));
    try std.testing.expectEqual(@as(usize, 2), len);
    try std.testing.expectEqualStrings("ab", buf[0..len]);
    try std.testing.expect(insert(&buf, &len, 'c'));
    try std.testing.expect(insert(&buf, &len, 'd'));
    try std.testing.expect(!insert(&buf, &len, 'e'));
    try std.testing.expectEqual(@as(usize, 4), len);
    backspace(&len);
    try std.testing.expectEqual(@as(usize, 3), len);
    backspace(&len);
    backspace(&len);
    backspace(&len);
    backspace(&len); // clamps at zero
    try std.testing.expectEqual(@as(usize, 0), len);
}

test "selection normalizes anchor/caret order, null when caret-only" {
    try std.testing.expect(selection(.{}) == null);
    try std.testing.expect(selection(.{ .caret = 2, .anchor = 2 }) == null);
    const fwd = selection(.{ .caret = 3, .anchor = 1 }).?;
    try std.testing.expectEqual(@as(usize, 1), fwd.start);
    try std.testing.expectEqual(@as(usize, 3), fwd.end);
    const rev = selection(.{ .caret = 1, .anchor = 3 }).?;
    try std.testing.expectEqual(@as(usize, 1), rev.start);
    try std.testing.expectEqual(@as(usize, 3), rev.end);
    try std.testing.expect(hasSelection(.{ .caret = 1, .anchor = 3 }));
    try std.testing.expect(!hasSelection(.{ .caret = 1 }));
}

test "clampEdit keeps caret/anchor inside the buffer" {
    var st = EditState{ .caret = 9, .anchor = 7 };
    clampEdit(&st, 3);
    try std.testing.expectEqual(@as(usize, 3), st.caret);
    try std.testing.expectEqual(@as(usize, 3), st.anchor.?);
    try std.testing.expect(!hasSelection(st));
}

// ---- Arrows: move + Shift-select ----

test "arrows step and clamp at both ends" {
    var st = EditState{ .caret = 1 };
    moveLeft(&st, 3, false);
    try std.testing.expectEqual(@as(usize, 0), st.caret);
    moveLeft(&st, 3, false); // clamps
    try std.testing.expectEqual(@as(usize, 0), st.caret);
    moveRight(&st, 3, false);
    moveRight(&st, 3, false);
    moveRight(&st, 3, false);
    try std.testing.expectEqual(@as(usize, 3), st.caret);
    moveRight(&st, 3, false); // clamps
    try std.testing.expectEqual(@as(usize, 3), st.caret);
}

test "shift+arrows extend, moving back onto anchor clears" {
    var st = EditState{ .caret = 1 };
    moveRight(&st, 3, true);
    try std.testing.expectEqual(@as(usize, 2), st.caret);
    try std.testing.expectEqual(@as(usize, 1), st.anchor.?);
    moveLeft(&st, 3, true); // back onto anchor -> cleared
    try std.testing.expectEqual(@as(usize, 1), st.caret);
    try std.testing.expect(st.anchor == null);
    moveLeft(&st, 3, true);
    const sp = selection(st).?;
    try std.testing.expectEqual(@as(usize, 0), sp.start);
    try std.testing.expectEqual(@as(usize, 1), sp.end);
}

test "plain arrow collapses selection to the edge in its direction" {
    var left = EditState{ .caret = 3, .anchor = 1 };
    moveLeft(&left, 4, false);
    try std.testing.expectEqual(@as(usize, 1), left.caret);
    try std.testing.expect(left.anchor == null);
    var right = EditState{ .caret = 1, .anchor = 3 };
    moveRight(&right, 4, false);
    try std.testing.expectEqual(@as(usize, 3), right.caret);
    try std.testing.expect(right.anchor == null);
}

test "home/end jump, shift extends" {
    var st = EditState{ .caret = 2 };
    moveHome(&st, false);
    try std.testing.expectEqual(@as(usize, 0), st.caret);
    moveEnd(&st, 5, false);
    try std.testing.expectEqual(@as(usize, 5), st.caret);
    moveHome(&st, true);
    const sp = selection(st).?;
    try std.testing.expectEqual(@as(usize, 0), sp.start);
    try std.testing.expectEqual(@as(usize, 5), sp.end);
    try std.testing.expectEqual(@as(usize, 0), st.caret); // active end left
}

test "selectAll covers the buffer, empty selects nothing" {
    var st = EditState{};
    selectAll(&st, 4);
    const sp = selection(st).?;
    try std.testing.expectEqual(@as(usize, 0), sp.start);
    try std.testing.expectEqual(@as(usize, 4), sp.end);
    var empty = EditState{};
    selectAll(&empty, 0);
    try std.testing.expect(!hasSelection(empty));
}

// ---- Word jumps ----

test "ctrl+arrows jump whole words" {
    const buf = "foo bar-baz";
    const len = buf.len; // 11
    // From end: to start of "bar-baz" (dash splits words).
    try std.testing.expectEqual(@as(usize, 8), wordLeftEnd(buf, len, 11));
    try std.testing.expectEqual(@as(usize, 4), wordLeftEnd(buf, len, 8));
    try std.testing.expectEqual(@as(usize, 0), wordLeftEnd(buf, len, 4));
    try std.testing.expectEqual(@as(usize, 0), wordLeftEnd(buf, len, 0));
    // From start: to end of "foo", then end of "bar-baz".
    try std.testing.expectEqual(@as(usize, 4), wordRightEnd(buf, len, 0));
    try std.testing.expectEqual(@as(usize, 8), wordRightEnd(buf, len, 4));
    try std.testing.expectEqual(@as(usize, 11), wordRightEnd(buf, len, 8));
    try std.testing.expectEqual(@as(usize, 11), wordRightEnd(buf, len, 11));
}

test "ctrl+shift+arrows extend by word" {
    const buf = "foo bar";
    var st = EditState{ .caret = 7 };
    moveWordLeft(&st, buf, 7, true);
    const sp = selection(st).?;
    try std.testing.expectEqual(@as(usize, 4), sp.start);
    try std.testing.expectEqual(@as(usize, 7), sp.end);
}

// ---- insertAt / backspaceAt / deleteAt ----

fn fillBuf(buf: []u8, s: []const u8) usize {
    @memcpy(buf[0..s.len], s);
    return s.len;
}

test "insertAt writes at caret, shifting the tail" {
    var buf: [8]u8 = undefined;
    var len = fillBuf(&buf, "ac");
    var st = EditState{ .caret = 1 };
    try std.testing.expect(insertAt(&buf, &len, &st, 'b'));
    try std.testing.expectEqualStrings("abc", buf[0..len]);
    try std.testing.expectEqual(@as(usize, 2), st.caret);
}

test "insertAt replaces the selection (type-replaces)" {
    var buf: [8]u8 = undefined;
    var len = fillBuf(&buf, "abcd");
    var st = EditState{ .caret = 3, .anchor = 1 };
    try std.testing.expect(insertAt(&buf, &len, &st, 'X'));
    try std.testing.expectEqualStrings("aXd", buf[0..len]);
    try std.testing.expectEqual(@as(usize, 2), st.caret);
    try std.testing.expect(!hasSelection(st));
}

test "insertAt on a full buffer fails without growing" {
    var buf: [2]u8 = .{ 'a', 'b' };
    var len: usize = 2;
    var st = EditState{ .caret = 2 };
    try std.testing.expect(!insertAt(&buf, &len, &st, 'c'));
    try std.testing.expectEqual(@as(usize, 2), len);
}

test "backspaceAt deletes before caret, clamps at zero" {
    var buf: [8]u8 = undefined;
    var len = fillBuf(&buf, "abc");
    var st = EditState{ .caret = 2 };
    backspaceAt(&buf, &len, &st);
    try std.testing.expectEqualStrings("ac", buf[0..len]);
    try std.testing.expectEqual(@as(usize, 1), st.caret);
    st.caret = 0;
    backspaceAt(&buf, &len, &st); // no-op
    try std.testing.expectEqualStrings("ac", buf[0..len]);
}

test "backspaceAt and deleteAt remove the whole selection" {
    var buf: [8]u8 = undefined;
    var len = fillBuf(&buf, "abcd");
    var st = EditState{ .caret = 3, .anchor = 1 };
    backspaceAt(&buf, &len, &st);
    try std.testing.expectEqualStrings("ad", buf[0..len]);
    try std.testing.expectEqual(@as(usize, 1), st.caret);

    len = fillBuf(&buf, "abcd");
    st = .{ .caret = 1, .anchor = 3 };
    deleteAt(&buf, &len, &st);
    try std.testing.expectEqualStrings("ad", buf[0..len]);
    try std.testing.expectEqual(@as(usize, 1), st.caret);
}

test "deleteAt removes at caret, no-op at end" {
    var buf: [8]u8 = undefined;
    var len = fillBuf(&buf, "abc");
    var st = EditState{ .caret = 1 };
    deleteAt(&buf, &len, &st);
    try std.testing.expectEqualStrings("ac", buf[0..len]);
    try std.testing.expectEqual(@as(usize, 1), st.caret);
    st.caret = 2;
    deleteAt(&buf, &len, &st); // no-op
    try std.testing.expectEqualStrings("ac", buf[0..len]);
}

// ---- handleNavKey dispatch ----

test "handleNavKey routes arrows/home/end, ignores up/down/other" {
    const buf = "abcd";
    var st = EditState{ .caret = 2 };
    try std.testing.expect(handleNavKey(&st, buf, 4, KEY_LEFT, false, false));
    try std.testing.expectEqual(@as(usize, 1), st.caret);
    try std.testing.expect(handleNavKey(&st, buf, 4, KEY_RIGHT, true, false));
    try std.testing.expect(hasSelection(st));
    try std.testing.expect(handleNavKey(&st, buf, 4, KEY_HOME, false, false));
    try std.testing.expectEqual(@as(usize, 0), st.caret);
    try std.testing.expect(handleNavKey(&st, buf, 4, KEY_END, false, false));
    try std.testing.expectEqual(@as(usize, 4), st.caret);
    try std.testing.expect(!handleNavKey(&st, buf, 4, KEY_UP, false, false));
    try std.testing.expect(!handleNavKey(&st, buf, 4, KEY_DOWN, false, false));
    try std.testing.expect(!handleNavKey(&st, buf, 4, 30, false, false)); // 'a'
}

test "handleNavKey ctrl+arrows move by word" {
    const buf = "foo bar";
    var st = EditState{ .caret = 7 };
    try std.testing.expect(handleNavKey(&st, buf, 7, KEY_LEFT, false, true));
    try std.testing.expectEqual(@as(usize, 4), st.caret);
    try std.testing.expect(handleNavKey(&st, buf, 7, KEY_RIGHT, false, true));
    try std.testing.expectEqual(@as(usize, 7), st.caret);
}

test "Mods.track latches shift/ctrl, consumes only mods" {
    var m = Mods{};
    try std.testing.expect(m.track(42, true)); // left shift press
    try std.testing.expect(m.shift);
    try std.testing.expect(m.track(42, false));
    try std.testing.expect(!m.shift);
    try std.testing.expect(m.track(29, true)); // left ctrl press
    try std.testing.expect(m.ctrl);
    try std.testing.expect(m.track(97, false)); // right ctrl release
    try std.testing.expect(!m.ctrl);
    try std.testing.expect(!m.track(30, true)); // 'a' not consumed
    try std.testing.expect(!m.track(105, true)); // Left not consumed
}

test "handleKey ignores releases" {
    var buf: [8]u8 = undefined;
    var len = fillBuf(&buf, "ab");
    var st = EditState{ .caret = 2 };
    try std.testing.expectEqual(Action.ignored, handleKey(&buf, &len, &st, .{}, 30, false));
    try std.testing.expectEqualStrings("ab", buf[0..len]);
}

test "handleKey routes nav/edit/enter/printable per draft" {
    var buf: [8]u8 = undefined;
    var len = fillBuf(&buf, "abc");
    var st = EditState{ .caret = 3 };
    // Left moves caret.
    try std.testing.expectEqual(Action.edited, handleKey(&buf, &len, &st, .{}, KEY_LEFT, true));
    try std.testing.expectEqual(@as(usize, 2), st.caret);
    // Printable inserts at caret.
    try std.testing.expectEqual(Action.edited, handleKey(&buf, &len, &st, .{}, KEY_A, true));
    try std.testing.expectEqualStrings("abac", buf[0..len]);
    // Backspace removes before caret.
    try std.testing.expectEqual(Action.edited, handleKey(&buf, &len, &st, .{}, KEY_BACKSPACE, true));
    try std.testing.expectEqualStrings("abc", buf[0..len]);
    // Forward Delete removes at caret.
    st.caret = 1;
    try std.testing.expectEqual(Action.edited, handleKey(&buf, &len, &st, .{}, KEY_DELETE, true));
    try std.testing.expectEqualStrings("ac", buf[0..len]);
    // Enter confirms (business logic stays owner-side).
    try std.testing.expectEqual(Action.confirm, handleKey(&buf, &len, &st, .{}, KEY_ENTER, true));
    // Unknown key ignored.
    try std.testing.expectEqual(Action.ignored, handleKey(&buf, &len, &st, .{}, 59, true)); // F1
}

test "handleKey shift+arrow selects, typing replaces it" {
    var buf: [8]u8 = undefined;
    var len = fillBuf(&buf, "abc");
    var st = EditState{ .caret = 3 };
    try std.testing.expectEqual(Action.edited, handleKey(&buf, &len, &st, .{ .shift = true }, KEY_LEFT, true));
    try std.testing.expect(hasSelection(st));
    try std.testing.expectEqual(Action.edited, handleKey(&buf, &len, &st, .{}, KEY_A, true));
    try std.testing.expectEqualStrings("aba", buf[0..len]);
    try std.testing.expect(!hasSelection(st));
}

test "handleKey ctrl+A selects all, other ctrl combos insert nothing" {
    var buf: [8]u8 = undefined;
    var len = fillBuf(&buf, "abc");
    var st = EditState{ .caret = 1 };
    try std.testing.expectEqual(Action.edited, handleKey(&buf, &len, &st, .{ .ctrl = true }, KEY_A, true));
    const sp = selection(st).?;
    try std.testing.expectEqual(@as(usize, 0), sp.start);
    try std.testing.expectEqual(@as(usize, 3), sp.end);
    // Ctrl+C (evdev 46) must not type.
    try std.testing.expectEqual(Action.ignored, handleKey(&buf, &len, &st, .{ .ctrl = true }, 46, true));
    try std.testing.expectEqualStrings("abc", buf[0..len]);
}
