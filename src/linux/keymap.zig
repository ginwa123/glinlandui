//! Linux keycode mapping — the `keymap.zig` half of the platform mirror.
//!
//! ## Why this file is nearly empty, and why it exists
//!
//! The Wayland protocol is explicit that `wl_keyboard.key` is already an
//! **evdev** code — the same numbering `components.dispatch` keys on. So Linux
//! needs no table: the mapping is the identity.
//!
//!     mac/keymap.zig     ~360 lines: AppKit virtual keycode -> evdev
//!     linux/keymap.zig   the identity, below
//!
//! That asymmetry is the *content* of this file. A reader comparing the two
//! folders learns where the translation burden actually sits, which is exactly
//! what the mirrored layout is for. The function names match so the question
//! ("what evdev code is this key?") is asked the same way on both sides.
//!
//! This module is pure Zig — no `@cImport`, no Wayland types — so it is
//! imported by the cross-platform parity suite in `src/root.zig` and therefore
//! type-checked on macOS as well as Linux. Keep it that way; see layering rule
//! R6 in `ci/check_layering.sh`.

/// Sentinel for "no key". Matches `mac/keymap.zig`'s `KEY_NONE` and the value
/// `components/input.zig` treats as "nothing pressed".
pub const KEY_NONE: u32 = 0;

/// Wayland keycode -> evdev code. The identity: see the module comment.
///
/// Kept as a function rather than a bare alias so that a future platform whose
/// protocol key is *not* evdev can implement the same name, and so the call
/// site in `window.zig` reads the same as the macOS one.
pub fn toEvdev(key: u32) u32 {
    return key;
}

/// Alias matching `mac/keymap.zig`'s second name for the same question. macOS
/// needs both because AppKit hands out two different numbers depending on the
/// call path; Linux has one, so this forwards.
pub fn evdevFor(key: u32) u32 {
    return toEvdev(key);
}
