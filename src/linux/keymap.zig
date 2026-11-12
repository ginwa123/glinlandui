//! Linux keycode mapping — the `keymap.zig` half of the platform mirror.

/// Sentinel for "no key".
pub const KEY_NONE: u32 = 0;

/// Wayland keycode -> evdev code.
pub fn toEvdev(key: u32) u32 {
    return key;
}

/// Alias matching `mac/keymap.zig`'s second name for the same question.
pub fn evdevFor(key: u32) u32 {
    return toEvdev(key);
}
