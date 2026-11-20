//! The pointer adapter of a host with no platform of its own: identity points, and the toolkit's own button numbering.
const contract = @import("pointer_contract.zig");

/// A point already in toolkit space, so there is no origin to flip.
pub const Point = struct {
    x: f32,
    y: f32,
};

pub const MOTION = contract.MOTION;
pub const DOWN = contract.DOWN;
pub const UP = contract.UP;
pub const Raw = contract.Raw;
pub const Translated = contract.Translated;

pub fn toToolkitPoint(_: u32, _: u32, x: f32, y: f32) Point {
    return .{ .x = x, .y = y };
}

/// 0 left, 1 right, 2 middle — the same numbering AppKit and Win32 use.
pub fn evdevButton(button_number: i32) u32 {
    return switch (button_number) {
        0 => contract.BTN_LEFT,
        1 => contract.BTN_RIGHT,
        else => contract.BTN_MIDDLE,
    };
}

pub fn translate(w: u32, h: u32, raw: Raw, held: bool) Translated {
    return contract.translate(@This(), w, h, raw, held);
}
