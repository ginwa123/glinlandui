//! Composition root — the ONLY file in the repository that branches on OS.
//!
//! Consumers (the library root, the demo, application code) depend on the
//! stable shape below so a CPU-only platform can compile the same Clay/UI
//! surface without pretending to present a native window.
//!
//! ## The test rule, which is the whole reason this file is centralised
//!
//! A TEST BUILD SELECTS `core/window_portable.zig` ON EVERY PLATFORM, and the
//! portable renderer + text estimator with it. That is what makes the Linux and
//! macOS test counts identical: the parity suite never analyzes either native
//! backend, so neither OS pulls in tests the other does not have. The native
//! backends are still tested — the Wayland one in the Linux-only `native-test`
//! step, and the macOS one's decision logic (pure Zig, in `mac/`) through the
//! parity suite itself.
//!
//! If that `builtin.is_test` branch is ever lost, `ci/check_test_parity.sh`
//! fails on both platforms. That is the intended alarm.
//!
//! ## Why this file is NOT under src/core/
//!
//! `core/` must not know that platforms exist — that is the point of the split,
//! and `ci/check_layering.sh` enforces it (rules R1, R3, R5). This file is the
//! single place allowed to know, so it sits beside `root.zig` at the top.
//!
//! Core modules that need a resolved implementation reach it through exactly one
//! bridge, `core/select.zig`, which is the only core file permitted to import
//! this one.
const builtin = @import("builtin");

/// One window backend per OS, selected here and nowhere else.
pub const window = if (builtin.is_test)
    @import("core/window_portable.zig")
else switch (builtin.os.tag) {
    .linux => @import("linux/window.zig"),
    .macos => @import("mac/window.zig"),
    // No backend yet (Windows): the CPU-only path, so the library still
    // compiles and its headless render still proves pixels.
    else => @import("core/window_portable.zig"),
};

/// The renderer the frame path drives.
///
/// A TEST build takes the shared software rasterizer on EVERY platform — that
/// is the parity rule, and it is why the GLES3 backend's tests can never leak
/// into the cross-platform count. A production build takes the platform folder's
/// own `renderer.zig`: the real EGL/GLES3 GPU path on Linux, and (today) the
/// same shared rasterizer re-exported on macOS, which is where a future Metal
/// path would land. The GLES3 backend is still tested, in the Linux-only
/// `native-test` step.
pub const render_impl = if (builtin.is_test)
    @import("core/render_software.zig")
else switch (builtin.os.tag) {
    .linux => @import("linux/renderer.zig"),
    .macos => @import("mac/renderer.zig"),
    else => @import("core/render_software.zig"),
};

/// The text backend. Production on Linux is the pangocairo shim; macOS uses the
/// deterministic portable estimator (see mac/text.zig). Every TEST build uses
/// the estimator on every OS, for the same parity reason as above.
///
/// The native module is reached only through the branch that uses it, so a test
/// or non-Linux build never touches the Pango-backed shim at all.
pub const text_impl = if (builtin.is_test)
    @import("core/text_portable.zig")
else switch (builtin.os.tag) {
    .linux => @import("linux/text.zig"),
    .macos => @import("mac/text.zig"),
    else => @import("core/text_portable.zig"),
};

// ---- Stable public window surface (formerly wayland_api.zig) ----
//
// `render`, `text` and `frame` deliberately do NOT live here. They are core
// facades (`core/render.zig`, `core/text_backend.zig`, `core/frame.zig`) which
// resolve through `core/select.zig`; re-exporting them from this file would
// close an import cycle, because `select.zig` imports this file and the
// backends below import the facades. `root.zig` imports them directly.
pub const Window = window.Window;
pub const WindowConfig = window.WindowConfig;
pub const Delegate = window.Delegate;

// Pure utils (geometry / input / EGL / test-frames + legacy helpers).
pub const Placement = window.Placement;
pub const computePlacement = window.computePlacement;
pub const min_width = window.min_width;
pub const min_height = window.min_height;
pub const clampSize = window.clampSize;
pub const keyToClose = window.keyToClose;
pub const centeredAnchor = window.centeredAnchor;
pub const LayerSize = window.LayerSize;
pub const layerSize = window.layerSize;
pub const eglConfigAttribs = window.eglConfigAttribs;
pub const parseTestFrames = window.parseTestFrames;
