//! The terminal window: alternate screen, raw mode, resize polling and the frame loop, shared by every console.
const std = @import("std");
const contract = @import("../core/window_contract.zig");
const frame_mod = @import("../core/frame.zig");
const text_face = @import("../core/text_face.zig");
const soft = @import("../core/render_software.zig");
const term = @import("term.zig");
const input = @import("input.zig");
const renderer = @import("renderer.zig");
const kitty = @import("kitty.zig");

/// What a headless run reports: the size it laid out at, and how many cells carried a glyph.
pub const Headless = struct {
    width: u32,
    height: u32,
    painted_pixels: usize,
};

// Alternate screen on, cursor hidden, SGR mouse and bracketed paste on: the four things a frame needs from the terminal.
const enter_screen = "\x1b[?1049h\x1b[?25l\x1b[?1000h\x1b[?1002h\x1b[?1006h\x1b[?2004h\x1b[2J\x1b[H";
// The exact inverse, and it runs on every exit path: a terminal left in raw mode is a broken terminal.
const leave_screen = "\x1b[?2004l\x1b[?1006l\x1b[?1002l\x1b[?1000l\x1b[?25h\x1b[?1049l\x1b[0m";

/// The base64 payload of a single-chunk kitty escape, which is what the probe sends.
fn payloadOf(escape: []const u8) []const u8 {
    const semi = std.mem.indexOfScalar(u8, escape, ';') orelse return "";
    const end = if (std.mem.lastIndexOf(u8, escape, "\x1b\\")) |i| i else escape.len;
    if (end <= semi + 1) return "";
    return escape[semi + 1 .. end];
}

const key_ctrl: u32 = 29;
const key_c: u32 = 46;
const key_q: u32 = 16;

const capture_cap: usize = 64 * 1024;
const Capture = struct {
    alloc: std.mem.Allocator,
    buf: [capture_cap]u8 = undefined,
    len: usize = 0,
    overflow: std.ArrayList(u8) = .empty,
    failed: bool = false,

    fn append(self: *Capture, bytes: []const u8) bool {
        if (self.failed) return false;
        var rest = bytes;
        if (self.overflow.items.len == 0) {
            const n = @min(rest.len, self.buf.len - self.len);
            @memcpy(self.buf[self.len..][0..n], rest[0..n]);
            self.len += n;
            rest = rest[n..];
            if (rest.len == 0) return true;
        }
        self.overflow.appendSlice(self.alloc, rest) catch {
            self.failed = true;
            return false;
        };
        return true;
    }

    fn deinit(self: *Capture) void {
        self.overflow.deinit(self.alloc);
    }
};

fn appendToBuffer(ctx: ?*anyopaque, bytes: []const u8) void {
    const buf: *Capture = @ptrCast(@alignCast(ctx.?));
    buf.append(bytes);
}

