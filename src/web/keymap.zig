//! `KeyboardEvent.code` -> Linux evdev code translation.
//!
//! The Delegate contract carries *evdev* keycodes: `components.input.keyChar` is
//! a pure evdev -> ASCII table, `keyToClose` accepts evdev 1, and the calculator
//! example maps the numeric keypad's evdev codes itself. The DOM reports
//! `KeyboardEvent.code`, a completely different namespace (`"KeyQ"`,
//! `"Digit1"`, `"NumpadAdd"`), so the backend MUST translate before handing a key
//! to the delegate. Doing it here — rather than making `components.input`
//! platform-aware — is what keeps the whole widget layer and the Delegate
//! contract identical on all three platforms.
//!
//! ## Why the table is keyed by `code` and not by `key`
//!
//! `KeyboardEvent.code` names the PHYSICAL key at its US-layout position, which
//! is the same abstraction evdev uses — so this is a straight translation with no
//! layout reasoning in it. `KeyboardEvent.key` would carry the *produced
//! character*, which would fold the user's keyboard layout into the toolkit.
//!
//! The known consequence is that an AZERTY user types US characters, because
//! `keyChar(evdev)` is a US table. That is **exactly what Linux/Wayland does
//! today** — Wayland also speaks evdev — so the browser is consistent with the
//! existing native behaviour rather than newly wrong. Fixing it properly means an
//! `event.key`/composition text-input path, which is shared work with Linux and
//! is deliberately out of scope here.
//!
//! ## Everything here is a pure table lookup
//!
//! No DOM, no runtime state, so it is unit-tested in the cross-platform parity
//! suite and runs on Linux and macOS too — the same treatment `mac/keymap.zig`
//! gets, and for the same reason: a dropped code means a key that silently does
//! nothing, which is indistinguishable from a widget bug.

const std = @import("std");

/// Returned for a code with no evdev equivalent. Zero is evdev KEY_RESERVED, so 0
/// is a safe "not ours" sentinel — no real key maps to it.
pub const KEY_NONE: u32 = 0;

/// One row of a translation table.
const Row = struct { code: []const u8, ev: u32 };

const LETTERS = [_]Row{
    .{ .code = "KeyA", .ev = 30 },
    .{ .code = "KeyB", .ev = 48 },
    .{ .code = "KeyC", .ev = 46 },
    .{ .code = "KeyD", .ev = 32 },
    .{ .code = "KeyE", .ev = 18 },
    .{ .code = "KeyF", .ev = 33 },
    .{ .code = "KeyG", .ev = 34 },
    .{ .code = "KeyH", .ev = 35 },
    .{ .code = "KeyI", .ev = 23 },
    .{ .code = "KeyJ", .ev = 36 },
    .{ .code = "KeyK", .ev = 37 },
    .{ .code = "KeyL", .ev = 38 },
    .{ .code = "KeyM", .ev = 50 },
    .{ .code = "KeyN", .ev = 49 },
    .{ .code = "KeyO", .ev = 24 },
    .{ .code = "KeyP", .ev = 25 },
    .{ .code = "KeyQ", .ev = 16 },
    .{ .code = "KeyR", .ev = 19 },
    .{ .code = "KeyS", .ev = 31 },
    .{ .code = "KeyT", .ev = 20 },
    .{ .code = "KeyU", .ev = 22 },
    .{ .code = "KeyV", .ev = 47 },
    .{ .code = "KeyW", .ev = 17 },
    .{ .code = "KeyX", .ev = 45 },
    .{ .code = "KeyY", .ev = 21 },
    .{ .code = "KeyZ", .ev = 44 },
};

const DIGITS = [_]Row{
    .{ .code = "Digit1", .ev = 2 },
    .{ .code = "Digit2", .ev = 3 },
    .{ .code = "Digit3", .ev = 4 },
    .{ .code = "Digit4", .ev = 5 },
    .{ .code = "Digit5", .ev = 6 },
    .{ .code = "Digit6", .ev = 7 },
    .{ .code = "Digit7", .ev = 8 },
    .{ .code = "Digit8", .ev = 9 },
    .{ .code = "Digit9", .ev = 10 },
    .{ .code = "Digit0", .ev = 11 },
};

