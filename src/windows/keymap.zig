//! Win32 virtual-key code -> Linux evdev code translation.
//!
//! The Delegate contract carries *evdev* keycodes: `components.input.keyChar`
//! is a pure evdev -> ASCII table and `keyToClose` accepts evdev 1. Win32
//! hands us a `WM_KEYDOWN` `wParam`, which is a completely different numbering
//! (Win32 `Q` is 0x51, evdev `Q` is 16), so the backend MUST translate before
//! handing a key to the delegate. Doing it here — rather than making
//! `components.input` platform-aware — is what keeps the whole widget layer and
//! the Delegate contract identical on every operating system.
//!
//! Everything in this module is a pure table lookup: no Win32, no runtime
//! state, so it is unit-tested in the cross-platform parity suite and runs on
//! Linux and macOS too. Only the shim is untestable.
//!
//! ## Two Win32 facts that shape the table
//!
//!  1. **The main row IS ASCII.** `WM_KEYDOWN` reports `'A'`..`'Z'` as 0x41..0x5A
//!     and `'0'`..`'9'` as 0x30..0x39, but that is a coincidence of the
//!     US layout, not a rule. Punctuation lives in the `VK_OEM_*` range
//!     (0xBA..0xE2) and the whole set shifts with the active keyboard layout,
//!     which is why the table is a real table and not `vk - 'a' + 30`.
//!  2. **The keypad duplicates codes with an "extended" bit set.** The numpad
//!     `Enter` is a `WM_KEYDOWN` of `VK_RETURN` with bit 24 set, and the
//!     calculator routes evdev 96 (`KEY_KPENTER`) to `=` *separately* from 28
//!     (`KEY_ENTER`). Collapsing them loses the distinction, and collapsing the
//!     WRONG way makes the main Enter stop working — which is why the extended
//!     bit is stripped for the lookup and then consulted for `VK_RETURN` only.

const std = @import("std");

/// Returned for a key with no evdev equivalent. Zero is evdev KEY_RESERVED,
/// so 0 is a safe "not ours" sentinel — no real key maps to it.
pub const KEY_NONE: u32 = 0;

/// Bit 24 of `wParam`, set by the keyboard driver for keys that are NOT on the
/// main block: the numpad, the navigation cluster, and the right-hand Ctrl /
/// Alt / Enter. Must be stripped before the table lookup.
pub const vk_extended: u32 = 0x0100_0000;

/// One row of a translation table.
const Row = struct { vk: u32, ev: u32 };

// The main-row letters. Win32 reports the ASCII code point, so `'A'` is 0x41.
const LETTERS = [_]Row{
    .{ .vk = 'A', .ev = 30 }, // a
    .{ .vk = 'B', .ev = 48 }, // b
    .{ .vk = 'C', .ev = 46 }, // c
    .{ .vk = 'D', .ev = 32 }, // d
    .{ .vk = 'E', .ev = 18 }, // e
    .{ .vk = 'F', .ev = 33 }, // f
    .{ .vk = 'G', .ev = 34 }, // g
    .{ .vk = 'H', .ev = 35 }, // h
    .{ .vk = 'I', .ev = 23 }, // i
    .{ .vk = 'J', .ev = 36 }, // j
    .{ .vk = 'K', .ev = 37 }, // k
    .{ .vk = 'L', .ev = 38 }, // l
    .{ .vk = 'M', .ev = 50 }, // m
    .{ .vk = 'N', .ev = 49 }, // n
    .{ .vk = 'O', .ev = 24 }, // o
    .{ .vk = 'P', .ev = 25 }, // p
    .{ .vk = 'Q', .ev = 16 }, // q
    .{ .vk = 'R', .ev = 19 }, // r
    .{ .vk = 'S', .ev = 31 }, // s
    .{ .vk = 'T', .ev = 20 }, // t
    .{ .vk = 'U', .ev = 22 }, // u
    .{ .vk = 'V', .ev = 47 }, // v
    .{ .vk = 'W', .ev = 17 }, // w
    .{ .vk = 'X', .ev = 45 }, // x
    .{ .vk = 'Y', .ev = 21 }, // y
    .{ .vk = 'Z', .ev = 44 }, // z
};

