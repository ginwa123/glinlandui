//! The single bridge from `core/` to the platform composition root.
const platform = @import("../platform.zig");

pub const Window = platform.window.Window;
pub const WindowConfig = platform.window.WindowConfig;
pub const Delegate = platform.window.Delegate;

/// The renderer the frame path drives, resolved by the composition root.
pub const Renderer = platform.render_impl.Renderer;

/// The resolved text backend (pangocairo on Linux production, the deterministic portable estimator everywhere else and in every test build).
pub const TextBackend = platform.text_impl;