/// A window over one console implementation: `console` must expose open/enableRaw/disableRaw/size/read/write/close.
pub fn Window(comptime console: type) type {
    return struct {
        const Self = @This();

        // The renderer's sink needs a plain function, and this is the only place the console's concrete type exists.
        const console_write = struct {
            fn write(ctx: ?*anyopaque, bytes: []const u8) void {
                const con: *console.Console = @ptrCast(@alignCast(ctx.?));
                con.write(bytes);
            }
        }.write;

        alloc: std.mem.Allocator,
        config: contract.WindowConfig,
        delegate: ?contract.Delegate = null,
        state: contract.WindowState,
        decoder: input.Decoder = .{},
        size: term.Size = .{},
        ctrl: bool = false,

        pub fn init(alloc: std.mem.Allocator, config: contract.WindowConfig) Self {
            return .{
                .alloc = alloc,
                .config = config,
                .state = contract.WindowState.init(config),
                .size = term.sanitise(.{ .cols = 80, .rows = 24 }),
            };
        }

        pub fn clamp(self: *Self, w: u32, h: u32) struct { w: u32, h: u32 } {
            return self.state.clamp(w, h);
        }

        /// The layout box the terminal currently offers, in points: whole cells, never a guess.
        pub fn layoutSize(self: *const Self) struct { w: u32, h: u32 } {
            return .{ .w = term.layoutWidth(self.size.cols), .h = term.layoutHeight(self.size.rows) };
        }

        fn inputSink(self: *Self) input.Sink {
            return .{
                .ctx = self,
                .key = onKey,
                .text = onText,
                .pointer = onPointer,
                .scroll = onScroll,
            };
        }

        fn onKey(ctx: ?*anyopaque, code: u32, pressed: bool) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            if (code == key_ctrl) self.ctrl = pressed;
            // A terminal has no window manager: Ctrl+C and Ctrl+Q are the two keys that always get you out.
            if (pressed and self.ctrl and (code == key_c or code == key_q)) {
                self.state.quit = true;
                return;
            }
            if (self.delegate) |d| {
                if (d.on_key(d.ptr, code, pressed)) self.state.quit = true;
            }
            self.state.needs_draw = true;
        }

        fn onText(ctx: ?*anyopaque, bytes: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            if (self.delegate) |d| {
                if (d.on_text) |f| f(d.ptr, bytes);
            }
            self.state.needs_draw = true;
        }

        fn onPointer(ctx: ?*anyopaque, x: i32, y: i32, pressed: bool, button: u32) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            if (self.delegate) |d| {
                d.on_pointer(d.ptr, @floatFromInt(x), @floatFromInt(y), pressed, button);
            }
            self.state.needs_draw = true;
        }

        fn onScroll(ctx: ?*anyopaque, dx: f32, dy: f32) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            if (self.delegate) |d| {
                if (d.on_scroll) |f| f(d.ptr, dx, dy);
            }
            self.state.needs_draw = true;
        }

        /// Ask the terminal whether it inflates zlib payloads (`o=z`), which is what makes a full frame tens of KB.
        fn probeCompression(con: *console.Console, alloc: std.mem.Allocator) bool {
            const env = term.libcEnv();
            if (env.get(env.ctx, "GLIN_TUI_COMPRESS")) |v| {
                if (std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "off")) return false;
                if (std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "on")) return true;
            }
            // A 1x1 query (`a=q`, `q=1`): a terminal that can inflate answers `ESC _ G i=99 ; OK ESC \`.
            const rgba = [_]u8{ 0, 0, 0, 255 };
            const image = kitty.encodedRegion(alloc, &rgba, 1, 1, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, 1, 1, 99, .zlib) catch return false;
            defer alloc.free(image);
            var query: [512]u8 = undefined;
            const q = std.fmt.bufPrint(&query, "\x1b_Ga=q,f=24,s=1,v=1,i=99,q=1,o=z;{s}\x1b\\", .{payloadOf(image)}) catch return false;
            con.write(q);
            const deadline = con.nowUs() + 150_000;
            var buf: [256]u8 = undefined;
            while (con.nowUs() < deadline) {
                const n = con.read(&buf, 20) catch 0;
                if (n == 0) continue;
                if (std.mem.indexOf(u8, buf[0..n], "OK") != null) return true;
                if (std.mem.indexOf(u8, buf[0..n], "\x1b_G") != null and std.mem.indexOf(u8, buf[0..n], "OK") == null) return false;
            }
            return false;
        }

        /// Open the terminal and drive frames until the app quits. A process with no tty gets `error.NotATerminal`.
        pub fn run(self: *Self) !void {
            var con = try console.Console.open();
            defer con.close();
            try con.enableRaw();
            defer con.disableRaw();
            const env = term.libcEnv();
            const plan = term.plan(env);
            // A cell frame is laid out in whole cells; a pixel frame keeps real glyph metrics, or the raster quantises twice.
            if (plan.mode == .cells) text_face.setCellMetrics(.{ .w = @floatFromInt(term.cell_w), .h = @floatFromInt(term.cell_h) });
            defer text_face.setCellMetrics(null);
            self.size = con.size() orelse term.sanitise(.{ .cols = 80, .rows = 24 });
            self.state.win_w = term.layoutWidth(self.size.cols);
            self.state.win_h = term.layoutHeight(self.size.rows);
            const compress = if (plan.mode == .kitty) probeCompression(&con, self.alloc) else false;
            const attached = renderer.Attach{
                .sink = .{ .ctx = &con, .write = console_write },
                .cols = self.size.cols,
                .rows = self.size.rows,
                .mode = plan.mode,
                .depth = plan.depth,
                .px_w = self.size.px_w,
                .px_h = self.size.px_h,
                .compress = compress,
            };
            // Before the first layout, never after: the measure and the raster must agree on the device scale.
            soft.setRenderScale(renderer.scaleFor(attached));
            renderer.attach(attached);
            defer renderer.deinitFrameText(self.alloc);
            con.write(enter_screen);
            defer con.write(leave_screen);
            const sink = self.inputSink();
            const max_frames = contract.parseTestFrames(env.get(env.ctx, "QS_SETTINGS_TEST_FRAMES"));
            // `GLIN_TUI_STATS=1` prints one line per frame: how long it took and how many bytes it put on the wire.
            const stats = env.get(env.ctx, "GLIN_TUI_STATS") != null;
            var frames: u32 = 0;
            var idle: u32 = 0;
            var buf: [1024]u8 = undefined;
            while (!self.state.quit) {
                if (self.delegate) |d| {
                    if (d.is_quit(d.ptr)) break;
                }
                if (max_frames) |n| {
                    if (frames >= n) break;
                }
                // A screen that changed with no event to carry it (a route, a load that finished) asked for this frame.
                if (frame_mod.takeRepaintRequest()) self.state.needs_draw = true;
                if (self.state.needs_draw) {
                    self.state.needs_draw = false;
                    const started = if (stats) con.nowUs() else 0;
                    if (self.delegate) |d| d.on_frame(d.ptr, self.state.win_w, self.state.win_h);
                    frames += 1;
                    if (stats) {
                        const us = con.nowUs() - started;
                        std.debug.print("tui frame {d}: {d:.2} ms, {d} bytes, {d}x{d} cells, tier {s}\n", .{
                            frames,
                            @as(f64, @floatFromInt(us)) / 1000.0,
                            renderer.lastBytes(),
                            self.state.win_w / term.cell_w,
                            self.state.win_h / term.cell_h,
                            @tagName(renderer.tierNow()),
                        });
                    }
                    continue;
                }
                const n = con.read(&buf, if (max_frames != null) 0 else 33) catch 0;
                if (n > 0) {
                    idle = 0;
                    self.decoder.feed(buf[0..n], sink);
                    continue;
                }
                self.decoder.idle(sink);
                idle += 1;
                // Half a second of nothing: one frame, so a blinking caret keeps blinking and a resize is noticed.
                if (idle >= 15) {
                    idle = 0;
                    self.state.needs_draw = true;
                }
                if (con.size()) |sz| {
                    if (sz.cols != self.size.cols or sz.rows != self.size.rows) {
                        self.size = sz;
                        self.state.win_w = term.layoutWidth(sz.cols);
                        self.state.win_h = term.layoutHeight(sz.rows);
                        if (self.delegate) |d| d.on_resize(d.ptr, self.state.win_w, self.state.win_h);
                        self.state.needs_draw = true;
                    }
                }
            }
        }

        /// Lay out one real frame at a nominal terminal size and paint it into a buffer: what a CI runner with no tty can check.
        pub fn renderHeadless(self: *Self) !Headless {
            const cols: u16 = 80;
            const rows: u16 = 24;
            const w = term.layoutWidth(cols);
            const h = term.layoutHeight(rows);
            text_face.setCellMetrics(.{ .w = @floatFromInt(term.cell_w), .h = @floatFromInt(term.cell_h) });
            defer text_face.setCellMetrics(null);
            var buf = Capture{ .alloc = self.alloc };
            defer buf.deinit();
            renderer.attach(.{
                .sink = .{ .ctx = &buf, .write = appendToBuffer },
                .cols = cols,
                .rows = rows,
                .mode = .cells,
                .depth = .truecolor,
                .capture_text = true,
            });
            const d = self.delegate orelse return .{ .width = w, .height = h, .painted_pixels = 0 };
            d.on_frame(d.ptr, w, h);
            if (buf.failed) return error.OutOfMemory;
            var painted: usize = 0;
            for (buf.buf[0..buf.len]) |b| {
                if (b > ' ' and b < 0x7f) painted += 1;
            }
            for (buf.overflow.items) |b| {
                if (b > ' ' and b < 0x7f) painted += 1;
            }
            return .{ .width = w, .height = h, .painted_pixels = painted };
        }
    };
}

