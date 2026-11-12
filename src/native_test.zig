//! Standalone test root for the Linux-only `native-test` step.
test {
    _ = @import("linux/text.zig");
    _ = @import("linux/renderer.zig");
    _ = @import("linux/window.zig");
    // The file dialog's live half: a D-Bus client that talks to a real session bus, and a fake portal that answers it.
    _ = @import("linux/file_dialog.zig");
}