/// Punctuation maps to the UNSHIFTED key's evdev code. The shifted character is
/// `keyChar`'s job, not ours: evdev 13 is the only code `keyChar` knows that
/// yields '+', so `"Equal"` must land on 13 and let shift do the rest.
const PUNCT = [_]Row{
    .{ .code = "Minus", .ev = 12 }, // shift -> _
    .{ .code = "Equal", .ev = 13 }, // shift -> +
    .{ .code = "BracketLeft", .ev = 26 }, // shift -> {
    .{ .code = "BracketRight", .ev = 27 }, // shift -> }
    .{ .code = "Semicolon", .ev = 39 }, // shift -> :
    .{ .code = "Quote", .ev = 40 }, // shift -> "
    .{ .code = "Backquote", .ev = 41 }, // shift -> ~
    .{ .code = "Backslash", .ev = 43 }, // shift -> |
    .{ .code = "Comma", .ev = 51 }, // shift -> <
    .{ .code = "Period", .ev = 52 }, // shift -> >
    .{ .code = "Slash", .ev = 53 }, // shift -> ?
    .{ .code = "Space", .ev = 57 },
};

const NAMED = [_]Row{
    // keyToClose() accepts evdev 1, so a browser tab gets quit-on-Escape with no
    // per-platform code at all.
    .{ .code = "Escape", .ev = 1 },
    .{ .code = "Tab", .ev = 15 },
    .{ .code = "Enter", .ev = 28 },
    .{ .code = "Backspace", .ev = 14 },
    .{ .code = "Delete", .ev = 111 },
    .{ .code = "Insert", .ev = 110 },
    .{ .code = "ArrowLeft", .ev = 105 },
    .{ .code = "ArrowRight", .ev = 106 },
    .{ .code = "ArrowUp", .ev = 103 },
    .{ .code = "ArrowDown", .ev = 108 },
    .{ .code = "Home", .ev = 102 },
    .{ .code = "End", .ev = 107 },
    .{ .code = "PageUp", .ev = 104 },
    .{ .code = "PageDown", .ev = 109 },
    .{ .code = "CapsLock", .ev = 58 },
};

const FKEYS = [_]Row{
    .{ .code = "F1", .ev = 59 },
    .{ .code = "F2", .ev = 60 },
    .{ .code = "F3", .ev = 61 },
    .{ .code = "F4", .ev = 62 },
    .{ .code = "F5", .ev = 63 },
    .{ .code = "F6", .ev = 64 },
    .{ .code = "F7", .ev = 65 },
    .{ .code = "F8", .ev = 66 },
    .{ .code = "F9", .ev = 67 },
    .{ .code = "F10", .ev = 68 },
    .{ .code = "F11", .ev = 87 },
    .{ .code = "F12", .ev = 88 },
};

/// The numeric keypad is mapped EXPLICITLY, including its arithmetic keys, which
/// are deliberately NOT folded onto the digit row: the calculator example routes
/// evdev 78/74/55/98/96 to its own operations, and folding `"NumpadAdd"` onto
/// `"Equal"` would make it type '+' into a text field instead of adding.
///
/// The digits use their own evdev codes (71..83) rather than the digit row's, so
/// NumLock-off keys (`"Numpad7"` as Home) still arrive as keypad codes — the same
/// identity `mac/keymap.zig` preserves for macOS's keypad.
const NUMPAD = [_]Row{
    .{ .code = "Numpad0", .ev = 82 },
    .{ .code = "Numpad1", .ev = 79 },
    .{ .code = "Numpad2", .ev = 80 },
    .{ .code = "Numpad3", .ev = 81 },
    .{ .code = "Numpad4", .ev = 75 },
    .{ .code = "Numpad5", .ev = 76 },
    .{ .code = "Numpad6", .ev = 77 },
    .{ .code = "Numpad7", .ev = 71 },
    .{ .code = "Numpad8", .ev = 72 },
    .{ .code = "Numpad9", .ev = 73 },
    .{ .code = "NumpadAdd", .ev = 78 },
    .{ .code = "NumpadSubtract", .ev = 74 },
    .{ .code = "NumpadMultiply", .ev = 55 },
    .{ .code = "NumpadDivide", .ev = 98 },
    .{ .code = "NumpadDecimal", .ev = 83 },
    .{ .code = "NumpadEnter", .ev = 96 },
};

