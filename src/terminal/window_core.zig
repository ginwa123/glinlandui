//! The terminal window: alternate screen, raw mode, resize polling and the frame loop, shared by every console.
const std = @import("std");
const contract = @import("../core/window_contract.zig");
const text_face = @import("../core/text_face.zig");
const soft = @import("../core/render_software.zig");
const term = @import("term.zig");
const input = @import("input.zig");
const renderer = @import("renderer.zig");

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

const key_ctrl: u32 = 29;
const key_c: u32 = 46;
const key_q: u32 = 16;

fn appendToBuffer(ctx: ?*anyopaque, bytes: []const u8) void {
    const buf: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx.?));
    buf.appendSlice(std.heap.page_allocator, bytes) catch {};
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
            const attached = renderer.Attach{
                .sink = .{ .ctx = &con, .write = console_write },
                .cols = self.size.cols,
                .rows = self.size.rows,
                .mode = plan.mode,
                .depth = plan.depth,
                .px_w = self.size.px_w,
                .px_h = self.size.px_h,
            };
            // Before the first layout, never after: the measure and the raster must agree on the device scale.
            soft.setRenderScale(renderer.scaleFor(attached));
            renderer.attach(attached);
            defer renderer.deinitFrameText(self.alloc);
            con.write(enter_screen);
            defer con.write(leave_screen);
            const sink = self.inputSink();
            const max_frames = contract.parseTestFrames(env.get(env.ctx, "QS_SETTINGS_TEST_FRAMES"));
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
                if (self.state.needs_draw) {
                    self.state.needs_draw = false;
                    if (self.delegate) |d| d.on_frame(d.ptr, self.state.win_w, self.state.win_h);
                    frames += 1;
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
            var buf = std.ArrayList(u8){};
            defer buf.deinit(self.alloc);
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
            var painted: usize = 0;
            for (buf.items) |b| {
                if (b > ' ' and b < 0x7f) painted += 1;
            }
            return .{ .width = w, .height = h, .painted_pixels = painted };
        }
    };
}
