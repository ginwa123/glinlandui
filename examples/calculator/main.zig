// The entry point: the window, the Host, and the browser's exported ABI — and nothing else.
// It creates the App (the Activity), opens the window, and hands the window the screen as its root function.
const std = @import("std");
const glinlandui = @import("glinlandui");
const calculator = @import("calculator");

const App = calculator.app.App;

/// The browser's exported ABI, bound to THIS application: on a wasm build this instantiates `src/web/exports.zig` with this app's type and root callback, which forces every `export fn` into the link; on native it is a no-op struct with the same shape, so the same `main` serves every platform.
const web = glinlandui.platform.web_exports.Exports(App, App.content);

// The freestanding C runtime, reached THROUGH the library: a relative `../src/web/compat_impl.zig` would escape this module's root directory. Guarded by `isWasm` because native has a real libc, and defining these again would be a duplicate symbol.
comptime {
    if (@import("builtin").cpu.arch.isWasm()) {
        _ = glinlandui.web.compatImpl();
    }
}

/// The page's `std.log` sink, on a wasm build. See `src/main.zig` for why this is conditional: overriding `logFn` with a no-op on Linux would silence the Wayland diagnostics the native build relies on.
pub const std_options: std.Options = if (@import("builtin").cpu.arch.isWasm())
    .{ .logFn = web.logFn }
else
    .{};

pub fn main() !void {
    // The Clay arena outlives run() and is process-lifetime, so the allocator matches the harness convention (see core/testing/root.zig). On the web this is `wasm_allocator`; see `platform.allocator`.
    const alloc = glinlandui.platform.allocator;

    var app = App{};
    app.start();

    var host = try glinlandui.host.Host.init(alloc, &app, App.content);
    defer host.deinit();

    // Registered through `onHostReady` rather than inline, so the web entry point — which creates its own Host and has no `main` to run — wires the same KeyChain, which is what makes the numeric keypad work in a browser.
    App.onHostReady(&host, &app);

    var window = glinlandui.Window.init(alloc, .{
        .app_id = "glinlandui-calculator",
        .title = "glinlandui - calculator",
        .width = 360,
        // 425 is the measured content height at its tallest (expression line shown: keys end at y=412.8 + 12px padding); 430 leaves a few pixels of slack so the window never clips the keypad.
        .height = 430,
        .min_width = 360,
        .min_height = 430,
    });
    window.delegate = host.delegate();

    // On a live compositor this opens a real Wayland window and blocks until closed; headless (CI, no GUI session) the window cannot open, which is an expected environment, not a failure. On the web it ARMS the loop and returns — the page owns the event loop.
    window.run() catch |err| {
        // The headless fallback is NATIVE-ONLY, and the guard is load-bearing: `std.debug.print` reaches `std.Io.Threaded` for its stderr lock, which cannot be analysed for a freestanding target. A browser has no stderr anyway; the page reads `glin_web_log_errors()` instead.
        if (@import("builtin").cpu.arch.isWasm()) return;
        std.debug.print(
            "window unavailable ({s}); rendering headless instead\n",
            .{@errorName(err)},
        );
        try renderHeadless(&host, 360, 440);
    };
}

/// Render one real frame through the normal frame path into a software surface and report how many pixels were drawn, so a headless host still exercises and proves the renderer. NATIVE-ONLY: it uses `std.debug.print` and `std.c.getenv`, neither of which exists on a freestanding target, so the caller guards it with `isWasm`.
fn renderHeadless(host: *glinlandui.host.Host, w: u32, h: u32) !void {
    const soft = glinlandui.software_render;
    var renderer = try soft.Renderer.init(std.heap.page_allocator);
    defer renderer.deinit();

    var opt = glinlandui.frame.FrameOptions{};
    const commands = try captureCommands(host, w, h, &opt);
    renderer.surface.resize(w, h) catch return error.InvalidSize;
    renderer.surface.clear();
    renderer.surface.renderCommands(commands);

    // Optional raw dump of the rendered surface: the SAME env var and the same RGBA8 layout the macOS window backend writes (see `dumpRaw` in mac/window.zig), so a frame from either platform can be compared byte for byte instead of by eye.
    if (std.c.getenv("GLIN_DUMP_SURFACE")) |path| {
        if (std.c.fopen(path, "wb")) |f| {
            _ = std.c.fwrite(renderer.surface.pixels.ptr, 1, renderer.surface.pixels.len, f);
            _ = std.c.fclose(f);
            std.debug.print(
                "wrote {d} raw RGBA bytes ({d}x{d}) to {s}\n",
                .{ renderer.surface.pixels.len, w, h, std.mem.span(path) },
            );
        }
    }

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
        "glinlandui calculator rendered {d}x{d} headless ({d} painted pixels, no display available)\n",
        .{ w, h, painted },
    );
}

/// Run one frame and hand back the emitted render commands via the frame probe. The slice is owned by the Clay arena, valid for this frame only.
fn captureCommands(
    host: *glinlandui.host.Host,
    w: u32,
    h: u32,
    opt: *glinlandui.frame.FrameOptions,
) ![]const glinlandui.RenderCommand {
    const Sink = struct {
        var commands: []const glinlandui.RenderCommand = &.{};
        fn probe(_: ?*anyopaque, cmds: []const glinlandui.RenderCommand, _: u32, _: u32) void {
            commands = cmds;
        }
    };
    opt.probe = Sink.probe;
    opt.probe_user_data = null;
    _ = host.frameWithOptions(w, h, opt);
    return Sink.commands;
}