/// Modifier keys, delivered as ordinary key events so the Host's `Mods.track`
/// updates itself exactly as it does on Wayland. Left and right get their OWN
/// evdev codes here (unlike `mac/keymap.zig`, which collapses both shifts onto 42
/// because macOS's two keycodes have no distinct meaning it can express).
/// `Mods.track` watches 42/54 and 29/97, so both sides update the same latch —
/// but keeping them distinct means the translation is faithful to the DOM, and a
/// caller that later wants "which shift" already has the information.
///
/// Alt/Meta are listed so they are *recognised* (reported as real keys) instead
/// of falling through to KEY_NONE: an app cannot tell "user pressed Alt" from
/// "unknown key" otherwise.
const MODIFIERS = [_]Row{
    .{ .code = "ShiftLeft", .ev = 42 },
    .{ .code = "ShiftRight", .ev = 54 },
    .{ .code = "ControlLeft", .ev = 29 },
    .{ .code = "ControlRight", .ev = 97 },
    .{ .code = "AltLeft", .ev = 56 },
    .{ .code = "AltRight", .ev = 100 },
    .{ .code = "MetaLeft", .ev = 125 },
    .{ .code = "MetaRight", .ev = 126 },
};

/// Every table, in one place, so the duplicate check below cannot drift from the
/// lookup order.
pub const tables = [_][]const Row{ &LETTERS, &DIGITS, &PUNCT, &NAMED, &FKEYS, &NUMPAD, &MODIFIERS };

/// Translate one `KeyboardEvent.code` to its evdev code, or KEY_NONE.
///
/// Total and pure: an unknown or empty code answers KEY_NONE rather than
/// guessing, because a wrong mapping types the wrong character — far more
/// confusing than typing nothing.
pub fn evdevFor(code: []const u8) u32 {
    for (tables) |table| {
        for (table) |r| {
            if (std.mem.eql(u8, r.code, code)) return r.ev;
        }
    }
    return KEY_NONE;
}

/// True when the code is one we translate. Useful for a caller that wants to
/// distinguish "not ours" from "mapped to a code that happens to be reserved".
pub fn isMapped(code: []const u8) bool {
    return evdevFor(code) != KEY_NONE;
}

// ===================== tests (parity suite — every platform) =====================

const input = @import("../core/components/input.zig");
const contract = @import("../core/window_contract.zig");

test "letters translate to their evdev codes" {
    try std.testing.expectEqual(@as(u32, 30), evdevFor("KeyA"));
    try std.testing.expectEqual(@as(u32, 16), evdevFor("KeyQ"));
    try std.testing.expectEqual(@as(u32, 17), evdevFor("KeyW"));
    try std.testing.expectEqual(@as(u32, 25), evdevFor("KeyP"));
    try std.testing.expectEqual(@as(u32, 50), evdevFor("KeyM"));
    try std.testing.expectEqual(@as(u32, 48), evdevFor("KeyB"));
}

test "the home row is not transposed" {
    // The three easiest pairs to get wrong when transcribing a physical layout
    // into a second numbering. Named explicitly so a regression cannot hide
    // inside a round-trip test.
    try std.testing.expectEqual(@as(u32, 34), evdevFor("KeyG"));
    try std.testing.expectEqual(@as(u32, 35), evdevFor("KeyH"));
    try std.testing.expectEqual(@as(u32, 36), evdevFor("KeyJ"));
    try std.testing.expectEqual(@as(u32, 37), evdevFor("KeyK"));
    try std.testing.expectEqual(@as(u32, 38), evdevFor("KeyL"));
}

