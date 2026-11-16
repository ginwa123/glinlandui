// The entry point: `MainActivity`, and nothing else.
// It creates the App (the Activity's state), opens the window, and hands the window the screen as its root function.
const std = @import("std");
const glinlandui = @import("glinlandui");
const Ctx = glinlandui.props.Ctx;
const todo = @import("todo");

pub fn main(init: std.process.Init) !void {
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
    var host = try glinlandui.host.Host.init(gpa, Ctx.from(&app), todo.app.App.content);
    defer host.deinit();
    // The devtool: right-click anywhere for this app's component tree. One line, and the app itself is untouched.
    _ = glinlandui.devtools.attach(gpa, &host);
    window.delegate = host.delegate();
    // With `GLIN_DEVTOOLS=1` a client can also attach over a socket and drive this window; without it this is one null check.
    if (glinlandui.devtools.serve(gpa, init.io, "todo")) |svc| {
        svc.attach(&host);
        glinlandui.devtools.wakeWindow(&window, svc.wakeFd());
    }
    try window.run();
}