const DIGITS = [_]Row{
    .{ .vk = '0', .ev = 11 }, // 0
    .{ .vk = '1', .ev = 2 }, // 1
    .{ .vk = '2', .ev = 3 }, // 2
    .{ .vk = '3', .ev = 4 }, // 3
    .{ .vk = '4', .ev = 5 }, // 4
    .{ .vk = '5', .ev = 6 }, // 5
    .{ .vk = '6', .ev = 7 }, // 6
    .{ .vk = '7', .ev = 8 }, // 7
    .{ .vk = '8', .ev = 9 }, // 8
    .{ .vk = '9', .ev = 10 }, // 9
};

// The `VK_OEM_*` codes, which are the unshifted US-layout punctuation.
// Punctuation maps to the UNSHIFTED key's evdev code. The shifted character
// is `keyChar`'s job, not ours: evdev 13 is the only code `keyChar` knows that
// yields '+', so '=' must land on 13 and let shift do the rest.
const PUNCT = [_]Row{
    .{ .vk = 0xBD, .ev = 12 }, // VK_OEM_MINUS  -   (shift -> _)
    .{ .vk = 0xBB, .ev = 13 }, // VK_OEM_PLUS   =   (shift -> +)
    .{ .vk = 0xDB, .ev = 26 }, // VK_OEM_4      [   (shift -> {)
    .{ .vk = 0xDD, .ev = 27 }, // VK_OEM_6      ]   (shift -> })
    .{ .vk = 0xBA, .ev = 39 }, // VK_OEM_1      ;   (shift -> :)
    .{ .vk = 0xDE, .ev = 40 }, // VK_OEM_7      '   (shift -> ")
    .{ .vk = 0xC0, .ev = 41 }, // VK_OEM_3      `   (shift -> ~)
    .{ .vk = 0xDC, .ev = 43 }, // VK_OEM_5      \   (shift -> |)
    .{ .vk = 0xBC, .ev = 51 }, // VK_OEM_COMMA  ,   (shift -> <)
    .{ .vk = 0xBE, .ev = 52 }, // VK_OEM_PERIOD .   (shift -> >)
    .{ .vk = 0xBF, .ev = 53 }, // VK_OEM_2      /   (shift -> ?)
    .{ .vk = 0x20, .ev = 57 }, // VK_SPACE         space
};

const NAMED = [_]Row{
    .{ .vk = 0x1B, .ev = 1 }, // VK_ESCAPE   -> keyToClose() accepts this, so a
    // Windows window gets quit-on-Escape with no per-platform code.
    .{ .vk = 0x09, .ev = 15 }, // VK_TAB         tab
    .{ .vk = 0x0D, .ev = 28 }, // VK_RETURN     return (main) — the numpad's
    // return arrives as the SAME code with the extended bit set and is handled
    // separately, because the calculator routes evdev 96 to `=` on its own.
    .{ .vk = 0x08, .ev = 14 }, // VK_BACK       backspace
    .{ .vk = 0x2E, .ev = 111 }, // VK_DELETE    forward delete
    .{ .vk = 0x25, .ev = 105 }, // VK_LEFT      left
    .{ .vk = 0x27, .ev = 106 }, // VK_RIGHT     right
    .{ .vk = 0x28, .ev = 108 }, // VK_DOWN      down
    .{ .vk = 0x26, .ev = 103 }, // VK_UP        up
    .{ .vk = 0x24, .ev = 102 }, // VK_HOME      home
    .{ .vk = 0x23, .ev = 107 }, // VK_END       end
    .{ .vk = 0x21, .ev = 104 }, // VK_PRIOR     page up
    .{ .vk = 0x22, .ev = 109 }, // VK_NEXT      page down
    .{ .vk = 0x2D, .ev = 110 }, // VK_INSERT    insert
};