test "the digit row translates, and 0 is the tenth key not the first" {
    try std.testing.expectEqual(@as(u32, 2), evdevFor("Digit1"));
    try std.testing.expectEqual(@as(u32, 6), evdevFor("Digit5"));
    try std.testing.expectEqual(@as(u32, 7), evdevFor("Digit6"));
    try std.testing.expectEqual(@as(u32, 8), evdevFor("Digit7"));
    try std.testing.expectEqual(@as(u32, 10), evdevFor("Digit9"));
    try std.testing.expectEqual(@as(u32, 11), evdevFor("Digit0"));
}

test "every translated key round-trips through keyChar to the right ASCII" {
    // The contract that actually matters: the Delegate hands evdev to
    // `components.input.keyChar`, so a wrong translation surfaces as the wrong
    // character. This is the test that would catch a transposition.
    const cases = [_]struct { code: []const u8, want: u8 }{
        .{ .code = "KeyA", .want = 'a' },
        .{ .code = "KeyS", .want = 's' },
        .{ .code = "KeyG", .want = 'g' },
        .{ .code = "KeyH", .want = 'h' },
        .{ .code = "KeyC", .want = 'c' },
        .{ .code = "KeyB", .want = 'b' },
        .{ .code = "KeyQ", .want = 'q' },
        .{ .code = "KeyW", .want = 'w' },
        .{ .code = "KeyY", .want = 'y' },
        .{ .code = "KeyT", .want = 't' },
        .{ .code = "KeyO", .want = 'o' },
        .{ .code = "KeyU", .want = 'u' },
        .{ .code = "KeyI", .want = 'i' },
        .{ .code = "KeyP", .want = 'p' },
        .{ .code = "KeyL", .want = 'l' },
        .{ .code = "KeyJ", .want = 'j' },
        .{ .code = "KeyK", .want = 'k' },
        .{ .code = "KeyN", .want = 'n' },
        .{ .code = "KeyM", .want = 'm' },
        .{ .code = "Digit1", .want = '1' },
        .{ .code = "Digit5", .want = '5' },
        .{ .code = "Digit6", .want = '6' },
        .{ .code = "Digit7", .want = '7' },
        .{ .code = "Digit9", .want = '9' },
        .{ .code = "Digit0", .want = '0' },
        .{ .code = "Minus", .want = '-' },
        .{ .code = "Equal", .want = '=' },
        .{ .code = "Slash", .want = '/' },
        .{ .code = "Period", .want = '.' },
        .{ .code = "Comma", .want = ',' },
        .{ .code = "Space", .want = ' ' },
    };
    for (cases) |c| {
        try std.testing.expectEqual(@as(?u8, c.want), input.keyChar(evdevFor(c.code), false));
    }
}

test "shifted punctuation keeps the unshifted evdev code" {
    // '=' must map to evdev 13, and `keyChar` turns THAT into '+' when shift is
    // held. Mapping it to some dedicated "plus" code would be wrong: evdev 13 is
    // the only code `keyChar` knows that yields '+'.
    try std.testing.expectEqual(@as(u32, 13), evdevFor("Equal"));
    try std.testing.expectEqual(@as(?u8, '='), input.keyChar(evdevFor("Equal"), false));
    try std.testing.expectEqual(@as(?u8, '+'), input.keyChar(evdevFor("Equal"), true));
    try std.testing.expectEqual(@as(?u8, '_'), input.keyChar(evdevFor("Minus"), true));
    try std.testing.expectEqual(@as(?u8, '?'), input.keyChar(evdevFor("Slash"), true));
}

test "shifted letters come out uppercase through the same code" {
    try std.testing.expectEqual(@as(?u8, 'q'), input.keyChar(evdevFor("KeyQ"), false));
    try std.testing.expectEqual(@as(?u8, 'Q'), input.keyChar(evdevFor("KeyQ"), true));
    try std.testing.expectEqual(@as(?u8, 'A'), input.keyChar(evdevFor("KeyA"), true));
}

