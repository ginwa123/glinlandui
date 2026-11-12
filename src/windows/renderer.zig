//! Windows renderer — the `renderer.zig` half of the platform mirror.
pub const Renderer = @import("../core/render_software.zig").Renderer;

/// The CPU surface type the software renderer draws into.
pub const Surface = @import("../core/render_software.zig").Surface;
