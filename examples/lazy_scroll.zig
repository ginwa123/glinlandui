// glinlandui example: 10,000 rows, virtualised, with a live frame-rate meter. What it is for: a scroll that does not care how much data there is. Only

// the rows that intersect the viewport are declared, with one spacer above and one below so the scrollbar still reports the real content height — so the

// cost of a frame depends on the WINDOW, not on the 10,000 rows behind it. It also measures itself. Every frame records how long the previous one took,

// and the header shows the current rate, the average and the worst over the last two seconds. On a 144 Hz display the budget is 6.9 ms; the meter turns

// red when a frame exceeds it, so a regression is visible rather than felt. Run it:     `zig build run-lazy-scroll`     (window; Space starts the

// auto-scroll, End jumps to the bottom) Measure it: `zig build bench-lazy-scroll`   (headless: scrolls to the bottom and prints the frame times)
const std = @import("std");
const glinlandui = @import("glinlandui");
const Color = glinlandui.Color;

const components = glinlandui.components;
const box_mod = components.box;
const text_mod = components.text;
const button = components.button;
const scroll_mod = components.scroll;
const cl = glinlandui.zclay;
const table = glinlandui.table;

// ---- the data ------------------------------------------------------------------------------------------------

// Ten thousand rows, and none of them is stored: a row is a function of its index. That is the point — the list is free, and the drawing is what costs.
const row_count: usize = 10_000;
// One row's height, taken from the virtualisation helper's own constant so the two cannot disagree.
const row_h: f32 = @floatFromInt(table.row_height);

// ---- palette (app-local; components stay theme-neutral) -------------------------------------------------------

const bg_app = Color.hexC("#101014");
const bg_row = Color.hexC("#141418");
const bg_row_alt = Color.hexC("#18181d");
const bg_head = Color.hexC("#1b1b22");
const fg = Color.hexC("#d8d8dc");
const fg_dim = Color.hexC("#8a8a94");
const fg_ok = Color.hexC("#7fae8a");
const fg_bad = Color.hexC("#c86a6a");
const accent = Color.hexC("#7aa2c4");
const bg_button = Color.hexC("#2b2d36");
const bg_button_hover = Color.hexC("#33363f");

// The frame budget of a 144 Hz display, in milliseconds.
const budget_144_ms: f32 = 1000.0 / 144.0;

// ---- the meter -----------------------------------------------------------------------------------------------

// The last N frame durations, in nanoseconds. `tick` is called at the top of every frame with the clock, so the meter measures what the screen actually

// got, not what the toolkit hoped for.
const Meter = struct {
    const cap = 120;

    durations: [cap]i64 = [_]i64{0} ** cap,
    count: usize = 0,
    next: usize = 0,
    last_ns: i64 = 0,

    fn tick(self: *Meter, now_ns: i64) void {
        if (self.last_ns != 0 and now_ns > self.last_ns) {
            self.durations[self.next] = now_ns - self.last_ns;
            self.next = (self.next + 1) % cap;
            if (self.count < cap) self.count += 1;
        }
        self.last_ns = now_ns;
    }

    const Stats = struct { last_ms: f32 = 0, avg_ms: f32 = 0, max_ms: f32 = 0, fps: f32 = 0 };

    fn stats(self: *const Meter) Stats {
        if (self.count == 0) return .{};
        const last_ms = @as(f32, @floatFromInt(self.durations[(self.next + cap - 1) % cap])) / 1_000_000.0;
        var total: i64 = 0;
        var worst: i64 = 0;
        for (self.durations[0..self.count]) |d| {
            total += d;
            if (d > worst) worst = d;
        }
        const avg_ms = @as(f32, @floatFromInt(@divTrunc(total, @as(i64, @intCast(self.count))))) / 1_000_000.0;
        return .{
            .last_ms = last_ms,
            .avg_ms = avg_ms,
            .max_ms = @as(f32, @floatFromInt(worst)) / 1_000_000.0,
            .fps = if (avg_ms > 0) 1000.0 / avg_ms else 0,
        };
    }
};

// ---- the app -------------------------------------------------------------------------------------------------