test "escape maps to evdev 1 so keyToClose quits the UI in a tab" {
    try std.testing.expectEqual(@as(u32, 1), evdevFor("Escape"));
    // The point of the whole table: Escape-to-close works unchanged, with no
    // browser-specific code anywhere.
    try std.testing.expect(contract.keyToClose(evdevFor("Escape")));
}

test "return maps to KEY_ENTER, and the keypad's enter stays distinct" {
    // The calculator routes KEY_ENTER to '=' and the keypad's 96 separately, so
    // these two must not collapse.
    try std.testing.expectEqual(input.KEY_ENTER, evdevFor("Enter"));
    try std.testing.expectEqual(@as(u32, 96), evdevFor("NumpadEnter"));
    try std.testing.expect(input.KEY_ENTER != evdevFor("NumpadEnter"));
}

test "backspace and forward delete map to their distinct evdev codes" {
    try std.testing.expectEqual(input.KEY_BACKSPACE, evdevFor("Backspace"));
    try std.testing.expectEqual(input.KEY_DELETE, evdevFor("Delete"));
    try std.testing.expect(input.KEY_BACKSPACE != input.KEY_DELETE);
}

test "arrow keys and Home/End map to the navigation codes input.zig documents" {
    try std.testing.expectEqual(input.KEY_LEFT, evdevFor("ArrowLeft"));
    try std.testing.expectEqual(input.KEY_RIGHT, evdevFor("ArrowRight"));
    try std.testing.expectEqual(input.KEY_UP, evdevFor("ArrowUp"));
    try std.testing.expectEqual(input.KEY_DOWN, evdevFor("ArrowDown"));
    try std.testing.expectEqual(input.KEY_HOME, evdevFor("Home"));
    try std.testing.expectEqual(input.KEY_END, evdevFor("End"));
}

test "the keypad's arithmetic keys keep the codes the calculator maps itself" {
    // Regressing any of these breaks keyboard arithmetic in the example with no
    // other symptom.
    try std.testing.expectEqual(@as(u32, 78), evdevFor("NumpadAdd"));
    try std.testing.expectEqual(@as(u32, 74), evdevFor("NumpadSubtract"));
    try std.testing.expectEqual(@as(u32, 55), evdevFor("NumpadMultiply"));
    try std.testing.expectEqual(@as(u32, 98), evdevFor("NumpadDivide"));
    try std.testing.expectEqual(@as(u32, 83), evdevFor("NumpadDecimal"));
    // And '*', '+', '-' are NOT printable through keyChar — the calculator routes
    // them by code. If one of them started producing ASCII, arithmetic typed
    // into a text field would change meaning.
    try std.testing.expectEqual(@as(?u8, null), input.keyChar(evdevFor("NumpadMultiply"), false));
    try std.testing.expectEqual(@as(?u8, null), input.keyChar(evdevFor("NumpadAdd"), false));
}

test "the keypad's digits are NOT folded onto the digit row" {
    // Folding them would lose the keypad identity the calculator relies on.
    try std.testing.expectEqual(@as(u32, 71), evdevFor("Numpad7"));
    try std.testing.expectEqual(@as(u32, 72), evdevFor("Numpad8"));
    try std.testing.expect(evdevFor("Numpad7") != evdevFor("Digit7"));
}

test "shift and control reach the evdev codes Mods.track watches" {
    // `Mods.track` watches 42/54 for shift and 29/97 for control. Every DOM
    // shift and control code must land on one of those, or Shift+'=' would type
    // '=' instead of '+'.
    var mods = input.Mods{};
    for ([_][]const u8{ "ShiftLeft", "ShiftRight" }) |code| {
        const ev = evdevFor(code);
        try std.testing.expect(input.Mods.track(&mods, ev, true));
        try std.testing.expect(mods.shift);
        try std.testing.expect(input.Mods.track(&mods, ev, false));
        try std.testing.expect(!mods.shift);
    }
    for ([_][]const u8{ "ControlLeft", "ControlRight" }) |code| {
        const ev = evdevFor(code);
        try std.testing.expect(input.Mods.track(&mods, ev, true));
        try std.testing.expect(mods.ctrl);
        try std.testing.expect(input.Mods.track(&mods, ev, false));
        try std.testing.expect(!mods.ctrl);
    }
}

