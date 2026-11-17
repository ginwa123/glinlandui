// Every key the engine names, in ONE table, keyed by the Linux evdev code that is also what the mac, Windows and browser keymaps translate into.
const std = @import("std");

/// A physical key, by evdev code. The number a backend reports IS this enum's tag, so a raw keycode converts losslessly.
pub const Key = enum(u32) {
    none = 0,
    escape = 1,

    // Digits row.
    one = 2,
    two = 3,
    three = 4,
    four = 5,
    five = 6,
    six = 7,
    seven = 8,
    eight = 9,
    nine = 10,
    zero = 11,
    minus = 12,
    equal = 13,
    backspace = 14,
    tab = 15,

    // Letters: Q row, A row, Z row, with the punctuation between them.
    q = 16,
    w = 17,
    e = 18,
    r = 19,
    t = 20,
    y = 21,
    u = 22,
    i = 23,
    o = 24,
    p = 25,
    left_bracket = 26,
    right_bracket = 27,
    enter = 28,
    left_ctrl = 29,
    a = 30,
    s = 31,
    d = 32,
    f = 33,
    g = 34,
    h = 35,
    j = 36,
    k = 37,
    l = 38,
    semicolon = 39,
    apostrophe = 40,
    grave = 41,
    left_shift = 42,
    backslash = 43,
    z = 44,
    x = 45,
    c = 46,
    v = 47,
    b = 48,
    n = 49,
    m = 50,
    comma = 51,
    period = 52,
    slash = 53,
    right_shift = 54,
    keypad_multiply = 55,
    left_alt = 56,
    space = 57,
    caps_lock = 58,

    f1 = 59,
    f2 = 60,
    f3 = 61,
    f4 = 62,
    f5 = 63,
    f6 = 64,
    f7 = 65,
    f8 = 66,
    f9 = 67,
    f10 = 68,
    num_lock = 69,
    scroll_lock = 70,
    keypad_7 = 71,
    keypad_8 = 72,
    keypad_9 = 73,
    keypad_minus = 74,
    keypad_4 = 75,
    keypad_5 = 76,
    keypad_6 = 77,
    keypad_plus = 78,
    keypad_1 = 79,
    keypad_2 = 80,
    keypad_3 = 81,
    keypad_0 = 82,
    keypad_period = 83,
    f11 = 87,
    f12 = 88,

    keypad_enter = 96,
    right_ctrl = 97,
    keypad_slash = 98,
    print_screen = 99,
    right_alt = 100,

    home = 102,
    up = 103,
    page_up = 104,
    left = 105,
    right = 106,
    end = 107,
    down = 108,
    page_down = 109,
    insert = 110,
    delete = 111,

    left_meta = 125,
    right_meta = 126,

    /// The number a backend reports for this key.
    pub fn code(self: Key) u32 {
        return @intFromEnum(self);
    }

    /// The key a backend's number names, or null when the engine does not know it.
    pub fn fromCode(evdev: u32) ?Key {
        return std.enums.fromInt(Key, evdev);
    }

    /// The name a log or the devtool prints.
    pub fn name(self: Key) []const u8 {
        return @tagName(self);
    }

    /// True for a key that only modifies another one: Shift, Ctrl, Alt, the Cmd/Meta pair and Caps Lock.
    pub fn isModifier(self: Key) bool {
        return switch (self) {
            .left_shift, .right_shift, .left_ctrl, .right_ctrl, .left_alt, .right_alt, .left_meta, .right_meta, .caps_lock => true,
            else => false,
        };
    }

    /// True for either Shift.
    pub fn isShift(self: Key) bool {
        return self == .left_shift or self == .right_shift;
    }

    /// True for either Ctrl.
    pub fn isCtrl(self: Key) bool {
        return self == .left_ctrl or self == .right_ctrl;
    }

    /// True for either Alt/Option.
    pub fn isAlt(self: Key) bool {
        return self == .left_alt or self == .right_alt;
    }

    /// True for either Cmd/Meta/Super.
    pub fn isMeta(self: Key) bool {
        return self == .left_meta or self == .right_meta;
    }
};