const App = struct {
    io: std.Io,
    meter: Meter = .{},
    // Auto-scroll: points per frame to move the list.
    auto: bool = false,
    speed: f32 = 400,
    // Rows declared in the last frame, so the header can show the virtualisation working.
    declared: usize = 0,
    // Print the meter once a second, for a run you cannot watch (a benchmark on a build machine).
    log: bool = false,
    log_next_ns: i64 = 0,
    // Asks the window for another frame. Null in the headless bench, where the driver drives them.
    pump: ?*const fn (?*anyopaque) void = null,
    pump_ctx: ?*anyopaque = null,
    // Turns the pump off when the animation stops, so an idle window does not redraw forever.
    idle: ?*const fn (?*anyopaque) void = null,
    // Frame-scoped text, the way every immediate-mode app needs one for its labels.
    text: [1024 * 1024]u8 = undefined,
    text_used: usize = 0,

    fn claim(self: *App, n: usize) []u8 {
        if (self.text_used + n > self.text.len) return &[_]u8{};
        const s = self.text[self.text_used .. self.text_used + n];
        self.text_used += n;
        return s;
    }

    fn label(self: *App, comptime fmt: []const u8, args: anytype) []const u8 {
        const buf = self.claim(192);
        if (buf.len == 0) return "";
        return std.fmt.bufPrint(buf, fmt, args) catch "";
    }

    fn requestFrame(self: *App) void {
        if (self.pump) |p| p(self.pump_ctx);
    }

    fn stopFrames(self: *App) void {
        if (self.idle) |p| p(self.pump_ctx);
    }

    // Auto-scroll on or off, including the frame pump that keeps it moving.
    fn setAuto(self: *App, on: bool) void {
        self.auto = on;
        if (on) self.requestFrame() else self.stopFrames();
    }

    fn root(ctx: ?*anyopaque, w: u32, h: u32) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        _ = w;
        _ = h;
        self.text_used = 0;
        self.meter.tick(@intCast(std.Io.Clock.awake.now(self.io).nanoseconds));

        const now: i64 = @intCast(std.Io.Clock.awake.now(self.io).nanoseconds);
        if (self.log and now >= self.log_next_ns) {
            self.log_next_ns = now + std.time.ns_per_s;
            const s = self.meter.stats();
            std.debug.print("fps {d: >6.1}  frame {d: >5.2} ms  avg {d: >5.2}  max {d: >6.2}  declared {d}\n", .{
                s.fps, s.last_ms, s.avg_ms, s.max_ms, self.declared,
            });
        }

        // Advance the animation BEFORE declaring, so this frame draws the position it just moved to.
        if (self.auto) {
            scroll_mod.scrollBy("lazy.scroll", 0, self.speed);
            self.requestFrame();
        }

        box_mod.box(.{
            .id = "root",
            .w = .grow,
            .h = .grow,
            .direction = .column,
            .bg = bg_app,
            .gap = 0,
        }, self, rootChildren);
    }

    fn rootChildren(self: *App) void {
        header(self);
        list(self);
        footer(self);
    }
};

// ---- header --------------------------------------------------------------------------------------------------

fn header(self: *App) void {
    box_mod.box(.{
        .id = "header",
        .w = .grow,
        .h = .{ .fixed = 44 },
        .direction = .row,
        .bg = bg_head,
        .pad = 10,
        .gap = 12,
    }, self, headerChildren);
}

fn headerChildren(self: *App) void {
    const s = self.meter.stats();
    text_mod.label(.{ .str = "10,000 rows", .font_size = 14, .color = fg });
    text_mod.label(.{
        .str = self.label("fps {d: >6.1}   frame {d: >5.2} ms   avg {d: >5.2}   max {d: >6.2}", .{
            s.fps, s.last_ms, s.avg_ms, s.max_ms,
        }),
        .font_size = 14,
        // Red the moment the last frame misses a 144 Hz budget, so a regression is visible at a glance.
        .color = if (s.last_ms > budget_144_ms) fg_bad else fg_ok,
    });
    text_mod.label(.{
        .str = self.label("declared {d} of {d}", .{ self.declared, row_count }),
        .font_size = 14,
        .color = fg_dim,
    });
    box_mod.spacer("header.spacer");
    button.button(.{
        .id = "header.auto",
        .label = if (self.auto) "Stop" else "Scroll",
        .font_size = 14,
        .bg = if (self.auto) accent else bg_button,
        .fg = fg,
        .hover_bg = bg_button_hover,
        .pad_tb = 4,
        .pad_lr = 14,
        .on_click = onToggleAuto,
        .ctx = self,
    });
    button.button(.{
        .id = "header.bottom",
        .label = "End",
        .font_size = 14,
        .bg = bg_button,
        .fg = fg,
        .hover_bg = bg_button_hover,
        .pad_tb = 4,
        .pad_lr = 14,
        .on_click = onJumpBottom,
        .ctx = self,
    });
}

