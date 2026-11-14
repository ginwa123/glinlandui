// The entry point: `MainActivity`, and the headless bench. Everything else is the module.
// It parses the flags, builds the window and the Host, and contains the benchmark nobody can watch.
const std = @import("std");
const glinlandui = @import("glinlandui");
const scroll_mod = glinlandui.components.scroll;
const lazy = @import("lazy_scroll");

// The pump: ask the window for another frame while an animation is running.
fn pumpThroughWindow(ctx: ?*anyopaque) void {
    const window: *glinlandui.Window = @ptrCast(@alignCast(ctx.?));
    if (@hasDecl(glinlandui.Window, "setAnimating")) window.setAnimating(true);
}

// Stop asking for frames, so an idle window goes quiet again.
fn idleThroughWindow(ctx: ?*anyopaque) void {
    const window: *glinlandui.Window = @ptrCast(@alignCast(ctx.?));
    if (@hasDecl(glinlandui.Window, "setAnimating")) window.setAnimating(false);
}

// The command line. `--bench` runs the headless measurement; without it the window opens.
const Opts = struct {
    bench: bool = false,
    frames: usize = 600,
    width: u32 = 900,
    height: u32 = 640,
    scale: f32 = 1,
    auto: bool = false,
    log: bool = false,
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
        } else if (std.mem.eql(u8, a, "--auto")) {
            opts.auto = true;
        } else if (std.mem.eql(u8, a, "--log")) {
            opts.log = true;
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
    const gpa = std.heap.page_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const opts = parseOpts(args);

    // `--bench [frames]`: no window, no vsync, just the frame the toolkit produces. This is the number that has to fit in 6.9 ms for a 144 Hz display,
    // and it is the one to watch when the renderer changes.
    if (opts.bench) return bench(gpa, io, opts);

    var app = lazy.app.App{ .io = io };
    var window = glinlandui.Window.init(gpa, .{
        .app_id = "glinlandui-lazy-scroll",
        .title = "glinlandui · 10,000 rows",
        .width = opts.width,
        .height = opts.height,
        .min_width = 480,
        .min_height = 320,
    });
    // `setContent { ... }`: the Host hands the composable the ctx it was built with.
    var host = try glinlandui.host.Host.init(gpa, &app, lazy.app.App.content);
    defer host.deinit();
    window.delegate = host.delegate();

    // Space, Home and End are the screen's intents, so the handler is the model's and the window's events reach it through here.
    host.keys.register(lazy.view_model.LazyViewModel.onKey, app.vm());
    app.pump = .{ .ctx = &window, .request = pumpThroughWindow, .idle = idleThroughWindow };
    app.start();

    if (opts.log) app.vm().log = true;
    // `--auto` starts scrolling immediately, and the pump has to be running before the first frame or nothing moves.
    if (opts.auto) app.vm().toggleAuto();
    try window.run();
}

