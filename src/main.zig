//! glinlandui demo application — ONE source file, every platform.
//!
//! Wires the toolkit surface together the way a real consumer would:
//!   App (a root callback that builds a Clay tree with real components)
//!     -> Host (Clay arena, input routing, frame scheduler)
//!       -> Window (Wayland/EGL/GLES3 on Linux, Cocoa/CoreGraphics on macOS,
//!                  a canvas driven by the page on the web)
//!
//! ## There is no `web_main.zig`
//!
//! There used to be, and it was a design mistake: it duplicated this file's Host
//! setup, window config and delegate wiring, and differed only in how the program
//! starts. But "how the program starts" is exactly what `Window.run()` already
//! abstracts — it blocks on native and arms the loop on the web — so the entry
//! point has no business knowing which platform it is on.
//!
//! The two things that genuinely differ are supplied by `platform.zig`:
//!
//!   - `platform.allocator` — `page_allocator` natively, `wasm_allocator` on the
//!     web (the only one that grows a wasm module's linear memory);
//!   - `platform.web_exports` — the browser's `export fn` surface on a wasm
//!     build, an empty struct everywhere else.
//!
//! The `comptime` block below is what keeps that surface in the link. Zig
//! analyses lazily from the module root, so an `export fn` in a file nothing
//! references is never compiled and the linker has nothing to keep — which is
//! exactly the bug that produced a module exporting `memory` and nothing else,
//! and a black canvas.
const std = @import("std");
const glinlandui = @import("glinlandui");

/// The demo tree lives in `src/demo_app.zig` so the browser build and the native
/// build prove the SAME frame rather than two copies that can drift apart. See
/// that file for why it sits in `src/` and why it imports `glinlandui` by module
/// name.
const demo_app = @import("demo_app.zig");
const App = demo_app.App;

/// The browser's exported ABI, bound to this application.
///
/// On a wasm build this instantiates `src/web/exports.zig` with this app's type
/// and root callback, which forces every `export fn` into the link. On native it
/// is a no-op struct with the same shape, so this line compiles to nothing and
/// the same `main` serves every platform.
///
/// The app type is a COMPTIME parameter rather than a mutable global because Zig
/// will not store a `type` at runtime, and `export fn` cannot take a comptime
/// parameter — the ABI is fixed by `src/web/shim.h`. See `web/exports.zig`.
const web = glinlandui.platform.web_exports.Exports(App, App.root);

/// The webapp's font, as a generated module. See `makeFontModule` in build.zig.
///
/// Empty on a native build (the option is the empty string), and empty when the
/// build was made with `-Dfont=none`. Either way `bytes.len == 0` means "no font",
/// and the toolkit draws its documented glyph-free per-byte bars.
const font_data = @import("font_data");

/// The embedded font, handed to the web entry point.
///
/// `web/exports.zig` installs this from `glin_web_init`, before the first frame —
/// which is the only place it CAN happen, because on the web there is no `main`
/// to run: the page calls `glin_web_init`, which creates the Host and the Window
/// itself.
///
/// The bytes live in the module's data section for the lifetime of the instance,
/// which is exactly the lifetime the installed font needs (every glyph lookup
/// reads out of them). `Font.deinit` must never run on them.
///
/// Empty on native, where the backends resolve a font from the filesystem.
pub const embedded_font: []const u8 = if (@import("builtin").cpu.arch.isWasm())
    font_data.bytes
else
    &.{};

// The freestanding C runtime: `malloc`, `free`, `calloc`, `realloc`, `strtol`,
// `abort`, `abs` and the `str*` family.
//
// Referenced only for its `export fn`s, so the import is forced rather than kept
// in a variable nothing reads. Without it the vendored C TUs (Clay,
// stb_truetype) link against symbols that do not exist, and the failure is a
// wall of `undefined symbol: malloc` at link time.
//
// Reached through `glinlandui.web.compatImpl()` rather than a relative
// `@import("web/compat_impl.zig")`, because a relative import would put the file
// in BOTH this module and the library's — and Zig rejects a file that belongs to
// two modules (`file exists in modules 'root' and 'glinlandui'`). The library's
// function is the single entry point for it, and `examples/calculator.zig` uses
// the same one.
//
// Guarded by `isWasm` because on native there is a real libc and these symbols
// already exist — defining them again would be a duplicate-symbol error.
comptime {
    if (@import("builtin").cpu.arch.isWasm()) {
        _ = glinlandui.web.compatImpl();
    }
}