fn onToggleAuto(ctx: ?*anyopaque) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    self.setAuto(!self.auto);
}

fn onJumpBottom(ctx: ?*anyopaque) void {
    _ = ctx;
    scroll_mod.scrollBy("lazy.scroll", 0, @as(f32, @floatFromInt(row_count)) * row_h);
}

// ---- the list ------------------------------------------------------------------------------------------------

fn list(self: *App) void {
    scroll_mod.scroll(.{
        .id = "lazy.scroll",
        .direction = .vertical,
        .w = .grow,
        .h = .grow,
        .bg = bg_app,
        .thumb_bg = Color.hexC("#3a3a46"),
        .thumb_hover_bg = accent,
    }, self, listChildren);
}

fn listChildren(self: *App) void {
    // What is on screen decides what is declared. This is the whole trick, and it is four lines.
    const data = cl.getScrollContainerData(cl.getElementId("lazy.scroll"));
    const view_h: f32 = if (data.found) data.scroll_container_dimensions.h else 600;
    // Clay's scroll position is negative going down.
    const scroll_y: f32 = if (data.found) @max(-data.scroll_position.y, 0) else 0;

    const vis = table.visible(.{
        .total_rows = row_count,
        .total_cols = 1,
        .scroll_y = scroll_y,
        .height = view_h,
        .width = 0,
        .overscan = 2,
        .row_height = table.row_height,
    });
    self.declared = vis.row_count;

    // Everything above the viewport is ONE empty rectangle of its exact height: scrolling past ten thousand rows costs a single draw command, and the

    // scrollbar still knows how long the list is.
    if (vis.first_row > 0) {
        box_mod.box(.{
            .id = "lazy.pad.top",
            .w = .grow,
            .h = .{ .fixed = @as(f32, @floatFromInt(vis.first_row)) * row_h },
            .direction = .column,
        }, self, noChildren);
    }

    for (0..vis.row_count) |i| {
        row(self, vis.first_row + i);
    }

    const after = vis.first_row + vis.row_count;
    if (after < row_count) {
        box_mod.box(.{
            .id = "lazy.pad.bottom",
            .w = .grow,
            .h = .{ .fixed = @as(f32, @floatFromInt(row_count - after)) * row_h },
            .direction = .column,
        }, self, noChildren);
    }
}

// One row, declared with raw Clay so its id can be `IDI` (numeric) and its two labels sit inside the same element: ten thousand rows would be ten

// thousand formatted id strings otherwise.
fn row(self: *App, index: usize) void {
    const name = self.label("row {d: >5}", .{index});
    const meta = self.label("user{d}@example.com   {d}.{d:0>2}", .{ index, index % 977, index % 100 });
    cl.UI()(.{
        .id = .IDI("lazy.row", @intCast(index)),
        .layout = .{
            .direction = .left_to_right,
            .sizing = .{ .w = .grow, .h = .fixed(row_h) },
            .padding = .axes(6, 8),
            .child_alignment = .{ .x = .left, .y = .center },
            .child_gap = 16,
        },
        .background_color = (if (cl.hovered()) Color.hexC("#22222c") else if (index % 2 == 0) bg_row else bg_row_alt).toClay(),
    })({
        cl.text(name, .{ .font_size = 13, .color = fg.toClay() });
        cl.text(meta, .{ .font_size = 13, .color = fg_dim.toClay() });
    });
}

fn noChildren(_: *App) void {}

// ---- footer --------------------------------------------------------------------------------------------------

fn footer(self: *App) void {
    box_mod.box(.{
        .id = "footer",
        .w = .grow,
        .h = .{ .fixed = 26 },
        .direction = .row,
        .bg = bg_head,
        .pad = 8,
        .gap = 12,
    }, self, footerChildren);
}

