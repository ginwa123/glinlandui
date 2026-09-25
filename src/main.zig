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
    // allocator matches the harness convention (see testing/root.zig).
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

    // On a headless host (no compositor / no GUI session) run() completes a
    // real render and returns; on a live compositor it opens a window and
    // blocks until closed. Either way the same Clay layout was rasterized
    // into real pixels by the platform renderer.
    try window.run();
}

test "glinlandui surface resolves" {
    _ = glinlandui.Window;
    _ = glinlandui.WindowConfig;
    _ = glinlandui.render;
    _ = glinlandui.text;
}
