//! Linux pointer/keyboard value translation — the `input.zig` half of the platform mirror.

/// evdev button codes, matching `components.dispatch.BTN_LEFT` and `mac/input.zig`'s identical constants.
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
pub fn fixedToFloat(f: i32) f32 {
    return @as(f32, @floatFromInt(f)) / 256.0;
}

/// Wayland button code -> evdev code.
pub fn evdevButton(button: u32) u32 {
    return button;
}

/// `wl_pointer.button`'s `state` field -> a MOTION/DOWN/UP kind.
pub fn kindFromState(state: u32) u8 {
    return if (state == 1) DOWN else UP;
}
