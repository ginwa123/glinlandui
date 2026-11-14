// The entry point: `MainActivity`, and nothing else.
// It creates the App (the Activity's state), opens the window, and hands the window the screen as its root function.
const std = @import("std");
const glinlandui = @import("glinlandui");
const todo = @import("todo");

pub fn main(init: std.process.Init) !void {
    _ = init;
    const gpa = std.heap.page_allocator;

    var app = todo.app.App{};
    app.start();

    var window = glinlandui.Window.init(gpa, .{
        .app_id = "glinlandui-todo",
        .title = "glinlandui · todo (MVVM)",
        .width = 720,
        .height = 640,
        .min_width = 420,
        .min_height = 360,
    });

    // `setContent { ... }`: the Host hands the composable the ctx it was built with.
    var host = try glinlandui.host.Host.init(gpa, &app, todo.app.App.content);
    defer host.deinit();
    host.keys.register(todo.app.App.onKey, &app);
    host.keys.registerText(todo.app.App.onText, &app);
    window.delegate = host.delegate();
    try window.run();
}
