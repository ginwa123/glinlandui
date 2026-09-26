//! macOS renderer — the `renderer.zig` half of the platform mirror.
//!
//! ## Why this file is thin, and why it exists anyway
//!
//! Linux has a real GPU path: `linux/renderer.zig` drives Wayland + EGL +
//! GLES3. macOS does not, yet. The Cocoa shim presents a CPU bitmap, so the
//! renderer on this platform *is* the shared software rasterizer in `core/`.
//!
//! Rather than leave that fact buried in a branch inside `platform.zig`, it is
//! stated here. A reader can now diff
//!
//!     linux/renderer.zig   (GPU: EGL + GLES3, 1378 lines)
//!     mac/renderer.zig     (CPU: the shared rasterizer, this file)
//!
//! and see the whole difference in one place. The platform folders are meant to
//! be read side by side; a silently absent file defeats that.
//!
//! When a Metal/CoreGraphics GPU path lands, THIS is the file that grows and
//! `platform.zig` needs no edit — which is the real payoff of the mirror.
//!
//! Selection itself lives in the composition root (`src/platform.zig`), so this
//! module contains no OS branch: it is what macOS is told to use, not a chooser.
pub const Renderer = @import("../core/render_software.zig").Renderer;

/// The CPU surface type the software renderer draws into. The Cocoa shim
/// presents exactly this buffer, and `mac/present.zig` owns that hand-off.
pub const Surface = @import("../core/render_software.zig").Surface;
