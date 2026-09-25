//! Shared numeric protocol constants.
//!
//! These are the *values* defined by the Wayland protocol XMLs, in a
//! platform-neutral module with no C imports. Both the native Wayland backend
//! and the portable backend assert against this single table, so the two
//! platforms cannot drift apart or disagree about what "shape_pointer" means.
//!
//! Provenance (the values are not invented here):
//!   protocols/cursor-shape-v1.xml         -> CursorShape
//!   protocols/wlr-layer-shell-unstable-v1.xml -> LayerAnchor
//!   EGL 1.5 spec (EGL/egl.h)              -> EglAttrib / EglConfigKey
const std = @import("std");

/// wp_cursor_shape_manager_v1 <enum name="shape"> (cursor-shape-v1.xml).
pub const CursorShape = struct {
    pub const default: u32 = 1;
    pub const pointer: u32 = 4;
    pub const text: u32 = 9;
    pub const ew_resize: u32 = 26;
};

/// wlr_layer_shell_v1 <enum name="anchor"> (wlr-layer-shell-unstable-v1.xml).
/// Legacy: the tiled window no longer uses layer-shell, but the anchored
/// window helpers are still part of the public surface.
pub const LayerAnchor = struct {
    pub const top: u32 = 1;
    pub const bottom: u32 = 2;
    pub const left: u32 = 4;
    pub const right: u32 = 8;
};

/// The four EGL attribute *keys* used to build a config.
pub const EglAttrib = struct {
    pub const none: i32 = 0x3038;
    pub const buffer_size: i32 = 0x3020;
    pub const alpha_size: i32 = 0x3021;
    pub const blue_size: i32 = 0x3022;
    pub const green_size: i32 = 0x3023;
    pub const red_size: i32 = 0x3024;
    pub const depth_size: i32 = 0x3025;
    pub const stencil_size: i32 = 0x3026;
    pub const surface_type: i32 = 0x3033;
    pub const renderable_type: i32 = 0x3040;
};

/// The EGL attribute *values* used to build a config.
pub const EglConfigValue = struct {
    pub const window_bit: i32 = 0x0004;
    pub const openGL_es_bit: i32 = 0x0008;
    pub const openGL_es2_bit: i32 = 0x0004;
    pub const openGL_es3_bit: i32 = 0x00000040;
};

/// The canonical EGL config attribute list for a RGBA8, ES3, window-surface
/// config, terminated by EGL_NONE. Returned as i32 so it is identical on every
/// platform regardless of the C typedef the native backend would use.
pub fn eglConfigAttribs() [13]i32 {
    return .{
        EglAttrib.red_size,        8,
        EglAttrib.green_size,      8,
        EglAttrib.blue_size,       8,
        EglAttrib.alpha_size,      8,
        EglAttrib.surface_type,    EglConfigValue.window_bit,
        EglAttrib.renderable_type, EglConfigValue.openGL_es3_bit,
        EglAttrib.none,
    };
}

test "CursorShape values match cursor-shape-v1.xml" {
    try std.testing.expectEqual(@as(u32, 1), CursorShape.default);
    try std.testing.expectEqual(@as(u32, 4), CursorShape.pointer);
    try std.testing.expectEqual(@as(u32, 9), CursorShape.text);
    try std.testing.expectEqual(@as(u32, 26), CursorShape.ew_resize);
}

test "LayerAnchor values match wlr-layer-shell-unstable-v1.xml" {
    try std.testing.expectEqual(@as(u32, 1), LayerAnchor.top);
    try std.testing.expectEqual(@as(u32, 2), LayerAnchor.bottom);
    try std.testing.expectEqual(@as(u32, 4), LayerAnchor.left);
    try std.testing.expectEqual(@as(u32, 8), LayerAnchor.right);
    // All four OR'd together is the centred anchor.
    try std.testing.expectEqual(
        @as(u32, 15),
        LayerAnchor.top | LayerAnchor.bottom | LayerAnchor.left | LayerAnchor.right,
    );
}

test "EglAttrib keys match the EGL spec" {
    try std.testing.expectEqual(@as(i32, 0x3038), EglAttrib.none);
    try std.testing.expectEqual(@as(i32, 0x3024), EglAttrib.red_size);
    try std.testing.expectEqual(@as(i32, 0x3023), EglAttrib.green_size);
    try std.testing.expectEqual(@as(i32, 0x3022), EglAttrib.blue_size);
    try std.testing.expectEqual(@as(i32, 0x3021), EglAttrib.alpha_size);
    try std.testing.expectEqual(@as(i32, 0x3033), EglAttrib.surface_type);
    try std.testing.expectEqual(@as(i32, 0x3040), EglAttrib.renderable_type);
}

test "eglConfigAttribs requests RGBA8 + ES3 window and ends with NONE" {
    const a = eglConfigAttribs();
    // Red/green/blue/alpha size 8, in key/value pairs.
    try std.testing.expectEqual(EglAttrib.red_size, a[0]);
    try std.testing.expectEqual(@as(i32, 8), a[1]);
    try std.testing.expectEqual(EglAttrib.green_size, a[2]);
    try std.testing.expectEqual(@as(i32, 8), a[3]);
    try std.testing.expectEqual(EglAttrib.blue_size, a[4]);
    try std.testing.expectEqual(@as(i32, 8), a[5]);
    try std.testing.expectEqual(EglAttrib.alpha_size, a[6]);
    try std.testing.expectEqual(@as(i32, 8), a[7]);
    // Window surface + ES3 renderable.
    try std.testing.expectEqual(EglAttrib.surface_type, a[8]);
    try std.testing.expectEqual(EglConfigValue.window_bit, a[9]);
    try std.testing.expectEqual(EglAttrib.renderable_type, a[10]);
    try std.testing.expectEqual(EglConfigValue.openGL_es3_bit, a[11]);
    // Terminated by EGL_NONE.
    try std.testing.expectEqual(EglAttrib.none, a[12]);
}