// Render `frames` frames while scrolling, and report the frame times.
fn bench(gpa: std.mem.Allocator, io: std.Io, opts: Opts) !void {
    const Driver = glinlandui.testing.Driver;
    var app = lazy.app.App{ .io = io };
    // No pump: the driver produces the frames, and no window exists to be asked for one.
    app.start();
    var driver = try Driver.initOwned(gpa, &app, lazy.app.App.content);
    defer driver.deinit();
    try driver.start(.{ .width = opts.width, .height = opts.height });
    // A real window renders at the display's backing scale; 1x hides half the work the screen actually does.
    glinlandui.software_render.setRenderScale(opts.scale);
    glinlandui.frame.setPixelScale(opts.scale);

    const model = app.vm();
    model.toggleAuto();
    model.setSpeed(600);

    const frames = opts.frames;
    const durations = try gpa.alloc(i64, frames);
    defer gpa.free(durations);

    var cold_ns: i64 = 0;
    var i: usize = 0;
    while (i < frames) : (i += 1) {
        const t0 = std.Io.Clock.awake.now(io).nanoseconds;
        driver.frame();
        const t1 = std.Io.Clock.awake.now(io).nanoseconds;
        durations[i] = @intCast(t1 - t0);
        if (i == 0) cold_ns = durations[0];
    }

    // The first frames pay for the font load and the glyph cache. Reporting them as steady state would understate the frame rate by an order of
    // magnitude, and hiding them would overstate it — so they are reported separately.
    const warmup = @min(frames, 20);
    const steady = durations[warmup..];
    std.mem.sort(i64, steady, {}, std.sort.asc(i64));
    var total: i64 = 0;
    for (steady) |d| total += d;
    const avg_ms = @as(f32, @floatFromInt(@divTrunc(total, @as(i64, @intCast(steady.len))))) / 1_000_000.0;

    const v = scroll_mod.view(lazy.view_model.scroll_id);
    if (v.found) {
        std.debug.print("  viewport {d:.0} x {d:.0}   content {d:.0}   scroll {d:.0},{d:.0}\n", .{
            v.width,
            v.height,
            v.content_height,
            -v.x,
            -v.y,
        });
    }
    if (ui_row_box(0)) |b| {
        std.debug.print("  row 0 box {d:.0},{d:.0} {d:.0}x{d:.0}\n", .{ b.x, b.y, b.width, b.height });
    } else {
        std.debug.print("  row 0 is NOT in the element tree\n", .{});
    }

    const p50_ms = percentile(steady, 0.50);
    const p95_ms = percentile(steady, 0.95);
    const p99_ms = percentile(steady, 0.99);
    const max_ms = percentile(steady, 1.0);
    const cold_ms = @as(f32, @floatFromInt(cold_ns)) / 1_000_000.0;
    // The offset the run ended at: the work every CI platform must reproduce, because the scroll path is frame-count driven, not clock driven.
    const scroll_y: f32 = -v.y;

    std.debug.print(
        \\LAZY SCROLL BENCH  {d} rows, {d} frames, {d}x{d} at {d}x scale
        \\  steady   avg {d: >6.2} ms   p50 {d: >6.2}   p95 {d: >6.2}   p99 {d: >6.2}   max {d: >6.2}   ({d} frames after warm-up)
        \\  cold     first frame {d: >6.2} ms   (font load + glyph cache)
        \\  budget   144 Hz {d: >5.2} ms   60 Hz {d: >5.2} ms
        \\  declared {d} rows per frame
        \\
    , .{
        lazy.state.row_count,
        frames,
        opts.width,
        opts.height,
        opts.scale,
        avg_ms,
        p50_ms,
        p95_ms,
        p99_ms,
        max_ms,
        steady.len,
        cold_ms,
        lazy.state.budget_144_ms,
        1000.0 / 60.0,
        model.uiState().declared,
    });

    // One machine-readable line, parsed by ci/check_lazy_scroll_bench.sh on every platform: the work values must match everywhere, the timings must fit the budget.
    std.debug.print(
        "BENCH rows={d} frames={d} size={d}x{d} scale={d:.2} declared={d} scroll_y={d:.0} avg_ms={d:.2} p50_ms={d:.2} p95_ms={d:.2} p99_ms={d:.2} max_ms={d:.2} cold_ms={d:.2}\n",
        .{ lazy.state.row_count, frames, opts.width, opts.height, opts.scale, model.uiState().declared, scroll_y, avg_ms, p50_ms, p95_ms, p99_ms, max_ms, cold_ms },
    );
}

// The box of the first declared row, so a bench can prove the rows are on screen and not only declared.
fn ui_row_box(index: usize) ?glinlandui.frame.Bounds {
    const id = glinlandui.frame.elementId("lazy.row", index);
    return glinlandui.frame.bounds(glinlandui.frame.clayId(id));
}

fn percentile(sorted: []const i64, p: f64) f32 {
    if (sorted.len == 0) return 0;
    const idx = @min(sorted.len - 1, @as(usize, @intFromFloat(@as(f64, @floatFromInt(sorted.len)) * p)));
    return @as(f32, @floatFromInt(sorted[idx])) / 1_000_000.0;
}
