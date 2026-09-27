//! Browser renderer — the `renderer.zig` half of the platform mirror.
//!
//! ## Why this file is thin, and why it exists anyway
//!
//! Linux has a real GPU path: `linux/renderer.zig` drives Wayland + EGL + GLES3.
//! The browser does not use one — WebGL2 is a *JavaScript* API, so reaching it
//! from wasm means either ~60 curated wasm→JS imports or a command-buffer
//! protocol, for zero visual difference at the sizes this toolkit targets. So the
//! renderer here *is* the shared software rasterizer in `core/`, exactly as on
//! macOS. (See WEB_PLAN.md §D1 and §Phase 5: WebGL2 is a later, separately
//! measured optimisation behind this same contract.)
//!
//! Rather than leave that fact buried in a branch inside `platform.zig`, it is
//! stated here. A reader can diff
//!
//!     linux/renderer.zig   (GPU: EGL + GLES3, 1378 lines)
//!     mac/renderer.zig     (CPU: the shared rasterizer)
//!     web/renderer.zig     (CPU: the shared rasterizer, this file)
//!
//! and see the whole platform difference in one place. The platform folders are
//! meant to be read side by side; a silently absent file defeats that.
//!
//! Selection itself lives in the composition root (`src/platform.zig`), so this
//! module contains no OS branch: it is what a wasm build is told to use, not a
//! chooser.
//!
//! ## Why it is still the right renderer for a browser
//!
//! `Surface` is RGBA8, row-major, row 0 = the visual top, straight
//! (non-premultiplied) alpha — which is *exactly* `ImageData`'s layout in the
//! DOM. `mac/present.zig` already measured that the correct hand-off for a
//! top-left-origin consumer is the IDENTITY (no channel swap, no vertical flip);
//! `web/present.zig` is that same finding, plus the one rule the DOM adds.
pub const Renderer = @import("../core/render_software.zig").Renderer;

/// The CPU surface type the software renderer draws into. `web/present.zig`
/// owns the hand-off from this buffer to the `<canvas>`.
pub const Surface = @import("../core/render_software.zig").Surface;
