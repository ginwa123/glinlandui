//! Standalone test root for the Linux-only `native-test` step.
//!
//! Deliberately NOT the same thing as `src/root.zig`. That file is the
//! CROSS-PLATFORM parity root and imports only portable modules, so Linux and
//! macOS report an identical count. This one is its opposite: it exists to pull
//! in the *native* Linux backends (Wayland/EGL/GLES3/Pango), which the parity
//! root deliberately never analyzes.
//!
//! Why a separate file at src/ instead of rooting the module straight at a
//! backend file: Zig rejects an `@import` that escapes the module's root
//! DIRECTORY ("import of file outside module path"), and the native backends
//! import the shared `core/` modules (render_common, window_contract). A module
//! rooted at src/linux/ therefore cannot reach src/core/; one rooted at src/
//! reaches both — the same reason the parity root lives here.
test {
    _ = @import("linux/text.zig");
    _ = @import("linux/renderer.zig");
    _ = @import("linux/window.zig");
    // The file dialog's live half: a D-Bus client that talks to a real session
    // bus, and a fake portal that answers it. This is the only place those can
    // run — they need a bus, and a CI runner has none, so they SKIP there and
    // RUN on a developer machine with a session (see the file's own notes on
    // the two bugs only a live bus can find).
    _ = @import("linux/file_dialog.zig");
}
