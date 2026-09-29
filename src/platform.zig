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
const std = @import("std");

/// One window backend per OS, selected here and nowhere else.
///
/// The wasm arm is reached through `os.tag == .freestanding`, and then narrowed
/// by ARCHITECTURE: `wasm32-freestanding` and, say, `riscv32-freestanding` share
/// an `os.tag`, and only the first has a browser behind it. Anything else that
/// lands here keeps the CPU-only surface rather than pretending a canvas exists.
pub const window = if (builtin.is_test)
    @import("core/window_portable.zig")
else switch (builtin.os.tag) {
    .linux => @import("linux/window.zig"),
    .macos => @import("mac/window.zig"),
    .windows => @import("windows/window.zig"),
    .freestanding, .wasi => if (builtin.cpu.arch.isWasm()) @import("web/window.zig") else @import("core/window_portable.zig"),
    // No backend yet for anything else: the CPU-only path, so the library still
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
    // Windows presents through D3D11 but rasterises on the CPU, exactly as
    // macOS does through CoreGraphics; see windows/renderer.zig.
    .windows => @import("windows/renderer.zig"),
    // The browser draws with the same CPU rasterizer macOS does, because
    // `Surface` is already `ImageData`'s exact layout. `web/renderer.zig` is the
    // two-line re-export that says so where a reader will look for it.
    .freestanding, .wasi => if (builtin.cpu.arch.isWasm()) @import("web/renderer.zig") else @import("core/render_software.zig"),
    else => @import("core/render_software.zig"),
};

/// The file-dialog backend: "let the user pick a file, a folder or a save
/// target".
///
/// One OS branch, in the one file allowed to have it, for the same reason the
/// three above are here. A TEST build takes the portable stub on EVERY
/// platform, so the parity suite asserts the contract's types without a
/// compositor, a session bus or a window anywhere in sight — and so a Linux
/// runner and a macOS runner still report the same test count.
///
/// Linux asks the XDG Desktop Portal over D-Bus, macOS runs an `NSOpenPanel`
/// and Windows an `IFileDialog` — three unrelated APIs behind one question.
/// Each is a small file in its own platform folder, and the browser is the
/// stub: a page's `<input type="file">` has no filesystem paths and answers
/// asynchronously, which is a different problem rather than a smaller version
/// of this one.
pub const file_dialog = if (builtin.is_test)
    @import("core/file_dialog_portable.zig")
else switch (builtin.os.tag) {
    .linux => @import("linux/file_dialog.zig"),
    .macos => @import("mac/file_dialog.zig"),
    .windows => @import("windows/file_dialog.zig"),
    // A browser: `<input type="file">` through the page, which is async and
    // has no filesystem paths at all — a different problem, not a smaller
    // version of this one. Until it is written, the stub, which is a real
    // answer rather than a missing one.
    else => @import("core/file_dialog_portable.zig"),
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
    .windows => @import("windows/text.zig"),
    // A browser needs this arm specifically, and not merely for tidiness:
    // `core/text_portable.zig` probes font paths through `std.Io`, whose threaded
    // reactor cannot be analysed for a freestanding target, so selecting it here
    // would fail to compile rather than fail at runtime. `web/text.zig` takes the
    // pure estimator (`core/text_estimator.zig`) and answers every path-shaped
    // question with "no" — a browser's font arrives as BYTES and is installed with
    // `glyphs.installFont`.
    .freestanding, .wasi => if (builtin.cpu.arch.isWasm()) @import("web/text.zig") else @import("core/text_portable.zig"),
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

// ---- The file dialog's public surface ----
//
// The types come from the contract, the behaviour from the backend selected
// above, so `glinlandui.file_dialog.Options` means one thing on every host.
pub const FileDialogKind = file_dialog.Kind;
pub const FileDialogRule = file_dialog.Rule;
pub const FileDialogFilter = file_dialog.Filter;
pub const FileDialogOptions = file_dialog.Options;
pub const FileDialogStatus = file_dialog.Status;
pub const FileDialogSelection = file_dialog.Selection;
pub const FileDialogError = file_dialog.Error;

// ---- The two things an APPLICATION needs to know about the platform ----
//
// Everything else is already abstracted: `Window.run()` blocks on native and arms
// on the web, `Window` owns the event loop, and the renderer and text backend are
// resolved above. These two are the residue — the parts that cannot be hidden
// behind a method because they are a TYPE (the allocator) and a LINK-TIME
// requirement (the export surface).
//
// They exist so an application can be ONE source file on every platform:
//
//     pub fn main() !void {
//         const alloc = glinlandui.platform.allocator;
//         var app = App{};
//         var host = try glinlandui.host.Host.init(alloc, &app, App.root);
//         var window = glinlandui.Window.init(.{ ... });
//         window.delegate = host.delegate();
//         try window.run();
//     }
//
//     comptime { _ = glinlandui.platform.web_exports.bind(App, App.root); }
//
// The `comptime` line is what keeps the browser's `export fn` surface in the
// link. Zig analyses lazily from the module root, so an `export fn` in a file
// nothing references is never compiled and the linker has nothing to keep — which
// is exactly the bug that produced a module exporting `memory` and nothing else,
// and a black canvas.

/// The allocator an application's entry point should use.
///
/// Selected by MODULE, not by expression — see `alloc_native.zig` for why a
/// comptime `if` is not enough: both branches are analysed, so naming
/// `page_allocator` anywhere a wasm build compiles drags `std.Io.Threaded` (and
/// therefore `posix.system.getrandom`) into the freestanding graph.
///
/// This is the same selection shape as `window`, `render_impl` and `text_impl`
/// above, and for the same reason.
pub const allocator = if (builtin.cpu.arch.isWasm())
    @import("alloc_wasm.zig").allocator
else
    @import("alloc_native.zig").allocator;

/// The browser's exported ABI, on a wasm build; an empty struct everywhere else.
///
/// An application references it in a `comptime` block to force the export surface
/// into the link. On native the reference is to an empty struct, so the same line
/// compiles to nothing and ONE `main.zig` serves every platform.
///
/// The `is_test` guard matters: a test build must not analyse `web/exports.zig`,
/// because it names `std.heap.wasm_allocator` and cannot be compiled for a native
/// target. The parity suite compiles on Linux and macOS, so this has to be empty
/// there — the same rule as the `is_test` branches above.
pub const web_exports = if (builtin.is_test or !builtin.cpu.arch.isWasm())
    struct {
        /// A no-op on native, so the application can call it unconditionally.
        ///
        /// Returns a struct with the same shape the wasm version has, so
        /// `web_exports(App, App.root).installEmbeddedFont(...)` and
        /// `.logFn` resolve on every platform without an `if`.
        pub fn Exports(
            comptime App: type,
            comptime root: *const fn (?*anyopaque, u32, u32) void,
        ) type {
            _ = App;
            _ = root;
            return struct {
                /// A no-op on native: there is no embedded font to install,
                /// because the native backends resolve one from the filesystem.
                pub fn installEmbeddedFont(bytes: []const u8) void {
                    _ = bytes;
                }
                /// A no-op on native. The application's `std_options.logFn`
                /// points here only on a wasm build; see `src/main.zig`.
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
