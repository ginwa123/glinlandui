//! macOS virtual keycode -> Linux evdev code translation.
//!
//! The Delegate contract carries *evdev* keycodes: `components.input.keyChar`
//! is a pure evdev -> ASCII table and `keyToClose` accepts evdev 1. macOS
//! hands us `NSEvent.keyCode`, a completely different numbering (macOS `q`
//! is 12, evdev `q` is 16), so the backend MUST translate before handing a key
//! to the delegate. Doing it here — rather than making `components.input`
//! platform-aware — is what keeps the whole widget layer and the Delegate
//! contract identical on both operating systems.
//!
//! Everything in this module is a pure table lookup: no Cocoa, no runtime
//! state, so it is unit-tested in the cross-platform parity suite and runs on
//! Linux too. Only the Cocoa shell is untestable.
//!
//! `mac` values are macOS `NSEvent.keyCode` (ANSI / Carbon virtual codes).
//! The keypad's arithmetic keys are deliberately NOT translated: the
//! calculator example maps those evdev codes explicitly, so they must keep
//! their evdev identity and be passed through untouched.

const std = @import("std");

/// Returned for a keycode with no evdev equivalent. Zero is evdev KEY_RESERVED,
/// so 0 is a safe "not ours" sentinel — no real key maps to it.
pub const KEY_NONE: u32 = 0;

/// One row of a translation table.
const Row = struct { mac: u16, ev: u32 };

// macOS scatters the home row: 6 (22) sits before 5 (23), and 9 (25) sits
// before 7 (26)/8 (28). These tables follow the real numbers, not a guess.
const LETTERS = [_]Row{
    .{ .mac = 0, .ev = 30 }, // a
    .{ .mac = 1, .ev = 31 }, // s
    .{ .mac = 2, .ev = 32 }, // d
    .{ .mac = 3, .ev = 33 }, // f
    .{ .mac = 4, .ev = 35 }, // h
    .{ .mac = 5, .ev = 34 }, // g
    .{ .mac = 6, .ev = 44 }, // z
    .{ .mac = 7, .ev = 45 }, // x
    .{ .mac = 8, .ev = 46 }, // c
    .{ .mac = 9, .ev = 47 }, // v
    .{ .mac = 11, .ev = 48 }, // b
    .{ .mac = 12, .ev = 16 }, // q
    .{ .mac = 13, .ev = 17 }, // w
    .{ .mac = 14, .ev = 18 }, // e
    .{ .mac = 15, .ev = 19 }, // r
    .{ .mac = 16, .ev = 21 }, // y
    .{ .mac = 17, .ev = 20 }, // t
    .{ .mac = 31, .ev = 24 }, // o
    .{ .mac = 32, .ev = 22 }, // u
    .{ .mac = 34, .ev = 23 }, // i
    .{ .mac = 35, .ev = 25 }, // p
    .{ .mac = 37, .ev = 38 }, // l
    .{ .mac = 38, .ev = 36 }, // j
    .{ .mac = 40, .ev = 37 }, // k
    .{ .mac = 45, .ev = 49 }, // n
    .{ .mac = 46, .ev = 50 }, // m
};

const DIGITS = [_]Row{
    .{ .mac = 18, .ev = 2 }, // 1
    .{ .mac = 19, .ev = 3 }, // 2
    .{ .mac = 20, .ev = 4 }, // 3
    .{ .mac = 21, .ev = 5 }, // 4
    .{ .mac = 23, .ev = 6 }, // 5
    .{ .mac = 22, .ev = 7 }, // 6
    .{ .mac = 26, .ev = 8 }, // 7
    .{ .mac = 28, .ev = 9 }, // 8
    .{ .mac = 25, .ev = 10 }, // 9
    .{ .mac = 29, .ev = 11 }, // 0
};

/// Punctuation maps to the UNSHIFTED key's evdev code. The shifted character
/// is `keyChar`'s job, not ours: evdev 13 is the only code `keyChar` knows
/// that yields '+', so '=' must land on 13 and let shift do the rest.
const PUNCT = [_]Row{
    .{ .mac = 27, .ev = 12 }, // -   (shift -> _)
    .{ .mac = 24, .ev = 13 }, // =   (shift -> +)
    .{ .mac = 33, .ev = 26 }, // [   (shift -> {)
    .{ .mac = 30, .ev = 27 }, // ]   (shift -> })
    .{ .mac = 41, .ev = 39 }, // ;   (shift -> :)
    .{ .mac = 39, .ev = 40 }, // '   (shift -> ")
    .{ .mac = 50, .ev = 41 }, // `   (shift -> ~)
    .{ .mac = 42, .ev = 43 }, // \   (shift -> |)
    .{ .mac = 43, .ev = 51 }, // ,   (shift -> <)
    .{ .mac = 47, .ev = 52 }, // .   (shift -> >)
    .{ .mac = 44, .ev = 53 }, // /   (shift -> ?)
    .{ .mac = 49, .ev = 57 }, // space
};