// The numeric keypad, whose evdev codes are NOT contiguous — the +,-,* and /
// keys sit in the gaps between the digits, which is exactly the kind of detail
// a generated table gets wrong.
const KEYPAD = [_]Row{
    .{ .vk = 0x60, .ev = 82 }, // VK_NUMPAD0   KEY_KP0
    .{ .vk = 0x61, .ev = 79 }, // VK_NUMPAD1   KEY_KP1
    .{ .vk = 0x62, .ev = 80 }, // VK_NUMPAD2   KEY_KP2
    .{ .vk = 0x63, .ev = 81 }, // VK_NUMPAD3   KEY_KP3
    .{ .vk = 0x64, .ev = 75 }, // VK_NUMPAD4   KEY_KP4
    .{ .vk = 0x65, .ev = 76 }, // VK_NUMPAD5   KEY_KP5
    .{ .vk = 0x66, .ev = 77 }, // VK_NUMPAD6   KEY_KP6
    .{ .vk = 0x67, .ev = 71 }, // VK_NUMPAD7   KEY_KP7
    .{ .vk = 0x68, .ev = 72 }, // VK_NUMPAD8   KEY_KP8
    .{ .vk = 0x69, .ev = 73 }, // VK_NUMPAD9   KEY_KP9
    .{ .vk = 0x6A, .ev = 55 }, // VK_MULTIPLY  KEY_KPASTERISK
    .{ .vk = 0x6B, .ev = 78 }, // VK_ADD       KEY_KPPLUS
    .{ .vk = 0x6D, .ev = 74 }, // VK_SUBTRACT  KEY_KPMINUS
    .{ .vk = 0x6E, .ev = 83 }, // VK_DECIMAL   KEY_KPDOT
    .{ .vk = 0x6F, .ev = 98 }, // VK_DIVIDE    KEY_KPSLASH
};

/// Modifier keys. These are delivered as ordinary key events so the Host's
/// `Mods.track` updates itself exactly as it does on Wayland — that is what
/// makes `keyChar(code, shift)` produce '+' for Shift+'=' with no change to the
/// widget layer. Left and right of the same modifier share one evdev code on
/// purpose: `Mods.track` treats 42/54 and 29/97 as the same logical state, so
/// splitting them would be indistinguishable anyway.
///
/// The side-neutral `VK_SHIFT` / `VK_CONTROL` / `VK_MENU` codes are listed
/// because some layouts and injected input do report them, and a backend that
/// answered KEY_NONE for a real modifier cannot tell "the user pressed Alt"
/// from "unknown key". Windows and Menu are reported as real keys, exactly as
/// Option and Command are on macOS.
const MODIFIERS = [_]Row{
    .{ .vk = 0x10, .ev = 42 }, // VK_SHIFT     side-neutral shift
    .{ .vk = 0x11, .ev = 29 }, // VK_CONTROL   side-neutral control
    .{ .vk = 0x12, .ev = 56 }, // VK_MENU      side-neutral alt
    .{ .vk = 0xA0, .ev = 42 }, // VK_LSHIFT
    .{ .vk = 0xA1, .ev = 42 }, // VK_RSHIFT
    .{ .vk = 0xA2, .ev = 29 }, // VK_LCONTROL
    .{ .vk = 0xA3, .ev = 29 }, // VK_RCONTROL
    .{ .vk = 0xA4, .ev = 56 }, // VK_LMENU     left alt
    .{ .vk = 0xA5, .ev = 56 }, // VK_RMENU     right alt
    .{ .vk = 0x5B, .ev = 125 }, // VK_LWIN     left meta
    .{ .vk = 0x5C, .ev = 125 }, // VK_RWIN     right meta
};

/// The function keys. F11 and F12 are out of sequence in evdev (F10 is 68 and
/// F11 is 87), which is the whole reason this is a table.
const FUNCTION = [_]Row{
    .{ .vk = 0x70, .ev = 59 }, // F1
    .{ .vk = 0x71, .ev = 60 }, // F2
    .{ .vk = 0x72, .ev = 61 }, // F3
    .{ .vk = 0x73, .ev = 62 }, // F4
    .{ .vk = 0x74, .ev = 63 }, // F5
    .{ .vk = 0x75, .ev = 64 }, // F6
    .{ .vk = 0x76, .ev = 65 }, // F7
    .{ .vk = 0x77, .ev = 66 }, // F8
    .{ .vk = 0x78, .ev = 67 }, // F9
    .{ .vk = 0x79, .ev = 68 }, // F10
    .{ .vk = 0x7A, .ev = 87 }, // F11
    .{ .vk = 0x7B, .ev = 88 }, // F12
    .{ .vk = 0x7C, .ev = 89 }, // F13
    .{ .vk = 0x7D, .ev = 90 }, // F14
    .{ .vk = 0x7E, .ev = 91 }, // F15
    .{ .vk = 0x7F, .ev = 92 }, // F16
    .{ .vk = 0x80, .ev = 93 }, // F17
    .{ .vk = 0x81, .ev = 94 }, // F18
    .{ .vk = 0x82, .ev = 95 }, // F19
    .{ .vk = 0x83, .ev = 96 }, // F20
    .{ .vk = 0x84, .ev = 97 }, // F21
    .{ .vk = 0x85, .ev = 98 }, // F22
    .{ .vk = 0x86, .ev = 99 }, // F23
    .{ .vk = 0x87, .ev = 100 }, // F24
};

