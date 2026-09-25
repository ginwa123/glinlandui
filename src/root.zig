//! glinlandui: platform-agnostic Clay GUI library.
//! Linux uses the native Wayland/EGL/GLES3 runtime; other supported hosts
//! use the CPU-only backend while preserving the same component, frame, host,
//! and headless-test surface. ZERO ui/* imports by design. Consumers do
//! `@import("glinlandui")`.
const builtin = @import("builtin");
const wayland = @import("wayland_api.zig");

// Clay bindings re-export: ui consumers must use `glinlandui.zclay` (not
// a second `@import("zclay")`) so Clay types crossing the library
// boundary (Color, RenderCommandArray) share one module identity with
// wayland.render.
pub const zclay = @import("zclay");

// Core surface.
pub const Window = wayland.Window;
pub const WindowConfig = wayland.WindowConfig;
pub const Delegate = wayland.Delegate;
pub const render = wayland.render;
pub const text = wayland.text;
pub const frame = wayland.frame;
pub const host = @import("wayland/host.zig");
/// Reusable, compositor-free UI test harness. Import this module from
/// application tests to drive the same Host/Clay path used at runtime.
pub const testing = @import("testing/root.zig");

// Pure utils (geometry / input / EGL / test-frames + legacy helpers).
pub const Placement = wayland.Placement;
pub const computePlacement = wayland.computePlacement;
pub const min_width = wayland.min_width;
pub const min_height = wayland.min_height;
pub const clampSize = wayland.clampSize;
pub const keyToClose = wayland.keyToClose;
pub const centeredAnchor = wayland.centeredAnchor;
pub const LayerSize = wayland.LayerSize;
pub const layerSize = wayland.layerSize;
pub const eglConfigAttribs = wayland.eglConfigAttribs;
pub const parseTestFrames = wayland.parseTestFrames;

// Namespaced access (back-compat for `glinlandui.wayland.Window`).
pub const wayland_lib = wayland;

// Agnostic reusable Clay components (moved from qs src/ui/components).
// Namespaced under `components` so `components.text` (label widget) never
// collides with `text` (wayland font utils) above.
pub const components = struct {
    pub const box = @import("components/box.zig");
    pub const button = @import("components/button.zig");
    pub const checkbox = @import("components/checkbox.zig");
    pub const click_registry = @import("components/click_registry.zig");
    pub const dispatch = @import("components/dispatch.zig");
    pub const dropdown = @import("components/dropdown.zig");
    pub const icon = @import("components/icon.zig");
    pub const image = @import("components/image.zig");
    pub const input = @import("components/input.zig");
    pub const list = @import("components/list.zig");
    pub const radio = @import("components/radio.zig");
    pub const scroll = @import("components/scroll.zig");
    pub const slider = @import("components/slider.zig");
    pub const text = @import("components/text.zig");
    pub const toggle = @import("components/toggle.zig");
};

test {
    // Portable CPU path: components, layout, Host, the test driver, and
    // renderer-independent helpers are verified on every supported host.
    _ = @import("testing/root.zig");
    _ = @import("wayland/host.zig");
    _ = @import("wayland/frame.zig");
    _ = @import("wayland/render_common.zig");

    // Linux additionally compiles the native Wayland/EGL/GLES3/Pango path.
    // It is not built on hosts that do not provide those client libraries.
    if (builtin.os.tag == .linux) {
        _ = @import("wayland.zig");
        _ = @import("wayland/render_gles3.zig");
        _ = @import("wayland/text.zig");
    }

    _ = @import("components/box.zig");
    _ = @import("components/button.zig");
    _ = @import("components/checkbox.zig");
    _ = @import("components/click_registry.zig");
    _ = @import("components/dispatch.zig");
    _ = @import("components/dropdown.zig");
    _ = @import("components/icon.zig");
    _ = @import("components/image.zig");
    _ = @import("components/input.zig");
    _ = @import("components/list.zig");
    _ = @import("components/radio.zig");
    _ = @import("components/scroll.zig");
    _ = @import("components/slider.zig");
    _ = @import("components/text.zig");
    _ = @import("components/toggle.zig");
}
