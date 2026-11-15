// The devtool binary: run one of the repository's apps headless and print its component tree, or photograph it.
const std = @import("std");
const glinlandui = @import("glinlandui");

const demo = @import("demo_app");
const calculator = @import("calculator");
const todo = @import("todo");
const catalog = @import("catalog");
const file_dialog = @import("file_dialog");
const lazy_scroll = @import("lazy_scroll");

const devtools = glinlandui.devtools;

// A prepared app: the context its root function takes, and the root itself.
const Prepared = struct {
    ctx: ?*anyopaque,
    root: glinlandui.host.RootFn,
};

// One inspectable app: how to build it, and the window size it is laid out at.
const AppSpec = struct {
    name: []const u8,
    width: u32,
    height: u32,
    prepare: *const fn (alloc: std.mem.Allocator, io: std.Io) anyerror!Prepared,
};

const apps = [_]AppSpec{
    .{ .name = "demo", .width = 480, .height = 360, .prepare = prepareDemo },
    .{ .name = "calculator", .width = 360, .height = 430, .prepare = prepareCalculator },
    .{ .name = "todo", .width = 720, .height = 640, .prepare = prepareTodo },
    .{ .name = "catalog", .width = 960, .height = 760, .prepare = prepareCatalog },
    .{ .name = "file-dialog", .width = 520, .height = 300, .prepare = prepareFileDialog },
    .{ .name = "lazy-scroll", .width = 900, .height = 640, .prepare = prepareLazyScroll },
};

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.page_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var opts = devtools.cli.parse(args);
    if (opts.help) return print(io, devtools.cli.usage);

    const spec = find(opts.app) orelse {
        std.debug.print("glinlandui-inspect: no app named '{s}'.\n\n", .{opts.app});
        return print(io, devtools.cli.usage);
    };
    // An app knows how big its own window is; --size is the override.
    if (!opts.size_given) {
        opts.width = spec.width;
        opts.height = spec.height;
    }

    const app = try spec.prepare(gpa, io);

    if (opts.shot) |path| {
        var file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        var buf: [8192]u8 = undefined;
        var out = file.writer(io, &buf);
        try devtools.shoot(gpa, opts, app.ctx, app.root, &out.interface);
        try out.interface.flush();
        std.debug.print("glinlandui-inspect: wrote {s} ({d}x{d}, {s} with the inspector open)\n", .{ path, opts.width, opts.height, spec.name });
        return;
    }

    var buf: [8192]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buf);
    try devtools.cli.dump(gpa, opts, app.ctx, app.root, &out.interface);
    try out.interface.flush();
}

fn find(name: []const u8) ?*const AppSpec {
    for (&apps) |*spec| {
        if (std.mem.eql(u8, spec.name, name)) return spec;
    }
    return null;
}

// The demo app has no state to start beyond its own defaults.
fn prepareDemo(alloc: std.mem.Allocator, io: std.Io) !Prepared {
    _ = io;
    const app = try alloc.create(demo.App);
    app.* = .{};
    return .{ .ctx = app, .root = demo.App.root };
}

fn prepareCalculator(alloc: std.mem.Allocator, io: std.Io) !Prepared {
    _ = io;
    const app = try alloc.create(calculator.app.App);
    app.* = .{};
    app.start();
    return .{ .ctx = app, .root = calculator.app.App.content };
}

fn prepareTodo(alloc: std.mem.Allocator, io: std.Io) !Prepared {
    _ = io;
    const app = try alloc.create(todo.app.App);
    app.* = .{};
    app.start();
    return .{ .ctx = app, .root = todo.app.App.content };
}

fn prepareCatalog(alloc: std.mem.Allocator, io: std.Io) !Prepared {
    _ = io;
    const app = try alloc.create(catalog.app.App);
    app.* = .{};
    app.start();
    return .{ .ctx = app, .root = catalog.app.App.content };
}

fn prepareFileDialog(alloc: std.mem.Allocator, io: std.Io) !Prepared {
    _ = io;
    const app = try alloc.create(file_dialog.app.App);
    app.* = .{};
    app.start();
    return .{ .ctx = app, .root = file_dialog.app.App.content };
}

// The one app with a dependency: its pump and its clock come from the Io the process owns.
fn prepareLazyScroll(alloc: std.mem.Allocator, io: std.Io) !Prepared {
    const app = try alloc.create(lazy_scroll.app.App);
    app.* = .{ .io = io };
    app.start();
    return .{ .ctx = app, .root = lazy_scroll.app.App.content };
}

fn print(io: std.Io, text: []const u8) !void {
    var buf: [1024]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buf);
    try out.interface.writeAll(text);
    try out.interface.flush();
}