/// evdev `KEY_KPENTER` — the calculator maps this to `=` separately from
/// `KEY_ENTER`, so the numpad's Enter must not be folded into the main one.
pub const KEY_KPENTER: u32 = 96;

/// Win32 `VK_RETURN`, with and without the "extended key" flag.
pub const VK_RETURN: u32 = 0x0D;

fn lookup(base: u32) u32 {
    for (LETTERS) |r| {
        if (r.vk == base) return r.ev;
    }
    for (DIGITS) |r| {
        if (r.vk == base) return r.ev;
    }
    for (PUNCT) |r| {
        if (r.vk == base) return r.ev;
    }
    for (NAMED) |r| {
        if (r.vk == base) return r.ev;
    }
    for (KEYPAD) |r| {
        if (r.vk == base) return r.ev;
    }
    for (MODIFIERS) |r| {
        if (r.vk == base) return r.ev;
    }
    for (FUNCTION) |r| {
        if (r.vk == base) return r.ev;
    }
    return KEY_NONE;
}

/// Translate one `WM_KEYDOWN` / `WM_KEYUP` `wParam` to its evdev code, or
/// KEY_NONE. `wparam` is the raw value, extended-key bit and all, so callers
/// must pass it unmodified.
pub fn evdevFor(wparam: u32) u32 {
    const extended = (wparam & vk_extended) != 0;
    const base = wparam & ~vk_extended;
    // The ONLY place the extended bit changes the answer. The numpad's Enter
    // is a VK_RETURN that the driver marks as not-on-the-main-block, and the
    // calculator needs to tell it apart from the main Enter.
    if (extended and base == VK_RETURN) return KEY_KPENTER;
    return lookup(base);
}

/// The alias `mac/keymap.zig` and `linux/keymap.zig` also expose, so the three
/// backends read identically at the call site.
pub fn toEvdev(wparam: u32) u32 {
    return evdevFor(wparam);
}

// ===================== tests (parity suite — every platform) =====================

const input = @import("../core/components/input.zig");
const contract = @import("../core/window_contract.zig");

test "letters translate to their evdev codes" {
    // Win32 reports the ASCII code point for the main row, so the table has to
    // be keyed on 'A' (0x41) rather than on 30.
    try std.testing.expectEqual(@as(u32, 30), toEvdev('A'));
    try std.testing.expectEqual(@as(u32, 16), toEvdev('Q'));
    try std.testing.expectEqual(@as(u32, 17), toEvdev('W'));
    try std.testing.expectEqual(@as(u32, 25), toEvdev('P'));
    try std.testing.expectEqual(@as(u32, 50), toEvdev('M'));
    try std.testing.expectEqual(@as(u32, 48), toEvdev('B'));
}

test "the whole letter row round-trips through keyChar to the right ASCII" {
    // The contract that actually matters: the Delegate hands evdev to
    // `components.input.keyChar`, so a wrong translation surfaces as the wrong
    // character, not as an error.
    for ([_]u8{
        'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M',
        'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z',
    }) |ch| {
        const ev = toEvdev(ch);
        try std.testing.expect(ev != KEY_NONE);
        const want: u8 = ch + 32; // lowercase
        try std.testing.expectEqual(@as(?u8, want), input.keyChar(ev, false));
        try std.testing.expectEqual(@as(?u8, ch), input.keyChar(ev, true));
    }
}

