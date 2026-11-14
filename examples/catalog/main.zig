// The entry point: the App, the window, and the Host that renders the app's content function.
const std = @import("std");
const glinlandui = @import("glinlandui");
const catalog = @import("catalog");

// The command line. `--bench` measures headless; without it the window opens.
const Opts = struct {
    bench: bool = false,
    frames: usize = 300,
    width: u32 = 960,
    height: u32 = 760,
    scale: f32 = 2,
};

fn parseOpts(args: []const []const u8) Opts {
    var opts = Opts{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--bench")) {
            opts.bench = true;
            // `--bench [frames]`: the count is the next token, and a token that is not a number leaves the default standing.
            if (i + 1 < args.len) opts.frames = std.fmt.parseInt(usize, args[i + 1], 10) catch opts.frames;
        } else if (std.mem.startsWith(u8, a, "--size=")) {
            const v = a["--size=".len..];
            if (std.mem.indexOfScalar(u8, v, 'x')) |x| {
                opts.width = std.fmt.parseInt(u32, v[0..x], 10) catch opts.width;
                opts.height = std.fmt.parseInt(u32, v[x + 1 ..], 10) catch opts.height;
            }
        } else if (std.mem.startsWith(u8, a, "--scale=")) {
            opts.scale = std.fmt.parseFloat(f32, a["--scale=".len..]) catch opts.scale;
        }
    }
    return opts;
}

pub fn main(init: std.process.Init) !void {
    const gpa = glinlandui.platform.allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const opts = parseOpts(args);
    if (opts.bench) {
        var threaded: std.Io.Threaded = .init(gpa, .{});
        defer threaded.deinit();
        return bench(gpa, threaded.io(), opts);
    }

    var app = catalog.app.App{};
    app.start();

    var window = glinlandui.Window.init(gpa, .{
        .app_id = "glinlandui-catalog",
        .title = "glinlandui · catalog",
        .width = opts.width,
        .height = opts.height,
        .min_width = 520,
        .min_height = 400,
    });

    // `setContent { ... }`: the Host hands the composable the ctx it was built with.
    var host = try glinlandui.host.Host.init(gpa, &app, catalog.app.App.content);
    defer host.deinit();
    window.delegate = host.delegate();
    try window.run();
}

// The catalog is the toolkit's densest screen, so it is the number that says whether a widget change made the frame budget or broke it.
fn bench(gpa: std.mem.Allocator, io: std.Io, opts: Opts) !void {
    const Driver = glinlandui.testing.Driver;
    var app = catalog.app.App{};
    app.start();
    var driver = try Driver.initOwned(gpa, &app, catalog.app.App.content);
    defer driver.deinit();
    try driver.start(.{ .width = opts.width, .height = opts.height });
    // A real window renders at the display's backing scale; 1x hides half the work the screen actually does.
    glinlandui.software_render.setRenderScale(opts.scale);
    glinlandui.frame.setPixelScale(opts.scale);

    const frames = opts.frames;
    const durations = try gpa.alloc(i64, frames);
    defer gpa.free(durations);

    var i: usize = 0;
    while (i < frames) : (i += 1) {
        const t0 = std.Io.Clock.awake.now(io).nanoseconds;
        driver.frame();
        const t1 = std.Io.Clock.awake.now(io).nanoseconds;
        durations[i] = @intCast(t1 - t0);
    }

    // The first frames pay for the font load and the glyph cache; reporting them as steady state would understate the frame rate by an order of magnitude.
    const warmup = @min(frames, 20);
    const steady = durations[warmup..];
    std.mem.sort(i64, steady, {}, std.sort.asc(i64));
    var total: i64 = 0;
    for (steady) |d| total += d;
    const avg_ms = @as(f32, @floatFromInt(@divTrunc(total, @as(i64, @intCast(steady.len))))) / 1_000_000.0;
    const p95 = @as(f32, @floatFromInt(steady[steady.len * 95 / 100])) / 1_000_000.0;

    std.debug.print(
        "catalog bench: {d} frames at {d}x{d} (scale {d}), cold {d:.1} ms\n  steady avg {d:.2} ms  p95 {d:.2} ms  = {d:.0} fps\n",
        .{ frames, opts.width, opts.height, opts.scale, @as(f32, @floatFromInt(durations[0])) / 1_000_000.0, avg_ms, p95, 1000.0 / avg_ms },
    );
}