// The same keys as the raw numbers an event carries, so a call site that compares `evdev` never spells a code by hand.
pub const KEY_ESCAPE: u32 = Key.escape.code();
pub const KEY_TAB: u32 = Key.tab.code();
pub const KEY_ENTER: u32 = Key.enter.code();
pub const KEY_BACKSPACE: u32 = Key.backspace.code();
pub const KEY_DELETE: u32 = Key.delete.code();
pub const KEY_INSERT: u32 = Key.insert.code();
pub const KEY_LEFT: u32 = Key.left.code();
pub const KEY_RIGHT: u32 = Key.right.code();
pub const KEY_UP: u32 = Key.up.code();
pub const KEY_DOWN: u32 = Key.down.code();
pub const KEY_HOME: u32 = Key.home.code();
pub const KEY_END: u32 = Key.end.code();
pub const KEY_PAGE_UP: u32 = Key.page_up.code();
pub const KEY_PAGE_DOWN: u32 = Key.page_down.code();
pub const KEY_SPACE: u32 = Key.space.code();
pub const KEY_MINUS: u32 = Key.minus.code();
pub const KEY_EQUAL: u32 = Key.equal.code();
pub const KEY_KP_MINUS: u32 = Key.keypad_minus.code();
pub const KEY_KP_PLUS: u32 = Key.keypad_plus.code();
pub const KEY_ZERO: u32 = Key.zero.code();
pub const KEY_LEFTSHIFT: u32 = Key.left_shift.code();
pub const KEY_LEFTCTRL: u32 = Key.left_ctrl.code();
pub const KEY_RIGHTCTRL: u32 = Key.right_ctrl.code();
pub const KEY_LEFTMETA: u32 = Key.left_meta.code();
pub const KEY_RIGHTMETA: u32 = Key.right_meta.code();
pub const KEY_A: u32 = Key.a.code();
pub const KEY_C: u32 = Key.c.code();
pub const KEY_K: u32 = Key.k.code();
pub const KEY_O: u32 = Key.o.code();
pub const KEY_S: u32 = Key.s.code();
pub const KEY_V: u32 = Key.v.code();
pub const KEY_X: u32 = Key.x.code();
pub const KEY_Y: u32 = Key.y.code();
pub const KEY_Z: u32 = Key.z.code();

// ---- tests ----

const testing = std.testing;

test "a key's code round-trips through the number a backend reports" {
    for ([_]Key{ .enter, .tab, .escape, .backspace, .left, .z, .y, .left_meta, .keypad_plus }) |key| {
        try testing.expectEqual(@as(?Key, key), Key.fromCode(key.code()));
    }
    // A code the engine does not name converts to nothing instead of inventing a key.
    try testing.expectEqual(@as(?Key, null), Key.fromCode(2000));
}

test "the named codes are the table's, so no call site spells a number" {
    try testing.expectEqual(@as(u32, 28), KEY_ENTER);
    try testing.expectEqual(@as(u32, 14), KEY_BACKSPACE);
    try testing.expectEqual(@as(u32, 111), KEY_DELETE);
    try testing.expectEqual(@as(u32, 105), KEY_LEFT);
    try testing.expectEqual(@as(u32, 29), KEY_LEFTCTRL);
    try testing.expectEqual(@as(u32, 125), KEY_LEFTMETA);
    // Redo is Ctrl+Y on Windows and Linux, and both letters have to be distinct keys.
    try testing.expect(KEY_Y != KEY_Z);
}

test "a modifier is recognised as one, and a letter is not" {
    try testing.expect(Key.left_shift.isModifier());
    try testing.expect(Key.right_meta.isModifier());
    try testing.expect(Key.caps_lock.isModifier());
    try testing.expect(!Key.a.isModifier());
    try testing.expect(Key.right_shift.isShift());
    try testing.expect(!Key.left_ctrl.isShift());
    try testing.expect(Key.right_alt.isAlt());
    try testing.expect(Key.right_ctrl.isCtrl());
    try testing.expect(Key.left_meta.isMeta());
    try testing.expectEqualStrings("backspace", Key.backspace.name());
}