fn footerChildren(self: *App) void {
    _ = self;
    text_mod.label(.{
        .str = "Space scrolls  ·  End jumps  ·  only the visible rows are declared",
        .font_size = 12,
        .color = fg_dim,
    });
}

// ---- keys ----------------------------------------------------------------------------------------------------

// evdev codes, so the handler is the same on every host.
const key_space: u32 = 57;
const key_home: u32 = 102;
const key_end: u32 = 107;

fn onKey(ctx: ?*anyopaque, mods: components.input.Mods, keycode: u32) bool {
    _ = mods;
    const self: *App = @ptrCast(@alignCast(ctx.?));
    const span = @as(f32, @floatFromInt(row_count)) * row_h;
    switch (keycode) {
        key_space => {
            self.setAuto(!self.auto);
            return true;
        },
        key_home => {
            scroll_mod.scrollBy("lazy.scroll", 0, -span);
            return true;
        },
        key_end => {
            scroll_mod.scrollBy("lazy.scroll", 0, span);
            return true;
        },
        else => return false,
    }
}

// ---- the window ----------------------------------------------------------------------------------------------

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

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.page_allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var app = App{ .io = threaded.io() };

    // `--bench [frames]`: no window, no vsync, just the frame the toolkit produces. This is the number that has to fit in 6.9 ms for a 144 Hz display, and

    // it is the one to watch when the renderer changes.
    if (args.len > 1 and std.mem.eql(u8, args[1], "--bench")) {
        const frames: usize = if (args.len > 2) std.fmt.parseInt(usize, args[2], 10) catch 600 else 600;
        var width: u32 = 900;
        var height: u32 = 640;
        var scale: f32 = 1;
        for (args[2..]) |a| {
            if (std.mem.startsWith(u8, a, "--size=")) {
                const v = a["--size=".len..];
                if (std.mem.indexOfScalar(u8, v, 'x')) |x| {
                    width = std.fmt.parseInt(u32, v[0..x], 10) catch width;
                    height = std.fmt.parseInt(u32, v[x + 1 ..], 10) catch height;
                }
            }
            if (std.mem.startsWith(u8, a, "--scale=")) {
                scale = std.fmt.parseFloat(f32, a["--scale=".len..]) catch scale;
            }
        }
        return bench(gpa, &app, frames, width, height, scale);
    }

    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--auto")) app.auto = true;
        if (std.mem.eql(u8, a, "--log")) app.log = true;
    }

    var win_w: u32 = 900;
    var win_h: u32 = 640;
    for (args[1..]) |a| {
        if (std.mem.startsWith(u8, a, "--size=")) {
            const v = a["--size=".len..];
            if (std.mem.indexOfScalar(u8, v, 'x')) |x| {
                win_w = std.fmt.parseInt(u32, v[0..x], 10) catch win_w;
                win_h = std.fmt.parseInt(u32, v[x + 1 ..], 10) catch win_h;
            }
        }
    }

    var window = glinlandui.Window.init(gpa, .{
        .app_id = "glinlandui-lazy-scroll",
        .title = "glinlandui · 10,000 rows",
        .width = win_w,
        .height = win_h,
        .min_width = 480,
        .min_height = 320,
    });
    var host = try glinlandui.host.Host.init(gpa, &app, App.root);
    defer host.deinit();
    host.keys.register(onKey, &app);
    window.delegate = host.delegate();

    app.pump = pumpThroughWindow;
    app.idle = idleThroughWindow;
    app.pump_ctx = &window;
    // `--auto` starts scrolling immediately, and the pump has to be running before the first frame or nothing moves.
    if (app.auto) pumpThroughWindow(&window);
    try window.run();
}

