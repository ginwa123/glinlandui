//! Escape sequences to the engine's keycodes: a terminal speaks keystrokes, the toolkit wants evdev codes.
const std = @import("std");

/// Sentinel for "no key".
pub const KEY_NONE: u32 = 0;

/// The evdev code an ASCII byte names, or 0 when the byte types text rather than pressing a key.
pub fn fromAscii(b: u8) u32 {
    if (b >= 'a' and b <= 'z') return switch (b) {
        'a' => 30,
        'b' => 48,
        'c' => 46,
        'd' => 32,
        'e' => 18,
        'f' => 33,
        'g' => 34,
        'h' => 35,
        'i' => 23,
        'j' => 36,
        'k' => 37,
        'l' => 38,
        'm' => 50,
        'n' => 49,
        'o' => 24,
        'p' => 25,
        'q' => 16,
        'r' => 19,
        's' => 31,
        't' => 20,
        'u' => 22,
        'v' => 47,
        'w' => 17,
        'x' => 45,
        'y' => 21,
        else => 44,
    };
    if (b >= 'A' and b <= 'Z') return fromAscii(b + 32);
    if (b >= '0' and b <= '9') return switch (b) {
        '1' => 2,
        '2' => 3,
        '3' => 4,
        '4' => 5,
        '5' => 6,
        '6' => 7,
        '7' => 8,
        '8' => 9,
        '9' => 10,
        else => 11,
    };
    return switch (b) {
        ' ' => 57,
        '-' => 12,
        '=' => 13,
        '[' => 26,
        ']' => 27,
        ';' => 39,
        '\'' => 40,
        '`' => 41,
        '\\' => 43,
        ',' => 51,
        '.' => 52,
        '/' => 53,
        else => KEY_NONE,
    };
}

/// The evdev code the final byte of a CSI/SS3 sequence names.
pub fn fromFinal(final: u8) u32 {
    return switch (final) {
        'A' => 103,
        'B' => 108,
        'C' => 106,
        'D' => 105,
        'H' => 102,
        'F' => 107,
        'P' => 59,
        'Q' => 60,
        'R' => 61,
        'S' => 62,
        'Z' => 15,
        else => KEY_NONE,
    };
}

/// The evdev code a `CSI n ~` key names: home, insert, delete, end, page up/down and F5 up.
pub fn fromTilde(n: u32) u32 {
    return switch (n) {
        1, 7 => 102,
        2 => 110,
        3 => 111,
        4, 8 => 107,
        5 => 104,
        6 => 109,
        11 => 59,
        12 => 60,
        13 => 61,
        14 => 62,
        15 => 63,
        17 => 64,
        18 => 65,
        19 => 66,
        20 => 67,
        21 => 68,
        23 => 87,
        24 => 88,
        else => KEY_NONE,
    };
}

/// The evdev code for F1..F4 as the SS3 form sends them (`ESC O P`..`ESC O S`).
pub fn fromSS3(final: u8) u32 {
    return switch (final) {
        'P' => 59,
        'Q' => 60,
        'R' => 61,
        'S' => 62,
        else => fromFinal(final),
    };
}

/// The control key an ASCII control byte stands for (`0x01` is Ctrl+A), or the key it is on its own.
pub fn fromControl(b: u8) u32 {
    return switch (b) {
        0x1b => 1,
        0x0d, 0x0a => 28,
        0x09 => 15,
        0x7f, 0x08 => 14,
        0x00, 0x20 => 57,
        else => if (b >= 0x01 and b <= 0x1a) fromAscii(b - 1 + 'a') else KEY_NONE,
    };
}

/// The modifier evdev codes a CSI modifier parameter (1 + shift + 2*alt + 4*ctrl) asks for, press order first.
pub const Modifiers = struct {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,

    pub fn fromParam(p: u32) Modifiers {
        // xterm sends 1 + the bitmask, so `1` is "no modifier" and `5` is Ctrl alone.
        if (p <= 1) return .{};
        const bits = p - 1;
        return .{
            .shift = (bits & 1) != 0,
            .alt = (bits & 2) != 0,
            .ctrl = (bits & 4) != 0,
        };
    }
};

test "letters, digits and punctuation map to their evdev codes" {
    try std.testing.expectEqual(@as(u32, 30), fromAscii('a'));
    try std.testing.expectEqual(@as(u32, 44), fromAscii('z'));
    try std.testing.expectEqual(@as(u32, 30), fromAscii('A'));
    try std.testing.expectEqual(@as(u32, 2), fromAscii('1'));
    try std.testing.expectEqual(@as(u32, 57), fromAscii(' '));
    try std.testing.expectEqual(@as(u32, KEY_NONE), fromAscii(0xC3));
}

test "the arrows, home and end come from the CSI final byte" {
    try std.testing.expectEqual(@as(u32, 103), fromFinal('A'));
    try std.testing.expectEqual(@as(u32, 108), fromFinal('B'));
    try std.testing.expectEqual(@as(u32, 106), fromFinal('C'));
    try std.testing.expectEqual(@as(u32, 105), fromFinal('D'));
    try std.testing.expectEqual(@as(u32, 107), fromFinal('F'));
    try std.testing.expectEqual(@as(u32, KEY_NONE), fromFinal('x'));
}

test "the tilde keys cover home, delete, paging and the function keys" {
    try std.testing.expectEqual(@as(u32, 110), fromTilde(2));
    try std.testing.expectEqual(@as(u32, 111), fromTilde(3));
    try std.testing.expectEqual(@as(u32, 104), fromTilde(5));
    try std.testing.expectEqual(@as(u32, 109), fromTilde(6));
    try std.testing.expectEqual(@as(u32, 63), fromTilde(15));
    try std.testing.expectEqual(@as(u32, 59), fromTilde(11));
    try std.testing.expectEqual(@as(u32, 88), fromTilde(24));
    try std.testing.expectEqual(@as(u32, KEY_NONE), fromTilde(99));
}

test "control bytes become the key they stand for" {
    try std.testing.expectEqual(@as(u32, 1), fromControl(0x1b));
    try std.testing.expectEqual(@as(u32, 28), fromControl(0x0d));
    try std.testing.expectEqual(@as(u32, 14), fromControl(0x7f));
    try std.testing.expectEqual(@as(u32, 30), fromControl(0x01));
}

test "a modifier parameter decodes into shift, alt and ctrl" {
    const m = Modifiers.fromParam(7);
    try std.testing.expect(m.ctrl);
    try std.testing.expect(m.alt);
    try std.testing.expect(!m.shift);
}
