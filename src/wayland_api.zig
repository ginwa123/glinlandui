//! Public platform-window facade.
//!
//! The Wayland/EGL runtime remains a Linux implementation detail. Consumers
//! (Host, the library root, and application code) depend on this stable shape
//! so a CPU-only platform can compile the same Clay/UI surface without
//! pretending to present a Wayland window.
const builtin = @import("builtin");
const platform = if (builtin.os.tag == .linux)
    @import("wayland.zig")
else
    @import("wayland_portable.zig");

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