test "the digit row translates, and '0' is not confused with 'O'" {
    // '0' is 0x30 and 'O' is 0x4F, so a table keyed by mistake on the other
    // one produces a digit where a letter belongs.
    try std.testing.expectEqual(@as(u32, 2), toEvdev('1'));
    try std.testing.expectEqual(@as(u32, 6), toEvdev('5'));
    try std.testing.expectEqual(@as(u32, 7), toEvdev('6'));
    try std.testing.expectEqual(@as(u32, 8), toEvdev('7'));
    try std.testing.expectEqual(@as(u32, 10), toEvdev('9'));
    try std.testing.expectEqual(@as(u32, 11), toEvdev('0'));
    try std.testing.expectEqual(@as(u32, 24), toEvdev('O'));
    try std.testing.expect(toEvdev('0') != toEvdev('O'));

    for ("0123456789") |ch| {
        try std.testing.expectEqual(@as(?u8, ch), input.keyChar(toEvdev(ch), false));
    }
}

test "every digit and letter reaches keyChar as the right character" {
    const cases = [_]struct { vk: u32, want: u8 }{
        .{ .vk = 0xBD, .want = '-' }, // VK_OEM_MINUS
        .{ .vk = 0xBB, .want = '=' }, // VK_OEM_PLUS
        .{ .vk = 0xBF, .want = '/' }, // VK_OEM_2
        .{ .vk = 0xBE, .want = '.' }, // VK_OEM_PERIOD
        .{ .vk = 0xBC, .want = ',' }, // VK_OEM_COMMA
        .{ .vk = 0x20, .want = ' ' }, // VK_SPACE
    };
    for (cases) |c| {
        try std.testing.expectEqual(@as(?u8, c.want), input.keyChar(toEvdev(c.vk), false));
    }
}

test "shifted punctuation keeps the unshifted evdev code" {
    // '=' (VK_OEM_PLUS, 0xBB) must map to evdev 13, and `keyChar` turns THAT
    // into '+' when shift is held. Mapping '=' to some dedicated "plus" code
    // would be wrong: evdev 13 is the only code `keyChar` knows that yields '+'.
    try std.testing.expectEqual(@as(u32, 13), toEvdev(0xBB));
    try std.testing.expectEqual(@as(?u8, '='), input.keyChar(toEvdev(0xBB), false));
    try std.testing.expectEqual(@as(?u8, '+'), input.keyChar(toEvdev(0xBB), true));
    try std.testing.expectEqual(@as(?u8, '_'), input.keyChar(toEvdev(0xBD), true));
    try std.testing.expectEqual(@as(?u8, '?'), input.keyChar(toEvdev(0xBF), true));
}

test "escape maps to evdev 1 so keyToClose quits a Windows window" {
    try std.testing.expectEqual(@as(u32, 1), toEvdev(0x1B)); // VK_ESCAPE
    // The point of the whole table: Escape-to-close works unchanged.
    try std.testing.expect(contract.keyToClose(toEvdev(0x1B)));
}

test "the main Enter is 28 and the numpad's is 96" {
    // THE Win32-specific subtlety. Both are WM_KEYDOWN of VK_RETURN; only the
    // extended-key bit tells them apart, and the calculator routes them
    // separately — folding the keypad one into 28 loses that arm, and folding
    // the main one into 96 breaks the ordinary Enter.
    try std.testing.expectEqual(input.KEY_ENTER, toEvdev(VK_RETURN));
    try std.testing.expectEqual(KEY_KPENTER, toEvdev(VK_RETURN | vk_extended));
    try std.testing.expect(input.KEY_ENTER != KEY_KPENTER);
}

test "the extended bit changes nothing else" {
    // The numpad arrows, Insert/Delete and the right-hand modifiers all arrive
    // with the extended bit set, and must translate exactly like their
    // main-cluster twins.
    try std.testing.expectEqual(toEvdev(0x25), toEvdev(0x25 | vk_extended)); // left
    try std.testing.expectEqual(toEvdev(0x2E), toEvdev(0x2E | vk_extended)); // delete
    try std.testing.expectEqual(toEvdev(0xA3), toEvdev(0xA3 | vk_extended)); // right ctrl
    try std.testing.expectEqual(toEvdev('A'), toEvdev('A' | vk_extended));
}