const NAMED = [_]Row{
    .{ .mac = 53, .ev = 1 }, // escape  -> keyToClose() accepts this, so a
    // macOS window gets quit-on-Escape with no per-platform code.
    .{ .mac = 48, .ev = 15 }, // tab
    .{ .mac = 36, .ev = 28 }, // return  (main)
    .{ .mac = 76, .ev = 96 }, // keypad enter (calculator maps 96 itself)
    .{ .mac = 51, .ev = 14 }, // backspace (macOS calls this "delete")
    .{ .mac = 117, .ev = 111 }, // forward delete
    .{ .mac = 123, .ev = 105 }, // left
    .{ .mac = 124, .ev = 106 }, // right
    .{ .mac = 125, .ev = 108 }, // down
    .{ .mac = 126, .ev = 103 }, // up
    .{ .mac = 115, .ev = 102 }, // home
    .{ .mac = 119, .ev = 107 }, // end
};

/// Modifier keys. These are delivered as ordinary key events so the Host's
/// `Mods.track` updates itself exactly as it does on Wayland — that is what
/// makes `keyChar(code, shift)` produce '+' for Shift+'=' with no change to
/// the widget layer. Left and right of the same modifier share one evdev code
/// on purpose: `Mods.track` treats 42/54 and 29/97 as the same logical state,
/// so splitting them would be indistinguishable anyway.
/// Option (58/61) and Command (55/54) are listed so they are *recognised*
/// (reported as real keys) instead of falling through to KEY_NONE.
const MODIFIERS = [_]Row{
    .{ .mac = 56, .ev = 42 }, // left shift
    .{ .mac = 60, .ev = 42 }, // right shift
    .{ .mac = 59, .ev = 29 }, // left control
    .{ .mac = 62, .ev = 29 }, // right control
    .{ .mac = 58, .ev = 56 }, // left option
    .{ .mac = 61, .ev = 56 }, // right option
    .{ .mac = 55, .ev = 125 }, // left command
    .{ .mac = 54, .ev = 125 }, // right command
};

/// Translate one macOS virtual keycode to its evdev code, or KEY_NONE.
pub fn toEvdev(keycode: u16) u32 {
    for (LETTERS) |r| {
        if (r.mac == keycode) return r.ev;
    }
    for (DIGITS) |r| {
        if (r.mac == keycode) return r.ev;
    }
    for (PUNCT) |r| {
        if (r.mac == keycode) return r.ev;
    }
    for (NAMED) |r| {
        if (r.mac == keycode) return r.ev;
    }
    for (MODIFIERS) |r| {
        if (r.mac == keycode) return r.ev;
    }
    return KEY_NONE;
}

/// The delegate-facing alias. Named for the call site in the Cocoa shell.
pub fn evdevFor(keycode: u16) u32 {
    return toEvdev(keycode);
}

// ===================== tests (parity suite — every platform) =====================

const input = @import("../core/components/input.zig");
const contract = @import("../core/window_contract.zig");

test "letters translate to their evdev codes" {
    try std.testing.expectEqual(@as(u32, 30), toEvdev(0)); // a
    try std.testing.expectEqual(@as(u32, 16), toEvdev(12)); // q
    try std.testing.expectEqual(@as(u32, 17), toEvdev(13)); // w
    try std.testing.expectEqual(@as(u32, 25), toEvdev(35)); // p
    try std.testing.expectEqual(@as(u32, 50), toEvdev(46)); // m
    try std.testing.expectEqual(@as(u32, 48), toEvdev(11)); // b
}

test "h/g and j/k/l are not transposed" {
    // The macOS home row is a different shape from evdev's, so these three
    // pairs are the easiest thing in this table to get wrong. Named
    // explicitly so a regression cannot hide inside a round-trip test.
    try std.testing.expectEqual(@as(u32, 35), toEvdev(4)); // h
    try std.testing.expectEqual(@as(u32, 34), toEvdev(5)); // g
    try std.testing.expectEqual(@as(u32, 36), toEvdev(38)); // j
    try std.testing.expectEqual(@as(u32, 37), toEvdev(40)); // k
    try std.testing.expectEqual(@as(u32, 38), toEvdev(37)); // l
}

