//! glinlandui demo application — ONE source file, every platform.
const std = @import("std");
const glinlandui = @import("glinlandui");

/// The demo tree lives in `src/demo_app.zig` so the browser build and the native build prove the SAME frame rather than two copies that can drift apart.
const demo_app = @import("demo_app.zig");
const App = demo_app.App;

/// The browser's exported ABI, bound to this application.
const web = glinlandui.platform.web_exports.Exports(App, App.root);

/// The webapp's font, as a generated module.
const font_data = @import("font_data");

/// The embedded font, handed to the web entry point.
pub const embedded_font: []const u8 = if (@import("builtin").cpu.arch.isWasm())
    font_data.bytes
else
    &.{};

// The freestanding C runtime: `malloc`, `free`, `calloc`, `realloc`, `strtol`, `abort`, `abs` and the `str*` family.
comptime {
    if (@import("builtin").cpu.arch.isWasm()) {
        _ = glinlandui.web.compatImpl();
    }
}

/// The page's `std.log` sink, on a wasm build.
pub const std_options: std.Options = if (@import("builtin").cpu.arch.isWasm())
    .{ .logFn = web.logFn }
else
    .{};

pub fn main() !void {
    // The Clay arena outlives run() and is process-lifetime, so the allocator matches the harness convention (see core/testing/root.zig).
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

    // On a live compositor (Linux desktop) this opens a real window and blocks until closed.
    window.run() catch |err| {
        // The headless fallback is NATIVE-ONLY, and the guard is load-bearing rather than cosmetic.
        if (@import("builtin").cpu.arch.isWasm()) return;
        std.debug.print("window unavailable ({s}); rendering headless instead\n", .{@errorName(err)});
        try renderHeadless(&host, 480, 360);
    };
}

/// Render one real frame through the normal frame path into a software surface and report how many pixels were drawn.
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

/// Run one frame and hand back the emitted render commands via the frame probe.
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
