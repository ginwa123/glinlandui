// The entry point: `MainActivity`, and nothing else.
// It creates the App (the Activity's state), opens the window, and hands the window the composition as its root
// function. Everything the screen does lives in `app.zig`, `view.zig` and `view_model.zig`.
const std = @import("std");
const glinlandui = @import("glinlandui");
const todo = @import("todo");

// Ask the window for one more frame. macOS-only, like every pump: the other backends drive their own loop.
fn pumpThroughWindow(ctx: ?*anyopaque) void {
    const window: *glinlandui.Window = @ptrCast(@alignCast(ctx.?));
    if (@hasDecl(glinlandui.Window, "setAnimating")) window.setAnimating(true);
}

// Stop asking, so an idle window goes quiet again.
fn idleThroughWindow(ctx: ?*anyopaque) void {
    const window: *glinlandui.Window = @ptrCast(@alignCast(ctx.?));
    if (@hasDecl(glinlandui.Window, "setAnimating")) window.setAnimating(false);
}

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

    // `setContent { ... }`: the composable the window renders. The Host hands it the ctx it was built with.
    const root = todo.composition.Composition.setContent(todo.app.App.content);
    var host = try glinlandui.host.Host.init(gpa, &app, root);
    defer host.deinit();
    host.keys.register(todo.app.App.onKey, &app);
    host.keys.registerText(todo.app.App.onText, &app);
    window.delegate = host.delegate();

    app.pump = pumpThroughWindow;
    app.idle = idleThroughWindow;
    app.pump_ctx = &window;
    try window.run();
}
