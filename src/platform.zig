//! Composition root — the ONLY file in the repository that branches on OS.
const builtin = @import("builtin");
const std = @import("std");

/// One window backend per OS, selected here and nowhere else.
pub const window = if (builtin.is_test)
    @import("core/window_portable.zig")
else switch (builtin.os.tag) {
    .linux => @import("linux/window.zig"),
    .macos => @import("mac/window.zig"),
    .windows => @import("windows/window.zig"),
    .freestanding, .wasi => if (builtin.cpu.arch.isWasm()) @import("web/window.zig") else @import("core/window_portable.zig"),
    // No backend yet for anything else: the CPU-only path, so the library still compiles and its headless render still proves pixels.
    else => @import("core/window_portable.zig"),
};

/// The renderer the frame path drives.
pub const render_impl = if (builtin.is_test)
    @import("core/render_software.zig")
else switch (builtin.os.tag) {
    .linux => @import("linux/renderer.zig"),
    .macos => @import("mac/renderer.zig"),
    // Windows presents through D3D11 but rasterises on the CPU, exactly as macOS does through CoreGraphics; see windows/renderer.zig.
    .windows => @import("windows/renderer.zig"),
    // The browser draws with the same CPU rasterizer macOS does, because `Surface` is already `ImageData`'s exact layout.
    .freestanding, .wasi => if (builtin.cpu.arch.isWasm()) @import("web/renderer.zig") else @import("core/render_software.zig"),
    else => @import("core/render_software.zig"),
};

/// The file-dialog backend: "let the user pick a file, a folder or a save target".
pub const file_dialog = if (builtin.is_test)
    @import("core/file_dialog_portable.zig")
else switch (builtin.os.tag) {
    .linux => @import("linux/file_dialog.zig"),
    .macos => @import("mac/file_dialog.zig"),
    .windows => @import("windows/file_dialog.zig"),
    // A browser: `<input type="file">` through the page, which is async and has no filesystem paths at all — a different problem, not a smaller version of.
    else => @import("core/file_dialog_portable.zig"),
};

/// The text backend.
pub const text_impl = if (builtin.is_test)
    @import("core/text_portable.zig")
else switch (builtin.os.tag) {
    .linux => @import("linux/text.zig"),
    .macos => @import("mac/text.zig"),
    .windows => @import("windows/text.zig"),
    // A browser needs this arm specifically, and not merely for tidiness: `core/text_portable.zig` probes font paths through `std.Io`, whose threaded.
    .freestanding, .wasi => if (builtin.cpu.arch.isWasm()) @import("web/text.zig") else @import("core/text_portable.zig"),
    else => @import("core/text_portable.zig"),
};

// ---- Stable public window surface (formerly wayland_api.zig) ---- `render`, `text` and `frame` deliberately do NOT live here.
pub const Window = window.Window;
pub const WindowConfig = window.WindowConfig;
pub const Delegate = window.Delegate;

// ---- The file dialog's public surface ---- The types come from the contract, the behaviour from the backend selected above, so.
pub const FileDialogKind = file_dialog.Kind;
pub const FileDialogRule = file_dialog.Rule;
pub const FileDialogFilter = file_dialog.Filter;
pub const FileDialogOptions = file_dialog.Options;
pub const FileDialogStatus = file_dialog.Status;
pub const FileDialogSelection = file_dialog.Selection;
pub const FileDialogError = file_dialog.Error;

// ---- The two things an APPLICATION needs to know about the platform ---- Everything else is already abstracted: `Window.run()` blocks on native and.

/// The allocator an application's entry point should use.
pub const allocator = if (builtin.cpu.arch.isWasm())
    @import("alloc_wasm.zig").allocator
else
    @import("alloc_native.zig").allocator;

/// The browser's exported ABI, on a wasm build; an empty struct everywhere else.
pub const web_exports = if (builtin.is_test or !builtin.cpu.arch.isWasm())
    struct {
        /// A no-op on native, so the application can call it unconditionally.
        pub fn Exports(
            comptime App: type,
            comptime root: *const fn (?*anyopaque, u32, u32) void,
        ) type {
            _ = App;
            _ = root;
            return struct {
                /// A no-op on native: there is no embedded font to install, because the native backends resolve one from the filesystem.
                pub fn installEmbeddedFont(bytes: []const u8) void {
                    _ = bytes;
                }
                /// A no-op on native.
                pub fn logFn(
                    comptime level: std.log.Level,
                    comptime scope: @TypeOf(.enum_literal),
                    comptime format: []const u8,
                    args: anytype,
                ) void {
                    _ = level;
                    _ = scope;
                    _ = format;
                    _ = args;
                }
            };
        }
    }
else
    @import("web/exports.zig");

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
