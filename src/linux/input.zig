//! Linux pointer/keyboard value translation — the `input.zig` half of the
//! platform mirror.
//!
//! ## What Linux has to translate, and what it does not
//!
//! `mac/input.zig` exists because AppKit hands the backend bottom-left-origin
//! `CGFloat` coordinates and `NSEventButtonNumber` 0/1/2, none of which are the
//! toolkit's units. It therefore owns a `Raw` -> `Translated` conversion.
//!
//! Wayland hands the backend `wl_fixed_t` (24.8 fixed point) surface-local
//! coordinates and already-evdev button codes, which are *nearly* the toolkit's
//! units. So the translation here is only:
//!
//!   - 24.8 fixed point -> f32                  (`fixedToFloat`)
//!   - "button code" -> evdev code              (`evdevButton`, the identity)
//!   - press/release wire state -> MOTION/DOWN/UP (`kindFromState`)
//!
//! There is deliberately no `Raw`/`Translated` round trip. Inventing one would
//! mean un-translating data that already arrives in the target form, purely to
//! match a file next door — which is the kind of symmetry that makes code worse.
//! The shared names are the ones that genuinely answer the same question.
//!
//! Pure Zig — no `@cImport` — so the parity suite type-checks it on macOS too.
//! That is why `fixedToFloat` takes `i32` rather than `c.wl_fixed_t`: a
//! `wl_fixed_t` IS an `int32_t`, so the call sites are unchanged, and this file
//! stays free of Wayland headers. See `ci/check_layering.sh` rule R6.

/// evdev button codes, matching `components.dispatch.BTN_LEFT` and
/// `mac/input.zig`'s identical constants.
pub const BTN_LEFT: u32 = 272;
pub const BTN_RIGHT: u32 = 273;
pub const BTN_MIDDLE: u32 = 274;

/// The pointer moved; no button transition. Same values as `mac/input.zig`.
pub const MOTION: u8 = 0;
/// A button went down.
pub const DOWN: u8 = 1;
/// A button went up.
pub const UP: u8 = 2;

/// `wl_fixed_t` (24.8 signed fixed point) -> pixels.
///
/// Moved here verbatim from `window.zig`; the divisor is the protocol's 8
/// fractional bits, not a tunable.
pub fn fixedToFloat(f: i32) f32 {
    return @as(f32, @floatFromInt(f)) / 256.0;
}

/// Wayland button code -> evdev code. The identity: `wl_pointer.button` is
/// already an evdev code (BTN_LEFT is 272 on the wire), unlike AppKit's 0/1/2.
pub fn evdevButton(button: u32) u32 {
    return button;
}

/// `wl_pointer.button`'s `state` field -> a MOTION/DOWN/UP kind.
/// The protocol defines state 1 = pressed, 0 = released; anything else is not
/// representable, and `keyboardKey` already gates on exactly that pair.
pub fn kindFromState(state: u32) u8 {
    return if (state == 1) DOWN else UP;
}