/// The page's `std.log` sink, on a wasm build.
///
/// A freestanding module has nowhere to print — the default `logFn` cannot even
/// compile — so messages become counters the page can read. On native this is a
/// no-op and the default logger is used, which is why the declaration is
/// conditional: overriding `logFn` with a no-op on Linux would silence the
/// Wayland diagnostics the native build relies on.
pub const std_options: std.Options = if (@import("builtin").cpu.arch.isWasm())
    .{ .logFn = web.logFn }
else
    .{};

pub fn main() !void {
    // The Clay arena outlives run() and is process-lifetime, so the allocator
    // matches the harness convention (see core/testing/root.zig). On the web this
    // is `wasm_allocator`; see `platform.allocator`.
    const alloc = glinlandui.platform.allocator;

    // Reference the surface so the build proves the re-exports resolve.
    _ = glinlandui.Window;
    _ = glinlandui.WindowConfig;
    _ = glinlandui.render;
    _ = glinlandui.text;

    var app = App{};
    var host = try glinlandui.host.Host.init(alloc, &app, App.root);
    defer host.deinit();

    var window = glinlandui.Window.init(alloc, .{
        .app_id = "glinlandui",
        .title = "glinlandui",
        .width = 480,
        .height = 360,
        .min_width = 360,
        .min_height = 260,
    });
    window.delegate = host.delegate();

    // On a live compositor (Linux desktop) this opens a real window and blocks
    // until closed. On a headless host — no compositor, or a CI runner with no
    // GUI session — the platform window cannot open; that is an expected
    // environment, not a failure, so we fall back to a real headless software
    // render. Either path lays out the same Clay tree and rasterizes it into
    // real RGBA8 pixels, so the demo always proves the renderer draws.
    //
    // On the web this ARMS the loop and returns: the page owns the event loop, so
    // there is nothing to block on. The module stays resident and the page drives
    // it through the exports above.
    window.run() catch |err| {
        // The headless fallback is NATIVE-ONLY, and the guard is load-bearing
        // rather than cosmetic. `std.debug.print` reaches `std.Io.Threaded` for
        // its stderr lock, and that reactor cannot be analysed for a freestanding
        // target — so merely mentioning it here fails the wasm build with
        // `posix.system has no member named 'getrandom'`. A browser has no stderr
        // anyway; the page reads `glin_web_log_errors()` instead.
        if (@import("builtin").cpu.arch.isWasm()) return;
        std.debug.print("window unavailable ({s}); rendering headless instead\n", .{@errorName(err)});
        try renderHeadless(&host, 480, 360);
    };
}

/// Render one real frame through the normal frame path into a software
/// surface and report how many pixels were drawn. Used when no display is
/// available, so the demo still exercises and proves the renderer.
fn renderHeadless(host: *glinlandui.host.Host, w: u32, h: u32) !void {
    const soft = glinlandui.software_render;
    var renderer = try soft.Renderer.init(std.heap.page_allocator);
    defer renderer.deinit();

    var opt = glinlandui.frame.FrameOptions{};
    const commands = try captureCommands(host, w, h, &opt);
    renderer.surface.resize(w, h) catch return error.InvalidSize;
    renderer.surface.clear();
    renderer.surface.renderCommands(commands);

    const clear = renderer.surface.clear_rgb;
    var painted: usize = 0;
    var i: usize = 0;
    while (i + 3 < renderer.surface.pixels.len) : (i += 4) {
        const r = @as(f32, @floatFromInt(renderer.surface.pixels[i]));
        const g = @as(f32, @floatFromInt(renderer.surface.pixels[i + 1]));
        const b = @as(f32, @floatFromInt(renderer.surface.pixels[i + 2]));
        if (r != clear[0] or g != clear[1] or b != clear[2]) painted += 1;
    }
    std.debug.print(
        "glinlandui rendered {d}x{d} headless ({d} painted pixels, no display available)\n",
        .{ w, h, painted },
    );
}

/// Run one frame and hand back the emitted render commands via the frame
/// probe. The slice is owned by the Clay arena, valid for this frame only.
fn captureCommands(
    host: *glinlandui.host.Host,
    w: u32,
    h: u32,
    opt: *glinlandui.frame.FrameOptions,
) ![]const glinlandui.zclay.RenderCommand {
    const Sink = struct {
        var commands: []const glinlandui.zclay.RenderCommand = &.{};
        fn probe(_: ?*anyopaque, cmds: []const glinlandui.zclay.RenderCommand, _: u32, _: u32) void {
            commands = cmds;
        }
    };
    opt.probe = Sink.probe;
    opt.probe_user_data = null;
    _ = host.frameWithOptions(w, h, opt);
    return Sink.commands;
}

test "glinlandui surface resolves" {
    _ = glinlandui.Window;
    _ = glinlandui.WindowConfig;
    _ = glinlandui.render;
    _ = glinlandui.text;
}