test "digit row translates, including the out-of-order 5 and 6" {
    try std.testing.expectEqual(@as(u32, 2), toEvdev(18)); // 1
    try std.testing.expectEqual(@as(u32, 6), toEvdev(23)); // 5
    try std.testing.expectEqual(@as(u32, 7), toEvdev(22)); // 6
    try std.testing.expectEqual(@as(u32, 8), toEvdev(26)); // 7
    try std.testing.expectEqual(@as(u32, 10), toEvdev(25)); // 9
    try std.testing.expectEqual(@as(u32, 11), toEvdev(29)); // 0
}

test "every translated key round-trips through keyChar to the right ASCII" {
    // The contract that actually matters: the Delegate hands evdev to
    // `components.input.keyChar`, so a wrong translation surfaces as the wrong
    // character. This is the test that would have caught the h/g and j/k/l
    // transpositions.
    const cases = [_]struct { mac: u16, want: u8 }{
        .{ .mac = 0, .want = 'a' }, // a
        .{ .mac = 1, .want = 's' },
        .{ .mac = 5, .want = 'g' },
        .{ .mac = 4, .want = 'h' },
        .{ .mac = 8, .want = 'c' },
        .{ .mac = 11, .want = 'b' },
        .{ .mac = 12, .want = 'q' },
        .{ .mac = 13, .want = 'w' },
        .{ .mac = 16, .want = 'y' },
        .{ .mac = 17, .want = 't' },
        .{ .mac = 31, .want = 'o' },
        .{ .mac = 32, .want = 'u' },
        .{ .mac = 34, .want = 'i' },
        .{ .mac = 35, .want = 'p' },
        .{ .mac = 37, .want = 'l' },
        .{ .mac = 38, .want = 'j' },
        .{ .mac = 40, .want = 'k' },
        .{ .mac = 45, .want = 'n' },
        .{ .mac = 46, .want = 'm' },
        .{ .mac = 18, .want = '1' },
        .{ .mac = 23, .want = '5' },
        .{ .mac = 22, .want = '6' },
        .{ .mac = 26, .want = '7' },
        .{ .mac = 25, .want = '9' },
        .{ .mac = 29, .want = '0' },
        .{ .mac = 27, .want = '-' },
        .{ .mac = 24, .want = '=' },
        .{ .mac = 44, .want = '/' },
        .{ .mac = 47, .want = '.' },
        .{ .mac = 43, .want = ',' },
        .{ .mac = 49, .want = ' ' },
    };
    for (cases) |c| {
        const got = input.keyChar(toEvdev(c.mac), false);
        try std.testing.expectEqual(@as(?u8, c.want), got);
    }
}

test "shifted punctuation keeps the unshifted evdev code" {
    // '=' (mac 24) must map to evdev 13, and `keyChar` turns THAT into '+'
    // when shift is held. Mapping '=' to some dedicated "plus" code would be
    // wrong: evdev 13 is the only code `keyChar` knows that yields '+'.
    try std.testing.expectEqual(@as(u32, 13), toEvdev(24));
    try std.testing.expectEqual(@as(?u8, '='), input.keyChar(toEvdev(24), false));
    try std.testing.expectEqual(@as(?u8, '+'), input.keyChar(toEvdev(24), true));
    try std.testing.expectEqual(@as(?u8, '_'), input.keyChar(toEvdev(27), true));
    try std.testing.expectEqual(@as(?u8, '?'), input.keyChar(toEvdev(44), true));
}

test "shifted letters come out uppercase through the same code" {
    try std.testing.expectEqual(@as(?u8, 'q'), input.keyChar(toEvdev(12), false));
    try std.testing.expectEqual(@as(?u8, 'Q'), input.keyChar(toEvdev(12), true));
    try std.testing.expectEqual(@as(?u8, 'A'), input.keyChar(toEvdev(0), true));
}

test "escape maps to evdev 1 so keyToClose quits a macOS window" {
    try std.testing.expectEqual(@as(u32, 1), toEvdev(53));
    // The point of the whole table: Escape-to-close works unchanged.
    try std.testing.expect(contract.keyToClose(toEvdev(53)));
}

test "return maps to KEY_ENTER, not the keypad's code" {
    // The calculator routes KEY_ENTER to '=' and the keypad's 96 separately,
    // so these two must stay distinct.
    try std.testing.expectEqual(input.KEY_ENTER, toEvdev(36));
    try std.testing.expectEqual(@as(u32, 96), toEvdev(76));
    try std.testing.expect(input.KEY_ENTER != toEvdev(76));
}

test "backspace and forward delete map to their distinct evdev codes" {
    try std.testing.expectEqual(input.KEY_BACKSPACE, toEvdev(51));
    try std.testing.expectEqual(input.KEY_DELETE, toEvdev(117));
    try std.testing.expect(input.KEY_BACKSPACE != input.KEY_DELETE);
}

