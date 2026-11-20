//! One pointer translation for every backend: the kinds, the event shape, and the switch they all share.
const std = @import("std");

/// The pointer moved; no button transition happened.
pub const MOTION: u8 = 0;
/// A button went down.
pub const DOWN: u8 = 1;
/// A button went up.
pub const UP: u8 = 2;

/// evdev button codes, matching `components.dispatch.BTN_LEFT`.
pub const BTN_LEFT: u32 = 272;
pub const BTN_RIGHT: u32 = 273;
pub const BTN_MIDDLE: u32 = 274;

/// One pointer event before translation, filled in from whichever OS event the backend received.
pub const Raw = struct {
    kind: u8,
    /// 0 left, 1 right, 2 middle, 3 and up extra — in the backend's own numbering.
    button_number: i32,
    /// In the backend's own origin: AppKit counts y from the bottom, Win32 and the DOM from the top.
    x: f32,
    y: f32,
};

/// The Delegate's shape, ready to hand to `d.on_pointer`.
pub const Translated = struct {
    x: f32,
    y: f32,
    pressed: bool,
    /// The evdev code on a transition, and 0 on motion — matching Wayland exactly, which keeps drag detection working.
    button: u32,
};

/// The one translation; an `Adapter` supplies only `toToolkitPoint(w, h, x, y)` and `evdevButton(button_number)`.
pub fn translate(comptime Adapter: type, w: u32, h: u32, raw: Raw, held: bool) Translated {
    const pt = Adapter.toToolkitPoint(w, h, raw.x, raw.y);
    return switch (raw.kind) {
        // Motion carries button 0 so it lands in dispatch's drag arm.
        MOTION => .{ .x = pt.x, .y = pt.y, .pressed = held, .button = 0 },
        DOWN => .{ .x = pt.x, .y = pt.y, .pressed = true, .button = Adapter.evdevButton(raw.button_number) },
        UP => .{ .x = pt.x, .y = pt.y, .pressed = false, .button = Adapter.evdevButton(raw.button_number) },
        // Unknown kind: treat as motion rather than inventing a press.
        else => .{ .x = pt.x, .y = pt.y, .pressed = held, .button = 0 },
    };
}
