//! The POSIX terminal backend: the shared window over the raw-mode console, plus the pure surface `platform.zig` re-exports.
const core = @import("window_core.zig");
const console = @import("console_posix.zig");
const contract = @import("../core/window_contract.zig");

pub const Window = core.Window(console);
pub const WindowConfig = contract.WindowConfig;
pub const Delegate = contract.Delegate;

pub const Placement = contract.Placement;
pub const computePlacement = contract.computePlacement;
pub const min_width = contract.min_width;
pub const min_height = contract.min_height;
pub const clampSize = contract.clampSize;
pub const keyToClose = contract.keyToClose;
pub const centeredAnchor = contract.centeredAnchor;
pub const eglConfigAttribs = contract.eglConfigAttribs;
pub const LayerSize = contract.LayerSize;
pub const layerSize = contract.layerSize;
pub const parseTestFrames = contract.parseTestFrames;
