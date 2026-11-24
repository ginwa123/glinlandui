const std = @import("std");
const glinlandui = @import("glinlandui");
const demo = @import("demo");

const App = demo.App;
const web = glinlandui.platform.web_exports.Exports(App, App.root);

comptime {
    if (@import("builtin").cpu.arch.isWasm()) {
        _ = glinlandui.web.compatImpl();
    }
}

pub const std_options: std.Options = if (@import("builtin").cpu.arch.isWasm())
    .{ .logFn = web.logFn }
else
    .{};

pub fn main() !void {
    const alloc = glinlandui.platform.allocator;
    _ = glinlandui.Window;
    _ = glinlandui.WindowConfig;
    _ = glinlandui.render;
    _ = glinlandui.text;

    var app = App{};
    var host = try glinlandui.host.Host.init(alloc, &app, App.root);
    defer host.deinit();
    _ = glinlandui.devtools.attach(alloc, &host);

    var window = glinlandui.Window.init(alloc, .{
        .app_id = "glinlandui",
        .title = "glinlandui",
        .width = 480,
        .height = 360,
        .min_width = 360,
        .min_height = 260,
    });
    window.delegate = host.delegate();

    window.run() catch |err| {
        if (@import("builtin").cpu.arch.isWasm()) return;
        std.debug.print("window unavailable ({s}); rendering headless instead\n", .{@errorName(err)});
        try renderHeadless(&host, 480, 360);
    };
}

fn renderHeadless(host: *glinlandui.host.Host, w: u32, h: u32) !void {
    const soft = glinlandui.software_render;
    var renderer = try soft.Renderer.init(glinlandui.platform.allocator);
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
