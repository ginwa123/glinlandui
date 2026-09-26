//! Public platform-window facade.
//!
//! The Wayland/EGL runtime remains a Linux implementation detail. Consumers
//! (Host, the library root, and application code) depend on this stable shape
//! so a CPU-only platform can compile the same Clay/UI surface without
//! pretending to present a Wayland window.
const builtin = @import("builtin");
// One window module per OS, selected here and nowhere else. Every consumer
// (Host, the library root, application code) depends on this stable shape.
//
// TEST BUILDS SELECT `wayland_portable.zig` ON EVERY PLATFORM. That is the
// single most important rule in this file: it means the parity suite never
// analyzes either native backend, so Linux and macOS report an identical test
// count even though the two backends are completely different code. The
// native modules are still tested — the Wayland one in `native-test`, and the
// macOS one's decision logic in `platform/` (pure, cross-platform).
const platform = if (builtin.is_test)
    @import("wayland_portable.zig")
else switch (builtin.os.tag) {
    .linux => @import("wayland.zig"),
    .macos => @import("wayland_macos.zig"),
    // No backend yet (Windows): the CPU-only path, so the library still
    // compiles and its headless render still proves pixels.
    else => @import("wayland_portable.zig"),
};

pub const Window = platform.Window;
pub const WindowConfig = platform.WindowConfig;
pub const Delegate = platform.Delegate;
pub const render = @import("wayland/render.zig");
pub const text = @import("wayland/text_backend.zig");
pub const frame = @import("wayland/frame.zig");
pub const Placement = platform.Placement;
pub const computePlacement = platform.computePlacement;
pub const min_width = platform.min_width;
pub const min_height = platform.min_height;
pub const clampSize = platform.clampSize;
pub const keyToClose = platform.keyToClose;
pub const centeredAnchor = platform.centeredAnchor;
pub const LayerSize = platform.LayerSize;
pub const layerSize = platform.layerSize;
pub const eglConfigAttribs = platform.eglConfigAttribs;
pub const parseTestFrames = platform.parseTestFrames;