// Render `frames` frames while scrolling, and report the frame times.
fn bench(gpa: std.mem.Allocator, app: *App, frames: usize, width: u32, height: u32, scale: f32) !void {
    const Driver = glinlandui.testing.Driver;
    var driver = try Driver.initOwned(gpa, app, App.root);
    defer driver.deinit();
    try driver.start(.{ .width = width, .height = height });
    // A real window renders at the display's backing scale; 1x hides half the work the screen actually does.
    glinlandui.software_render.setRenderScale(scale);
    glinlandui.frame.setPixelScale(scale);

    app.auto = true;
    app.speed = 600;

    const durations = try gpa.alloc(i64, frames);
    defer gpa.free(durations);

    var cold_ns: i64 = 0;
    var i: usize = 0;
    while (i < frames) : (i += 1) {
        const t0 = std.Io.Clock.awake.now(app.io).nanoseconds;
        driver.frame();
        const t1 = std.Io.Clock.awake.now(app.io).nanoseconds;
        durations[i] = @intCast(t1 - t0);
        if (i == 0) cold_ns = durations[0];
    }

    // The first frames pay for the font load and the glyph cache. Reporting them as steady state would understate the frame rate by an order of magnitude,

    // and hiding them would overstate it — so they are reported separately.
    const warmup = @min(frames, 20);
    const steady = durations[warmup..];
    std.mem.sort(i64, steady, {}, std.sort.asc(i64));
    var total: i64 = 0;
    for (steady) |d| total += d;
    const avg_ms = @as(f32, @floatFromInt(@divTrunc(total, @as(i64, @intCast(steady.len))))) / 1_000_000.0;

    const data = cl.getScrollContainerData(cl.getElementId("lazy.scroll"));
    if (data.found) {
        std.debug.print("  viewport {d:.0} x {d:.0}   content {d:.0}   scroll {d:.0},{d:.0}\n", .{
            data.scroll_container_dimensions.w,
            data.scroll_container_dimensions.h,
            data.content_dimensions.h,
            data.scroll_position.x,
            data.scroll_position.y,
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
    const scroll_y: f32 = if (data.found) data.scroll_position.y else 0;

    std.debug.print(
        \\LAZY SCROLL BENCH  {d} rows, {d} frames, {d}x{d} at {d}x scale
        \\  steady   avg {d: >6.2} ms   p50 {d: >6.2}   p95 {d: >6.2}   p99 {d: >6.2}   max {d: >6.2}   ({d} frames after warm-up)
        \\  cold     first frame {d: >6.2} ms   (font load + glyph cache)
        \\  budget   144 Hz {d: >5.2} ms   60 Hz {d: >5.2} ms
        \\  declared {d} rows per frame
        \\
    , .{
        row_count,
        frames,
        width,
        height,
        scale,
        avg_ms,
        p50_ms,
        p95_ms,
        p99_ms,
        max_ms,
        steady.len,
        cold_ms,
        budget_144_ms,
        1000.0 / 60.0,
        app.declared,
    });

    // One machine-readable line, parsed by ci/check_lazy_scroll_bench.sh on every platform: the work values must match everywhere, the timings must fit the budget.
    std.debug.print(
        "BENCH rows={d} frames={d} size={d}x{d} scale={d:.2} declared={d} scroll_y={d:.0} avg_ms={d:.2} p50_ms={d:.2} p95_ms={d:.2} p99_ms={d:.2} max_ms={d:.2} cold_ms={d:.2}\n",
        .{ row_count, frames, width, height, scale, app.declared, scroll_y, avg_ms, p50_ms, p95_ms, p99_ms, max_ms, cold_ms },
    );
}

// The box of the first declared row, so a bench can prove the rows are on screen and not only declared.
fn ui_row_box(index: usize) ?glinlandui.zclay.BoundingBox {
    const d = glinlandui.zclay.getElementData(glinlandui.zclay.ElementId.IDI("lazy.row", @intCast(index)));
    if (!d.found) return null;
    return d.bounding_box;
}

fn percentile(sorted: []const i64, p: f64) f32 {
    if (sorted.len == 0) return 0;
    const idx = @min(sorted.len - 1, @as(usize, @intFromFloat(@as(f64, @floatFromInt(sorted.len)) * p)));
    return @as(f32, @floatFromInt(sorted[idx])) / 1_000_000.0;
}

test "the meter reports a frame time and a rate" {
    var m = Meter{};
    m.tick(1_000_000);
    m.tick(7_000_000); // 6 ms
    const s = m.stats();
    try std.testing.expectApproxEqAbs(@as(f32, 6.0), s.last_ms, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 6.0), s.avg_ms, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 1000.0 / 6.0), s.fps, 0.5);
}
