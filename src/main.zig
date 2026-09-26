//! glinlandui demo application.
//!
//! Wires the toolkit surface together the way a real consumer would:
//!   App (a root callback that builds a Clay tree with real components)
//!     -> Host (Clay arena, input routing, frame scheduler)
//!       -> Window (Wayland/EGL/GLES3 on Linux, Cocoa/CoreGraphics on macOS)
//!
//! On BOTH platforms the same components are laid out and turned into real
//! pixels. Linux draws them through the GLES3 backend; macOS draws them
//! through the portable software rasterizer, blitted by CoreGraphics.
const std = @import("std");
const glinlandui = @import("glinlandui");

const components = glinlandui.components;

/// Demo application state. The counters the widgets mutate make the rendered
/// pixels visibly reflect interaction, proving clicks/inputs reach the tree.
const App = struct {
    clicks: u32 = 0,
    toggled: bool = false,
    slider_frac: f32 = 0.4,
    status_buf: [96]u8 = undefined,

    /// The Clay declare callback: everything drawing happens here.
    fn root(ctx: ?*anyopaque, _: u32, _: u32) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        self.declare();
    }

    fn declare(self: *App) void {
        const Self = @This();
        components.box.box(.{
            .id = "root",
            .direction = .column,
            .w = .grow,
            .h = .grow,
            .bg = 0x1e1e1e,
            .pad = 16,
            .gap = 12,
        }, self, Self.children);
    }

    fn children(self: *App) void {
        components.text.label(.{
            .str = "glinlandui",
            .font_size = 24,
            .color = 0xf0f0f0,
        });
        components.text.label(.{
            .str = "real pixels, identical tests on Linux and macOS",
            .font_size = 14,
            .color = 0x9a9a9a,
        });
        components.button.button(.{
            .id = "click-me",
            .label = "Click me",
            .w = 180,
            .h = 40,
            .on_click = onClick,
            .ctx = self,
        });
        components.toggle.toggle(.{
            .id = "toggle",
            .on = self.toggled,
            .on_click = onToggle,
            .ctx = self,
        });
        components.slider.slider(.{
            .id = "slider",
            .w = 220,
            .h = 24,
            .value = self.slider_frac,
            .on_change = onSlider,
            .ctx = self,
        });
        components.text.label(.{
            .str = self.statusText(),
            .font_size = 13,
            .color = 0x7ab8ff,
        });
    }

    fn statusText(self: *App) []const u8 {
        return std.fmt.bufPrint(&self.status_buf, "clicks={d} toggled={} slider={d}", .{
            self.clicks,
            self.toggled,
            @as(u32, @intFromFloat(self.slider_frac * 100)),
        }) catch "status";
    }

    fn onClick(ctx: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        self.clicks += 1;
    }

    fn onToggle(ctx: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        self.toggled = !self.toggled;
    }

    fn onSlider(ctx: ?*anyopaque) void {
        // The slider stores its fraction; advance it so the fill visibly
        // moves and the status line updates.
        const self: *App = @ptrCast(@alignCast(ctx.?));
        self.slider_frac = if (self.slider_frac >= 0.95) 0.05 else self.slider_frac + 0.1;
    }
};

pub fn main() !void {
    // The Clay arena outlives run() and is process-lifetime, so the page
    // allocator matches the harness convention (see core/testing/root.zig).
    const alloc = std.heap.page_allocator;

    // Reference the surface so the build proves the re-exports resolve.
    _ = glinlandui.Window;
    _ = glinlandui.WindowConfig;
    _ = glinlandui.render;
    _ = glinlandui.text;

    var app = App{};
    var host = try glinlandui.host.Host.init(alloc, &app, App.root);
    defer host.deinit();

    var window = glinlandui.Window.init(.{
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
    window.run() catch |err| {
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