test "headless capture keeps nominal output in fixed storage without allocating" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var capture = Capture{ .alloc = failing.allocator() };
    defer capture.deinit();
    try std.testing.expect(capture.append("hello"));
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expectEqualSlices(u8, "hello", capture.buf[0..capture.len]);
}

test "headless capture spills larger output to the caller allocator and frees it" {
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var capture = Capture{ .alloc = counting.allocator() };
    var released = false;
    errdefer if (!released) capture.deinit();
    const chunk = [_]u8{'x'} ** 1024;
    for (0..65) |_| try std.testing.expect(capture.append(&chunk));
    try std.testing.expectEqual(@as(usize, capture_cap), capture.len);
    try std.testing.expectEqual(@as(usize, chunk.len), capture.overflow.items.len);
    try std.testing.expect(counting.allocations > 0);
    try std.testing.expectEqualSlices(u8, &chunk, capture.overflow.items);
    capture.deinit();
    released = true;
    try std.testing.expectEqual(counting.allocations, counting.deallocations);
}

test "headless capture reports overflow allocation failure instead of dropping bytes" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var capture = Capture{ .alloc = failing.allocator() };
    defer capture.deinit();
    const full = [_]u8{'x'} ** capture_cap;
    try std.testing.expect(capture.append(&full));
    try std.testing.expect(!capture.append("overflow"));
    try std.testing.expect(capture.failed);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
}