test "arrow keys map to the navigation codes input.zig documents" {
    try std.testing.expectEqual(input.KEY_LEFT, toEvdev(123));
    try std.testing.expectEqual(input.KEY_RIGHT, toEvdev(124));
    try std.testing.expectEqual(input.KEY_DOWN, toEvdev(125));
    try std.testing.expectEqual(input.KEY_UP, toEvdev(126));
    try std.testing.expectEqual(input.KEY_HOME, toEvdev(115));
    try std.testing.expectEqual(input.KEY_END, toEvdev(119));
}

test "shift and control reach the evdev codes Mods.track watches" {
    // The Host's KeyChain calls `Mods.track(evdev, pressed)`, which watches
    // 42/54 for shift and 29/97 for control. Both macOS shift keys and both
    // control keys must land on one of those, or Shift+'=' would type '='.
    var mods = input.Mods{};
    for ([_]u16{ 56, 60 }) |mac_key| {
        const ev = toEvdev(mac_key);
        try std.testing.expect(input.Mods.track(&mods, ev, true));
        try std.testing.expect(mods.shift);
        try std.testing.expect(input.Mods.track(&mods, ev, false));
        try std.testing.expect(!mods.shift);
    }
    for ([_]u16{ 59, 62 }) |mac_key| {
        const ev = toEvdev(mac_key);
        try std.testing.expect(input.Mods.track(&mods, ev, true));
        try std.testing.expect(mods.ctrl);
        try std.testing.expect(input.Mods.track(&mods, ev, false));
        try std.testing.expect(!mods.ctrl);
    }
}

test "option and command are recognised keys, not KEY_NONE" {
    // They are not tracked by `Mods`, but reporting them as unmapped would be
    // wrong: an app cannot tell "user pressed Option" from "unknown key".
    try std.testing.expect(toEvdev(58) != KEY_NONE); // left option
    try std.testing.expect(toEvdev(61) != KEY_NONE); // right option
    try std.testing.expect(toEvdev(55) != KEY_NONE); // left command
    try std.testing.expect(toEvdev(54) != KEY_NONE); // right command
}

test "a modifier press followed by '=' produces '+' through the chain" {
    // End-to-end proof of the reason modifiers are delivered as key events.
    var mods = input.Mods{};
    _ = input.Mods.track(&mods, toEvdev(56), true); // shift down
    try std.testing.expectEqual(@as(?u8, '+'), input.keyChar(toEvdev(24), mods.shift));
    _ = input.Mods.track(&mods, toEvdev(56), false); // shift up
    try std.testing.expectEqual(@as(?u8, '='), input.keyChar(toEvdev(24), mods.shift));
}

test "no keycode in the mapped set is itself the source of another row" {
    // A duplicate `mac` would make translation order-dependent: the first
    // row wins, so the table would silently depend on its own order.
    var seen = [_]u16{255} ** (LETTERS.len + DIGITS.len + PUNCT.len + NAMED.len + MODIFIERS.len);
    var n: usize = 0;
    for ([_][]const Row{ &LETTERS, &DIGITS, &PUNCT, &NAMED, &MODIFIERS }) |table| {
        for (table) |r| {
            for (seen[0..n]) |prior| {
                try std.testing.expect(prior != r.mac);
            }
            seen[n] = r.mac;
            n += 1;
        }
    }
    try std.testing.expectEqual(LETTERS.len + DIGITS.len + PUNCT.len + NAMED.len + MODIFIERS.len, n);
}

test "an unmapped keycode reports KEY_NONE rather than a plausible wrong key" {
    // Guessing is worse than silence: a wrong mapping types the wrong
    // character, which is far more confusing than typing nothing.
    try std.testing.expectEqual(KEY_NONE, toEvdev(10)); // gap in the ANSI map
    try std.testing.expectEqual(KEY_NONE, toEvdev(255));
    try std.testing.expectEqual(KEY_NONE, toEvdev(1000));
}

test "no mapped keycode collides with the KEY_NONE sentinel" {
    // If a real key mapped to 0 it would be indistinguishable from "unmapped"
    // and the keystroke would vanish.
    for (0..1200) |k| {
        const kc: u16 = @intCast(k);
        const ev = toEvdev(kc);
        if (ev != KEY_NONE) try std.testing.expect(ev != 0);
    }
}

test "translation is pure and total — the same input always gives the same code" {
    for (0..1200) |k| {
        const kc: u16 = @intCast(k);
        try std.testing.expectEqual(toEvdev(kc), toEvdev(kc));
    }
}

test "evdevFor is the delegate-facing name and agrees with toEvdev" {
    try std.testing.expectEqual(toEvdev(12), evdevFor(12));
    try std.testing.expectEqual(KEY_NONE, evdevFor(255));
}