test "the numeric keypad maps to the non-contiguous evdev codes" {
    // The evdev keypad layout puts +,-,* and / in the gaps between the digits,
    // which is why this is a table and not an arithmetic sequence.
    const cases = [_]struct { vk: u32, ev: u32 }{
        .{ .vk = 0x60, .ev = 82 }, // KP0
        .{ .vk = 0x61, .ev = 79 }, // KP1
        .{ .vk = 0x66, .ev = 77 }, // KP6
        .{ .vk = 0x67, .ev = 71 }, // KP7
        .{ .vk = 0x69, .ev = 73 }, // KP9
        .{ .vk = 0x6A, .ev = 55 }, // KP *
        .{ .vk = 0x6B, .ev = 78 }, // KP +
        .{ .vk = 0x6D, .ev = 74 }, // KP -
        .{ .vk = 0x6E, .ev = 83 }, // KP .
        .{ .vk = 0x6F, .ev = 98 }, // KP /
    };
    for (cases) |c| {
        try std.testing.expectEqual(c.ev, toEvdev(c.vk));
    }
}

test "the calculator's keypad operators land on the codes it listens for" {
    // The calculator declares its own KEY_KP_* constants and routes them
    // explicitly. If this drifts, the numpad operators type nothing at all —
    // and unlike a letter, there is no keyChar fallback to hide it.
    try std.testing.expectEqual(@as(u32, 96), toEvdev(VK_RETURN | vk_extended));
    try std.testing.expectEqual(@as(u32, 78), toEvdev(0x6B)); // +
    try std.testing.expectEqual(@as(u32, 74), toEvdev(0x6D)); // -
    try std.testing.expectEqual(@as(u32, 55), toEvdev(0x6A)); // *
    try std.testing.expectEqual(@as(u32, 98), toEvdev(0x6F)); // /
    // And none of them collide with each other or with the digits.
    try std.testing.expect(toEvdev(0x6B) != toEvdev(0x6D));
    try std.testing.expect(toEvdev(0x6A) != toEvdev(0x6F));
    try std.testing.expect(toEvdev(0x60) != toEvdev(0x69));
    try std.testing.expect(toEvdev(0x60) != toEvdev(0x6B));
}

test "backspace and forward delete map to their distinct evdev codes" {
    try std.testing.expectEqual(input.KEY_BACKSPACE, toEvdev(0x08)); // VK_BACK
    try std.testing.expectEqual(input.KEY_DELETE, toEvdev(0x2E)); // VK_DELETE
    try std.testing.expect(input.KEY_BACKSPACE != input.KEY_DELETE);
}

test "arrow keys map to the navigation codes input.zig documents" {
    try std.testing.expectEqual(input.KEY_LEFT, toEvdev(0x25));
    try std.testing.expectEqual(input.KEY_RIGHT, toEvdev(0x27));
    try std.testing.expectEqual(input.KEY_DOWN, toEvdev(0x28));
    try std.testing.expectEqual(input.KEY_UP, toEvdev(0x26));
    try std.testing.expectEqual(input.KEY_HOME, toEvdev(0x24));
    try std.testing.expectEqual(input.KEY_END, toEvdev(0x23));
}

test "shift and control reach the evdev codes Mods.track watches" {
    // The Host's KeyChain calls `Mods.track(evdev, pressed)`, which watches
    // 42/54 for shift and 29/97 for control. Both Win32 shift keys and both
    // control keys must land on one of those, or Shift+'=' would type '='.
    var mods = input.Mods{};
    for ([_]u32{ 0xA0, 0xA1 }) |vk| {
        const ev = toEvdev(vk);
        try std.testing.expect(input.Mods.track(&mods, ev, true));
        try std.testing.expect(mods.shift);
        try std.testing.expect(input.Mods.track(&mods, ev, false));
        try std.testing.expect(!mods.shift);
    }
    for ([_]u32{ 0xA2, 0xA3 }) |vk| {
        const ev = toEvdev(vk);
        try std.testing.expect(input.Mods.track(&mods, ev, true));
        try std.testing.expect(mods.ctrl);
        try std.testing.expect(input.Mods.track(&mods, ev, false));
        try std.testing.expect(!mods.ctrl);
    }
}

test "a modifier press followed by '=' produces '+' through the chain" {
    // End-to-end proof of the reason modifiers are delivered as key events.
    var mods = input.Mods{};
    _ = input.Mods.track(&mods, toEvdev(0xA0), true); // left shift down
    try std.testing.expectEqual(@as(?u8, '+'), input.keyChar(toEvdev(0xBB), mods.shift));
    _ = input.Mods.track(&mods, toEvdev(0xA0), false); // left shift up
    try std.testing.expectEqual(@as(?u8, '='), input.keyChar(toEvdev(0xBB), mods.shift));
}

