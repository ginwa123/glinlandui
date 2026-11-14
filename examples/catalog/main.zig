// The entry point: the App, the window, and the Host that renders the app's content function.
const std = @import("std");
const glinlandui = @import("glinlandui");
const catalog = @import("catalog");

pub fn main(init: std.process.Init) !void {
    _ = init;
    const gpa = std.heap.page_allocator;

    var app = catalog.app.App{};
    app.start();

    var window = glinlandui.Window.init(gpa, .{
        .app_id = "glinlandui-catalog",
        .title = "glinlandui · catalog",
        .width = 960,
        .height = 760,
        .min_width = 520,
        .min_height = 400,
    });

    // `setContent { ... }`: the Host hands the composable the ctx it was built with.
    var host = try glinlandui.host.Host.init(gpa, &app, catalog.app.App.content);
    defer host.deinit();
    window.delegate = host.delegate();
    try window.run();
}