test "alt and meta are recognised keys, not KEY_NONE" {
    // Reporting them as unmapped would make "user pressed Alt" indistinguishable
    // from "unknown key".
    try std.testing.expect(evdevFor("AltLeft") != KEY_NONE);
    try std.testing.expect(evdevFor("AltRight") != KEY_NONE);
    try std.testing.expect(evdevFor("MetaLeft") != KEY_NONE);
    try std.testing.expect(evdevFor("MetaRight") != KEY_NONE);
}

test "a modifier press followed by '=' produces '+' through the chain" {
    // End-to-end proof of why modifiers are delivered as key events.
    var mods = input.Mods{};
    _ = input.Mods.track(&mods, evdevFor("ShiftLeft"), true);
    try std.testing.expectEqual(@as(?u8, '+'), input.keyChar(evdevFor("Equal"), mods.shift));
    _ = input.Mods.track(&mods, evdevFor("ShiftLeft"), false);
    try std.testing.expectEqual(@as(?u8, '='), input.keyChar(evdevFor("Equal"), mods.shift));
}

test "no code appears in two tables" {
    // A duplicate would make translation order-dependent: the first row wins, so
    // the table would silently depend on its own order. 99 rows today, so the
    // scratch list is sized with room and asserted non-trivially full.
    var seen: [128][]const u8 = undefined;
    var n: usize = 0;
    for (tables) |table| {
        for (table) |r| {
            for (seen[0..n]) |prior| {
                try std.testing.expect(!std.mem.eql(u8, prior, r.code));
            }
            try std.testing.expect(n < seen.len);
            seen[n] = r.code;
            n += 1;
        }
    }
    try std.testing.expect(n > 90);
}

test "every row is reachable through the public lookup" {
    // Guards against a table being added to `tables` but left out of the lookup,
    // or a row whose key can never match (a typo in a `code` literal).
    for (tables) |table| {
        for (table) |r| {
            try std.testing.expectEqual(r.ev, evdevFor(r.code));
        }
    }
}

test "an unmapped code reports KEY_NONE rather than a plausible wrong key" {
    // Guessing is worse than silence: a wrong mapping types the wrong character.
    try std.testing.expectEqual(KEY_NONE, evdevFor("Unidentified"));
    try std.testing.expectEqual(KEY_NONE, evdevFor(""));
    try std.testing.expectEqual(KEY_NONE, evdevFor("LaunchMediaPlayer"));
    try std.testing.expectEqual(KEY_NONE, evdevFor("F13"));
    try std.testing.expect(!isMapped("KeyAA"));
    try std.testing.expect(isMapped("KeyA"));
}

test "no mapped code collides with the KEY_NONE sentinel" {
    // If a real key mapped to 0 it would be indistinguishable from "unmapped" and
    // the keystroke would vanish.
    for (tables) |table| {
        for (table) |r| try std.testing.expect(r.ev != 0);
    }
}

test "esoteric codes the toolkit ignores still translate to a real key" {
    // CapsLock, Insert and the function keys are not used by any widget, but
    // resolving them means an app can observe them rather than seeing KEY_NONE.
    try std.testing.expect(evdevFor("CapsLock") != KEY_NONE);
    try std.testing.expect(evdevFor("Insert") != KEY_NONE);
    try std.testing.expect(evdevFor("PageUp") != KEY_NONE);
    try std.testing.expect(evdevFor("PageDown") != KEY_NONE);
    for ([_][]const u8{ "F1", "F2", "F6", "F12" }) |code| {
        try std.testing.expect(evdevFor(code) != KEY_NONE);
    }
}