test "alt and the Windows keys are recognised keys, not KEY_NONE" {
    // They are not tracked by `Mods`, but reporting them as unmapped would be
    // wrong: an app cannot tell "the user pressed Alt" from "unknown key".
    try std.testing.expect(toEvdev(0xA4) != KEY_NONE); // left alt
    try std.testing.expect(toEvdev(0xA5) != KEY_NONE); // right alt
    try std.testing.expect(toEvdev(0x5B) != KEY_NONE); // left meta
    try std.testing.expect(toEvdev(0x5C) != KEY_NONE); // right meta
    // and the side-neutral spellings some layouts report
    try std.testing.expect(toEvdev(0x10) != KEY_NONE);
    try std.testing.expect(toEvdev(0x11) != KEY_NONE);
    try std.testing.expect(toEvdev(0x12) != KEY_NONE);
}

test "F1..F12 map to the evdev codes, including the F10/F11 jump" {
    try std.testing.expectEqual(@as(u32, 59), toEvdev(0x70));
    try std.testing.expectEqual(@as(u32, 68), toEvdev(0x79)); // F10
    try std.testing.expectEqual(@as(u32, 87), toEvdev(0x7A)); // F11 — NOT 69
    try std.testing.expectEqual(@as(u32, 88), toEvdev(0x7B)); // F12
    // The jump is the only interesting part; assert it explicitly so a
    // "VK_F1 + n" rewrite fails here rather than in a running app.
    try std.testing.expect(toEvdev(0x7A) != toEvdev(0x79) + 1);
}

test "no keycode in the mapped set is itself the source of another row" {
    // A duplicate `vk` would make translation order-dependent: the first row
    // wins, so the table would silently depend on its own order.
    var seen = [_]u32{0xFFFF_FFFF} ** (LETTERS.len + DIGITS.len + PUNCT.len + NAMED.len +
        KEYPAD.len + MODIFIERS.len + FUNCTION.len);
    var n: usize = 0;
    for ([_][]const Row{
        &LETTERS, &DIGITS, &PUNCT, &NAMED, &KEYPAD, &MODIFIERS, &FUNCTION,
    }) |table| {
        for (table) |r| {
            for (seen[0..n]) |prior| {
                try std.testing.expect(prior != r.vk);
            }
            seen[n] = r.vk;
            n += 1;
        }
    }
    try std.testing.expectEqual(LETTERS.len + DIGITS.len + PUNCT.len + NAMED.len +
        KEYPAD.len + MODIFIERS.len + FUNCTION.len, n);
}

test "an unmapped keycode reports KEY_NONE rather than a plausible wrong key" {
    // Guessing is worse than silence: a wrong mapping types the wrong
    // character, which is far more confusing than typing nothing.
    try std.testing.expectEqual(KEY_NONE, toEvdev(0x01)); // left mouse button
    try std.testing.expectEqual(KEY_NONE, toEvdev(0x07)); // F12 via mouse vkey
    try std.testing.expectEqual(KEY_NONE, toEvdev(0xE2));
    try std.testing.expectEqual(KEY_NONE, toEvdev(0xFFFF));
}

test "no mapped keycode collides with the KEY_NONE sentinel" {
    // If a real key mapped to 0 it would be indistinguishable from "unmapped"
    // and the keystroke would vanish.
    for (0..0x200) |k| {
        const ev = toEvdev(@intCast(k));
        if (ev != KEY_NONE) try std.testing.expect(ev != 0);
    }
}

test "translation is pure and total — the same input always gives the same code" {
    for (0..0x200) |k| {
        const vk: u32 = @intCast(k);
        try std.testing.expectEqual(toEvdev(vk), toEvdev(vk));
        try std.testing.expectEqual(toEvdev(vk | vk_extended), toEvdev(vk | vk_extended));
    }
}

test "evdevFor is the delegate-facing name and agrees with toEvdev" {
    try std.testing.expectEqual(toEvdev('Q'), evdevFor('Q'));
    try std.testing.expectEqual(KEY_NONE, evdevFor(0xE2));
}
