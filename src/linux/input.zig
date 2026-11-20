//! Linux pointer/keyboard value translation — the `input.zig` half of the platform mirror.

const contract = @import("../core/pointer_contract.zig");

/// The kinds and button codes are the one pointer contract's, so no backend can drift from the others.
pub const MOTION = contract.MOTION;
pub const DOWN = contract.DOWN;
pub const UP = contract.UP;
pub const BTN_LEFT = contract.BTN_LEFT;
pub const BTN_RIGHT = contract.BTN_RIGHT;
pub const BTN_MIDDLE = contract.BTN_MIDDLE;

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
