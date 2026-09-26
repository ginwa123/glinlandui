//! The single bridge from `core/` to the platform composition root.
//!
//! This is the ONLY file under `src/core/` allowed to import `../platform.zig`
//! — layering rule R2, enforced by `ci/check_layering.sh`. It exists so a core
//! module that needs a platform-resolved implementation asks one obviously-named
//! place, instead of each re-deriving an OS switch (which R3 and R5 forbid).
//!
//! Keep it this thin. Every symbol added here is a new hole between the
//! platform-agnostic half of the library and the platform half.
//!
//! Note what is deliberately absent: nothing here exposes `Host`, the
//! components, or the frame loop. Those are core logic and must compile
//! identically everywhere, so they import `window_contract.zig` directly rather
//! than routing through a platform.
const platform = @import("../platform.zig");

pub const Window = platform.window.Window;
pub const WindowConfig = platform.window.WindowConfig;
pub const Delegate = platform.window.Delegate;

/// The renderer the frame path drives, resolved by the composition root.
pub const Renderer = platform.render_impl.Renderer;

/// The resolved text backend (pangocairo on Linux production, the deterministic
/// portable estimator everywhere else and in every test build).
pub const TextBackend = platform.text_impl;
