//! glinlandui example: a four-function calculator (LINUX ONLY).
//!
//! This example is deliberately gated to Linux. The runtime it targets —
//! Wayland + EGL + GLES3 + pangocairo — is native to Linux in this
//! repository, and the example exercises that real backend. `build.zig`
//! only ever creates the `glinlandui-calculator` executable, the
//! `run-calculator` step and the example's tests when the target OS is
//! Linux; on macOS and every other host none of those artifacts exist, so
//! nothing about this file can affect the cross-platform test-parity
//! contract in `ci/check_test_parity.sh` / `tests.lock`.
//!
//! What it demonstrates, in order of interest:
//!   1. A button grid. Clay has no wrap layout, so the keypad is a column
//!      of fixed-height row boxes, each holding four buttons. Because
//!      `button()` only self-registers when `on_click` is set, the example
//!      passes `on_click = null` and registers one indexed row callback
//!      per key via `click_registry.registerZCursor`. That keeps 20 keys
//!      on a single handler and still gives the pointer cursor.
//!   2. Real keyboard input. App keys arrive through the Host's KeyChain
//!      (`host.keys.register`), NOT through a delegate callback: the Host
//!      consumes `Delegate.on_key` into that chain. Raw evdev keycodes are
//!      mapped to ASCII with `components.input.keyChar`, and the keypad's
//!      own evdev codes cover Enter / Backspace / the arithmetic keypad.
//!   3. State kept out of the draw path. The `Machine` below is a plain,
//!      allocation-free value type with no Clay or glinlandui imports at
//!      all — so the calculator's arithmetic is testable on its own, and
//!      the UI layer only ever reads `display()` / `expression()`.
//!
//! Run it with `zig build run-calculator`. Escape closes the window (the
//! toolkit's own contract). On a headless host with no compositor the
//! window cannot open, so the example falls back to a real software
//! rasterization of the same tree and reports the painted pixel count.
const std = @import("std");
const builtin = @import("builtin");
const glinlandui = @import("glinlandui");

const components = glinlandui.components;
const registry = components.click_registry;
const cl = glinlandui.zclay;

// Linux-only tripwire. The build already refuses to wire this example on
// other hosts; this turns an accidental future reference into a clear
// message instead of a confusing Wayland/link failure.
comptime {
    if (builtin.os.tag != .linux) {
        @compileError("examples/calculator.zig is Linux-only (Wayland/EGL/GLES3/pangocairo); it is wired into build.zig under the `is_linux` branch only.");
    }
}

// ---- Palette (app-local; components stay theme-neutral) ----

const COLOR_BG: u32 = 0x101014;
const COLOR_PANEL: u32 = 0x1b1b21;
const COLOR_FG: u32 = 0xf0f0f5;
const COLOR_DIM: u32 = 0x8a8a99;
const COLOR_ERR: u32 = 0xff6b6b;
const COLOR_DIGIT: u32 = 0x26262e;
const COLOR_DIGIT_HOVER: u32 = 0x33333d;
const COLOR_OP: u32 = 0x3a3a46;
const COLOR_OP_HOVER: u32 = 0x4a4a58;
const COLOR_ACCENT: u32 = 0x2f6df6;
const COLOR_ACCENT_HOVER: u32 = 0x4a82ff;

/// Keypad geometry. Four columns x five rows, fixed-size keys: `box` has
/// no wrap/flex-grow for its children, so the grid is laid out explicitly
/// rather than left to the layout engine.
const cols: usize = 4;
const rows: usize = 5;
const key_w: u32 = 72;
const key_h: u32 = 52;
const key_gap: u32 = 8;

/// Every key, in the order the grid is declared (row-major). The index
/// into this enum IS the click index and the keymap index, so the UI, the
/// pointer path and the keyboard path all agree on one numbering.
pub const Key = enum(u8) {
    clear,
    backspace,
    dot,
    divide,
    k7,
    k8,
    k9,
    times,
    k4,
    k5,
    k6,
    minus,
    k1,
    k2,
    k3,
    plus,
    k0,
    negate,
    percent,
    equals,

    pub const count: usize = @typeInfo(Key).@"enum".fields.len;
};

/// Row-major lookup table: index i (0..19) -> Key.
const KEYS_BY_INDEX: [Key.count]Key = blk: {
    var table: [Key.count]Key = undefined;
    for (&table, 0..) |*slot, i| slot.* = @enumFromInt(i);
    break :blk table;
};

/// Grid labels, ASCII only: the keymap is US-ASCII and a unicode glyph
/// would render as a fallback box in a stub font.
const KEY_LABELS: [Key.count][]const u8 = .{
    "C", "DEL", ".", "/",
    "7", "8",   "9", "*",
    "4", "5",   "6", "-",
    "1", "2",   "3", "+",
    "0", "+/-", "%", "=",
};

/// Stable element ids. Clay resolves `.ID(ptr)` by string, so these must
/// be distinct literals that outlive every frame — a per-frame buffer
/// would rehash the layout tree on each rebuild.
const KEY_IDS: [Key.count][]const u8 = .{
    "calc-k-clear", "calc-k-backspace", "calc-k-dot",     "calc-k-divide",
    "calc-k-7",     "calc-k-8",         "calc-k-9",       "calc-k-times",
    "calc-k-4",     "calc-k-5",         "calc-k-6",       "calc-k-minus",
    "calc-k-1",     "calc-k-2",         "calc-k-3",       "calc-k-plus",
    "calc-k-0",     "calc-k-negate",    "calc-k-percent", "calc-k-equals",
};

const ROW_IDS = [_][]const u8{
    "calc-row-0",
    "calc-row-1",
    "calc-row-2",
    "calc-row-3",
    "calc-row-4",
};

const DISPLAY_H: f32 = 72;

// ---- Arithmetic core ----
//
// `Machine` is deliberately free of any glinlandui/Clay import so the
// whole calculator can be exercised without a compositor, a font engine
// or a GL context.

const Op = enum { add, sub, mul, div };

fn apply(o: Op, a: f64, b: f64) f64 {
    return switch (o) {
        .add => a + b,
        .sub => a - b,
        .mul => a * b,
        .div => a / b,
    };
}

fn symbol(o: Op) []const u8 {
    return switch (o) {
        .add => "+",
        .sub => "-",
        .mul => "*",
        .div => "/",
    };
}

/// Render a computed value into `buf` without allocating. Integral
/// results print without a fractional tail ("5", not "5.0"); everything
/// else falls back to the float formatter.
fn writeValue(buf: []u8, v: f64) []const u8 {
    const rounded = @round(v);
    if (@abs(v - rounded) < 1e-9 and @abs(v) < 1e15) {
        return std.fmt.bufPrint(buf, "{d}", .{@as(i64, @intFromFloat(rounded))}) catch "0";
    }
    return std.fmt.bufPrint(buf, "{d}", .{v}) catch "0";
}

pub const Machine = struct {
    /// Digits currently being typed, as ASCII ("12", "-3.5").
    entry: [32]u8 = undefined,
    entry_len: usize = 0,
    /// Left-hand operand of a pending binary operation.
    accum: f64 = 0,
    pending: ?Op = null,
    /// The next digit starts a fresh entry instead of appending.
    fresh: bool = true,
    /// Latched by a non-finite result (e.g. divide by zero). Cleared by
    /// the next key press.
    err: bool = false,
    /// Scratch for `expression()`.
    accum_buf: [24]u8 = undefined,
    expr_buf: [64]u8 = undefined,

    pub fn init() Machine {
        var self = Machine{};
        self.reset();
        return self;
    }

    /// Back to "0", no operation pending, no error.
    pub fn reset(self: *Machine) void {
        self.entry[0] = '0';
        self.entry_len = 1;
        self.accum = 0;
        self.pending = null;
        self.fresh = true;
        self.err = false;
    }

    /// The big display string. Owned by the machine, valid until the next
    /// mutation — the UI reads it while declaring, exactly like
    /// `statusText` in the main demo.
    pub fn display(self: *const Machine) []const u8 {
        if (self.err) return "ERR";
        return self.entry[0..self.entry_len];
    }

    /// The small "12 +" line above the display; empty when no operation
    /// is pending.
    pub fn expression(self: *Machine) []const u8 {
        const p = self.pending orelse return "";
        const head = writeValue(&self.accum_buf, self.accum);
        return std.fmt.bufPrint(&self.expr_buf, "{s} {s}", .{ head, symbol(p) }) catch "";
    }

    /// Current entry as a number. The entry is always well-formed ASCII
    /// by construction, so a parse failure is impossible; default to 0.
    fn value(self: *const Machine) f64 {
        return std.fmt.parseFloat(f64, self.entry[0..self.entry_len]) catch 0;
    }

    fn fail(self: *Machine) void {
        self.err = true;
        self.pending = null;
        self.fresh = true;
    }

    fn setValue(self: *Machine, v: f64) void {
        const s = writeValue(&self.entry, v);
        self.entry_len = s.len;
    }

    pub fn press(self: *Machine, key: Key) void {
        // Any key clears a latched error first, so the machine is always
        // usable again without a dedicated "dismiss" key.
        if (self.err) self.reset();

        switch (key) {
            .clear => self.reset(),
            .dot => self.dot(),
            .backspace => self.backspace(),
            .negate => self.negate(),
            .percent => self.percent(),
            .equals => self.equals(),
            .divide => self.setOp(.div),
            .times => self.setOp(.mul),
            .minus => self.setOp(.sub),
            .plus => self.setOp(.add),
            else => if (digitValue(key)) |d| self.digit(d),
        }
    }

    /// The digit a digit-key represents, or null for every other key.
    /// Written out rather than derived from the enum value: the grid is
    /// declared row-major ("7 8 9" sits above "0"), so `k0` is the LAST
    /// digit key in the enum, not the first.
    fn digitValue(key: Key) ?u8 {
        return switch (key) {
            .k0 => 0,
            .k1 => 1,
            .k2 => 2,
            .k3 => 3,
            .k4 => 4,
            .k5 => 5,
            .k6 => 6,
            .k7 => 7,
            .k8 => 8,
            .k9 => 9,
            else => null,
        };
    }

    /// Append a digit (0-9 as an offset from the `k0` base).
    fn digit(self: *Machine, d: u8) void {
        if (self.fresh) {
            self.entry_len = 0;
            self.fresh = false;
        }
        if (self.entry_len >= self.entry.len) return;
        self.entry[self.entry_len] = '0' + d;
        self.entry_len += 1;
    }

    fn dot(self: *Machine) void {
        if (self.fresh) {
            self.entry[0] = '0';
            self.entry_len = 1;
            self.fresh = false;
        }
        for (self.entry[0..self.entry_len]) |c| {
            if (c == '.') return; // one decimal point per entry
        }
        if (self.entry_len >= self.entry.len) return;
        self.entry[self.entry_len] = '.';
        self.entry_len += 1;
    }

    fn backspace(self: *Machine) void {
        // Backspacing a just-computed value edits nothing and shows 0.
        if (self.fresh) {
            self.entry[0] = '0';
            self.entry_len = 1;
            return;
        }
        if (self.entry_len > 0) self.entry_len -= 1;
        if (self.entry_len == 0) {
            self.entry[0] = '0';
            self.entry_len = 1;
        }
    }

    /// Toggle a leading '-' in place. The entry is short, so an explicit
    /// shift is clearer than memmove.
    fn negate(self: *Machine) void {
        if (self.fresh) {
            self.entry_len = 0;
            self.fresh = false;
        }
        if (self.entry_len == 0) {
            self.entry[0] = '0';
            self.entry_len = 1;
        }
        if (self.entry[0] == '-') {
            var i: usize = 1;
            while (i < self.entry_len) : (i += 1) self.entry[i - 1] = self.entry[i];
            self.entry_len -= 1;
        } else {
            if (self.entry_len >= self.entry.len) return;
            var i: usize = self.entry_len + 1;
            while (i > 1) : (i -= 1) self.entry[i - 1] = self.entry[i - 2];
            self.entry[0] = '-';
            self.entry_len += 1;
        }
    }

    fn percent(self: *Machine) void {
        self.setValue(self.value() / 100.0);
        self.fresh = true;
    }

    /// Start (or replace) a pending operation, folding in the left
    /// operand. Typing two operators in a row replaces the first.
    fn setOp(self: *Machine, o: Op) void {
        if (self.pending) |p| {
            if (!self.fresh) {
                const r = apply(p, self.accum, self.value());
                if (!std.math.isFinite(r)) return self.fail();
                self.accum = r;
                self.setValue(r);
            }
        } else {
            self.accum = self.value();
        }
        self.pending = o;
        self.fresh = true;
    }

    fn equals(self: *Machine) void {
        if (self.pending) |p| {
            const r = apply(p, self.accum, self.value());
            if (!std.math.isFinite(r)) return self.fail();
            self.accum = r;
            self.setValue(r);
        }
        self.pending = null;
        self.fresh = true;
    }

    /// Keyboard path: a printable ASCII character from the keymap.
    /// Unknown characters are ignored (the caller still consumed the key).
    pub fn feedChar(self: *Machine, c: u8) void {
        switch (c) {
            '0'...'9' => self.digit(c - '0'),
            '+' => self.press(.plus),
            '-' => self.press(.minus),
            '*' => self.press(.times),
            '/' => self.press(.divide),
            '=' => self.press(.equals),
            '.' => self.press(.dot),
            '%' => self.press(.percent),
            'c', 'C' => self.press(.clear),
            else => {},
        }
    }
};

/// Keypad keys that the evdev code does not produce as printable ASCII.
const KEY_KP_ENTER: u32 = 96;
const KEY_KP_PLUS: u32 = 78;
const KEY_KP_MINUS: u32 = 74;
const KEY_KP_MULTIPLY: u32 = 55;
const KEY_KP_DIVIDE: u32 = 98;

/// Button fill for a key: digits neutral, operators tinted, `=` accented.
fn tint(key: Key) struct { bg: u32, hover_bg: u32 } {
    return switch (key) {
        .divide, .times, .minus, .plus => .{ .bg = COLOR_OP, .hover_bg = COLOR_OP_HOVER },
        .equals => .{ .bg = COLOR_ACCENT, .hover_bg = COLOR_ACCENT_HOVER },
        else => .{ .bg = COLOR_DIGIT, .hover_bg = COLOR_DIGIT_HOVER },
    };
}

// ---- App ----

const App = struct {
    m: Machine = Machine.init(),

    /// Press one key and report it as consumed.
    fn pressKey(self: *App, key: Key) bool {
        self.m.press(key);
        return true;
    }

    /// Host KeyChain handler (see `dispatch.handleKey`): returns true when
    /// the key was consumed. Escape is deliberately NOT consumed — the
    /// toolkit's own `keyToClose` contract uses it to quit the window.
    fn onKey(ctx: ?*anyopaque, mods: components.input.Mods, keycode: u32) bool {
        const self: *App = @ptrCast(@alignCast(ctx.?));

        if (components.input.keyChar(keycode, mods.shift)) |c| {
            self.m.feedChar(c);
            return true;
        }
        return switch (keycode) {
            KEY_KP_ENTER, components.input.KEY_ENTER => self.pressKey(.equals),
            components.input.KEY_BACKSPACE,
            components.input.KEY_DELETE,
            => self.pressKey(.backspace),
            KEY_KP_PLUS => self.pressKey(.plus),
            KEY_KP_MINUS => self.pressKey(.minus),
            KEY_KP_MULTIPLY => self.pressKey(.times),
            KEY_KP_DIVIDE => self.pressKey(.divide),
            else => false,
        };
    }

    /// The Clay declare callback: everything drawing happens here.
    fn root(ctx: ?*anyopaque, _: u32, _: u32) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        components.box.box(.{
            .id = "calc-root",
            .direction = .column,
            .w = .grow,
            .h = .grow,
            .bg = COLOR_BG,
            .pad = 12,
            .gap = 10,
        }, self, App.children);
    }

    fn children(self: *App) void {
        const expr = self.m.expression();
        if (expr.len > 0) {
            components.text.label(.{
                .str = expr,
                .font_size = 14,
                .color = COLOR_DIM,
            });
        }
        components.box.box(.{
            .id = "calc-display",
            .w = .grow,
            .h = .{ .fixed = DISPLAY_H },
            .bg = COLOR_PANEL,
            .radius = 10,
            .pad = 12,
            .child_align = .{ .x = .right, .y = .center },
        }, self, App.displayChildren);
        components.box.column(.{
            .id = "calc-keys",
            .w = .grow,
            .h = .grow,
            .gap = @intCast(key_gap),
        }, self, App.keysChildren);
    }

    fn displayChildren(self: *App) void {
        components.text.label(.{
            .str = self.m.display(),
            .font_size = 34,
            .color = if (self.m.err) COLOR_ERR else COLOR_FG,
        });
    }

    fn keysChildren(self: *App) void {
        var r: usize = 0;
        while (r < rows) : (r += 1) {
            // `box`'s children callback is a comptime `fn(@TypeOf(ctx))`,
            // so ctx must be a pointer for the type to dedupe at comptime.
            var rc = RowCtx{ .app = self, .row = r };
            components.box.row(.{
                .id = ROW_IDS[r],
                .w = .grow,
                .h = .{ .fixed = @floatFromInt(key_h) },
                .gap = @intCast(key_gap),
            }, &rc, rowChildren);
        }
    }
};

/// One keypad row. `row` picks the four keys, so a single callback covers
/// all five rows. Passed by pointer (see keysChildren).
const RowCtx = struct {
    app: *App,
    row: usize,
};

fn rowChildren(ctx: *RowCtx) void {
    var c: usize = 0;
    while (c < cols) : (c += 1) {
        const i = ctx.row * cols + c;
        const key = KEYS_BY_INDEX[i];
        const fill = tint(key);
        components.button.button(.{
            .id = KEY_IDS[i],
            .label = KEY_LABELS[i],
            .font_size = 18,
            .w = key_w,
            .h = key_h,
            .radius = 10,
            .pad_tb = 0,
            .pad_lr = 0,
            .bg = fill.bg,
            .hover_bg = fill.hover_bg,
            // on_click stays null so button() does not self-register: the
            // indexed registration below carries the key index instead.
        });
        // One handler for all 20 keys: dispatch passes the grid index.
        registry.registerZCursor(
            cl.getElementId(KEY_IDS[i]),
            onKeyPress,
            ctx.app,
            i,
            0,
            .pointer,
        );
    }
}

fn onKeyPress(ctx: ?*anyopaque, index: usize) void {
    const self: *App = @ptrCast(@alignCast(ctx.?));
    self.m.press(KEYS_BY_INDEX[index]);
}

pub fn main() !void {
    // The Clay arena outlives run() and is process-lifetime, so the page
    // allocator matches the harness convention (see testing/root.zig).
    const alloc = std.heap.page_allocator;

    var app = App{};
    var host = try glinlandui.host.Host.init(alloc, &app, App.root);
    defer host.deinit();

    // Keys reach the app through the Host's chain, not the delegate.
    host.keys.register(App.onKey, &app);

    var window = glinlandui.Window.init(.{
        .app_id = "glinlandui-calculator",
        .title = "glinlandui - calculator",
        .width = 360,
        // 425 is the measured content height at its tallest (expression
        // line shown: keys end at y=412.8 + 12px padding); 430 leaves a
        // few pixels of slack so the window never clips the keypad.
        .height = 430,
        .min_width = 360,
        .min_height = 430,
    });
    window.delegate = host.delegate();

    // On a live compositor this opens a real Wayland window and blocks
    // until closed. Headless (CI, no GUI session) the window cannot open;
    // that is an expected environment, not a failure, so render the same
    // tree through the software rasterizer instead.
    window.run() catch |err| {
        std.debug.print(
            "window unavailable ({s}); rendering headless instead\n",
            .{@errorName(err)},
        );
        try renderHeadless(&host, 360, 440);
    };
}

/// Render one real frame through the normal frame path into a software
/// surface and report how many pixels were drawn. Used when no display is
/// available, so the example still exercises and proves the renderer.
fn renderHeadless(host: *glinlandui.host.Host, w: u32, h: u32) !void {
    const soft = glinlandui.software_render;
    var renderer = try soft.Renderer.init(std.heap.page_allocator);
    defer renderer.deinit();

    var opt = glinlandui.frame.FrameOptions{};
    const commands = try captureCommands(host, w, h, &opt);
    renderer.surface.resize(w, h) catch return error.InvalidSize;
    renderer.surface.clear();
    renderer.surface.renderCommands(commands);

    const clear = renderer.surface.clear_rgb;
    var painted: usize = 0;
    var i: usize = 0;
    while (i + 3 < renderer.surface.pixels.len) : (i += 4) {
        const r = @as(f32, @floatFromInt(renderer.surface.pixels[i]));
        const g = @as(f32, @floatFromInt(renderer.surface.pixels[i + 1]));
        const b = @as(f32, @floatFromInt(renderer.surface.pixels[i + 2]));
        if (r != clear[0] or g != clear[1] or b != clear[2]) painted += 1;
    }
    std.debug.print(
        "glinlandui calculator rendered {d}x{d} headless ({d} painted pixels, no display available)\n",
        .{ w, h, painted },
    );
}

/// Run one frame and hand back the emitted render commands via the frame
/// probe. The slice is owned by the Clay arena, valid for this frame only.
fn captureCommands(
    host: *glinlandui.host.Host,
    w: u32,
    h: u32,
    opt: *glinlandui.frame.FrameOptions,
) ![]const glinlandui.zclay.RenderCommand {
    const Sink = struct {
        var commands: []const glinlandui.zclay.RenderCommand = &.{};
        fn probe(_: ?*anyopaque, cmds: []const glinlandui.zclay.RenderCommand, _: u32, _: u32) void {
            commands = cmds;
        }
    };
    opt.probe = Sink.probe;
    opt.probe_user_data = null;
    _ = host.frameWithOptions(w, h, opt);
    return Sink.commands;
}

// ---- Tests ----
//
// These run in the Linux-only `native-test` step (wired from build.zig),
// never in the cross-platform parity `test` step — adding a test to the
// parity roots would change the count in tests.lock on every platform.

test "example keypad grid covers every key exactly once" {
    try std.testing.expectEqual(@as(usize, 20), Key.count);
    try std.testing.expectEqual(Key.count, cols * rows);
    // Row-major: the UI, the click index and the keymap share one index.
    try std.testing.expectEqual(Key.clear, KEYS_BY_INDEX[0]);
    try std.testing.expectEqual(Key.k7, KEYS_BY_INDEX[4]);
    try std.testing.expectEqual(Key.k0, KEYS_BY_INDEX[16]);
    try std.testing.expectEqual(Key.equals, KEYS_BY_INDEX[19]);
    // Every label and element id is present and distinct.
    for (KEY_LABELS, 0..) |label, i| {
        try std.testing.expect(label.len > 0);
        try std.testing.expect(!std.mem.eql(u8, label, ""));
        _ = i;
    }
    for (KEY_IDS, 0..) |id, i| {
        for (KEY_IDS[0..i]) |prev| {
            try std.testing.expect(!std.mem.eql(u8, id, prev));
        }
    }
}

test "digits accumulate into one entry" {
    var m = Machine.init();
    try std.testing.expectEqualStrings("0", m.display());
    m.press(.k1);
    m.press(.k2);
    m.press(.k3);
    try std.testing.expectEqualStrings("123", m.display());
}

test "a new digit after a result starts a fresh entry" {
    var m = Machine.init();
    m.press(.k5);
    m.press(.plus);
    m.press(.k5);
    m.press(.equals);
    try std.testing.expectEqualStrings("10", m.display());
    m.press(.k7);
    try std.testing.expectEqualStrings("7", m.display());
}

test "all four operations fold left" {
    const Case = struct { keys: []const Key, want: []const u8 };
    const cases = [_]Case{
        .{ .keys = &.{ .k2, .plus, .k3, .equals }, .want = "5" },
        .{ .keys = &.{ .k9, .minus, .k4, .equals }, .want = "5" },
        .{ .keys = &.{ .k3, .times, .k4, .equals }, .want = "12" },
        .{ .keys = &.{ .k8, .divide, .k2, .equals }, .want = "4" },
        // 2 + 3 * 4 evaluates as (2+3)*4 when operators fold immediately.
        .{ .keys = &.{ .k2, .plus, .k3, .times, .k4, .equals }, .want = "20" },
    };
    for (cases) |c| {
        var m = Machine.init();
        for (c.keys) |k| m.press(k);
        try std.testing.expectEqualStrings(c.want, m.display());
    }
}

test "integral results print without a fractional tail" {
    var m = Machine.init();
    m.press(.k1);
    m.press(.dot);
    m.press(.k5);
    m.press(.plus);
    m.press(.k1);
    m.press(.dot);
    m.press(.k5);
    m.press(.equals);
    try std.testing.expectEqualStrings("3", m.display());
}

test "fractional results keep their fraction" {
    var m = Machine.init();
    m.press(.k1);
    m.press(.divide);
    m.press(.k4);
    m.press(.equals);
    try std.testing.expectEqualStrings("0.25", m.display());
}

test "only one decimal point per entry" {
    var m = Machine.init();
    m.press(.k1);
    m.press(.dot);
    m.press(.dot);
    m.press(.k5);
    try std.testing.expectEqualStrings("1.5", m.display());
}

test "a leading dot starts the entry at zero" {
    var m = Machine.init();
    m.press(.dot);
    m.press(.k5);
    try std.testing.expectEqualStrings("0.5", m.display());
}

test "divide by zero latches an error that the next key clears" {
    var m = Machine.init();
    m.press(.k5);
    m.press(.divide);
    m.press(.k0);
    m.press(.equals);
    try std.testing.expect(m.err);
    try std.testing.expectEqualStrings("ERR", m.display());

    // The next key press recovers instead of leaving a dead machine.
    m.press(.k7);
    try std.testing.expect(!m.err);
    try std.testing.expectEqualStrings("7", m.display());
}

test "clear resets entry, operand and pending operation" {
    var m = Machine.init();
    m.press(.k8);
    m.press(.plus);
    m.press(.k8);
    m.press(.clear);
    try std.testing.expectEqualStrings("0", m.display());
    try std.testing.expectEqual(@as(?Op, null), m.pending);
    m.press(.k1);
    try std.testing.expectEqualStrings("1", m.display());
}

test "equals is idempotent with no pending operation" {
    var m = Machine.init();
    m.press(.k4);
    m.press(.equals);
    try std.testing.expectEqualStrings("4", m.display());
    m.press(.equals);
    try std.testing.expectEqualStrings("4", m.display());
}

test "typing two operators in a row replaces the first" {
    var m = Machine.init();
    m.press(.k8);
    m.press(.plus);
    m.press(.times);
    m.press(.k3);
    m.press(.equals);
    try std.testing.expectEqualStrings("24", m.display());
}

test "negate toggles the sign in place" {
    var m = Machine.init();
    m.press(.k4);
    m.press(.k2);
    m.press(.negate);
    try std.testing.expectEqualStrings("-42", m.display());
    m.press(.negate);
    try std.testing.expectEqualStrings("42", m.display());
    m.press(.negate);
    m.press(.plus);
    m.press(.k1);
    m.press(.equals);
    try std.testing.expectEqualStrings("-41", m.display());
}

test "percent divides the entry by a hundred" {
    var m = Machine.init();
    m.press(.k5);
    m.press(.k0);
    m.press(.percent);
    try std.testing.expectEqualStrings("0.5", m.display());
}

test "backspace edits the entry and never empties it" {
    var m = Machine.init();
    m.press(.k1);
    m.press(.k2);
    m.press(.k3);
    m.press(.backspace);
    try std.testing.expectEqualStrings("12", m.display());
    m.press(.backspace);
    m.press(.backspace);
    try std.testing.expectEqualStrings("0", m.display());
    m.press(.backspace);
    try std.testing.expectEqualStrings("0", m.display());
}

test "the entry is bounded, so a huge run of digits cannot overflow" {
    var m = Machine.init();
    var i: usize = 0;
    while (i < 100) : (i += 1) m.press(.k9);
    try std.testing.expect(m.entry_len <= m.entry.len);
    try std.testing.expect(m.entry.len > 0);
}

test "the keyboard path drives the same machine as the keypad" {
    var m = Machine.init();
    for ("12+30") |c| m.feedChar(c);
    m.feedChar('=');
    try std.testing.expectEqualStrings("42", m.display());
}

test "keyboard clear, percent, backspace and divide all reach the machine" {
    var m = Machine.init();
    for ("50") |c| m.feedChar(c);
    m.feedChar('%');
    try std.testing.expectEqualStrings("0.5", m.display());

    m.feedChar('/');
    m.feedChar('2');
    m.feedChar('=');
    try std.testing.expectEqualStrings("0.25", m.display());

    m.feedChar('c');
    try std.testing.expectEqualStrings("0", m.display());
}

test "unknown keyboard characters leave the machine untouched" {
    var m = Machine.init();
    m.press(.k7);
    m.feedChar('q');
    try std.testing.expectEqualStrings("7", m.display());
}

test "the expression line shows the pending operation" {
    var m = Machine.init();
    try std.testing.expectEqualStrings("", m.expression());
    m.press(.k1);
    m.press(.k2);
    m.press(.plus);
    try std.testing.expectEqualStrings("12 +", m.expression());
    m.press(.equals);
    try std.testing.expectEqualStrings("", m.expression());
}

test "the expression line reports the folded operand, not the entry" {
    var m = Machine.init();
    m.press(.k2);
    m.press(.plus);
    m.press(.k3);
    m.press(.times);
    try std.testing.expectEqualStrings("5 *", m.expression());
}

test "keyChar maps the calculator's printable keycodes" {
    // 0-9 live on the evdev digits row (2..11), '*' is evdev 55.
    try std.testing.expectEqual(@as(?u8, '7'), components.input.keyChar(8, false));
    try std.testing.expectEqual(@as(?u8, '0'), components.input.keyChar(11, false));
    try std.testing.expectEqual(@as(?u8, '/'), components.input.keyChar(53, false));
    try std.testing.expectEqual(@as(?u8, '.'), components.input.keyChar(52, false));
    // '*' is NOT in keyChar's table: evdev 55 is the keypad '*', so it is
    // routed by onKey's KEY_KP_MULTIPLY arm instead (covered below).
    try std.testing.expectEqual(@as(?u8, null), components.input.keyChar(KEY_KP_MULTIPLY, false));
    try std.testing.expectEqual(@as(?u8, '+'), components.input.keyChar(13, true));
    // Non-printables (Enter, Backspace, Escape) are handled by the owner.
    try std.testing.expectEqual(@as(?u8, null), components.input.keyChar(components.input.KEY_ENTER, false));
    try std.testing.expectEqual(@as(?u8, null), components.input.keyChar(components.input.KEY_BACKSPACE, false));
}

test "Escape is left unconsumed so the window can still close" {
    // wayland.keyToClose accepts the raw evdev code 1 and keysym 0xff1b.
    const escape_evdev: u32 = 1;
    try std.testing.expect(glinlandui.keyToClose(escape_evdev));
    var app = App{};
    // onKey routes through the KeyChain, which tracks modifiers first and
    // then asks each handler. Escape reaches no handler.
    try std.testing.expect(!App.onKey(&app, .{}, escape_evdev));
    try std.testing.expectEqualStrings("0", app.m.display());
}

test "onKey drives the machine through the Host KeyChain" {
    var app = App{};
    // Enter, Backspace and the arithmetic keypad are non-ASCII keycodes,
    // so they only work via onKey — not via keyChar.
    try std.testing.expect(App.onKey(&app, .{}, components.input.KEY_ENTER));
    try std.testing.expectEqualStrings("0", app.m.display());

    // evdev 8 is the "7" key; type it twice through the chain.
    try std.testing.expect(App.onKey(&app, .{}, 8));
    try std.testing.expect(App.onKey(&app, .{}, 8));
    try std.testing.expectEqualStrings("77", app.m.display());
    try std.testing.expect(App.onKey(&app, .{}, components.input.KEY_BACKSPACE));
    try std.testing.expectEqualStrings("7", app.m.display());

    try std.testing.expect(App.onKey(&app, .{}, KEY_KP_MULTIPLY));
    try std.testing.expect(App.onKey(&app, .{}, KEY_KP_PLUS));
    try std.testing.expect(App.onKey(&app, .{}, KEY_KP_MINUS));
    try std.testing.expect(App.onKey(&app, .{}, KEY_KP_DIVIDE));
    try std.testing.expect(App.onKey(&app, .{}, KEY_KP_ENTER));
}

test "a keypad click and the same key press agree" {
    var app = App{};
    // row 3 col 0 is index 12 -> "1"; row 1 col 0 is index 4 -> "7".
    onKeyPress(&app, 12);
    onKeyPress(&app, 4);
    try std.testing.expectEqualStrings("17", app.m.display());
    // And the machine agrees with the label under that index.
    try std.testing.expectEqualStrings("1", KEY_LABELS[12]);
    try std.testing.expectEqualStrings("7", KEY_LABELS[4]);
}

test "declaring the app emits the display, every key and the row boxes" {
    const Rec = struct {
        var rects: usize = 0;
        var texts: usize = 0;
        fn probe(_: ?*anyopaque, cmds: []const glinlandui.zclay.RenderCommand, _: u32, _: u32) void {
            for (cmds) |c| switch (c.command_type) {
                .rectangle => rects += 1,
                .text => texts += 1,
                else => {},
            };
        }
    };
    const alloc = std.heap.page_allocator;
    var app = App{};
    // NOTE: no `host.deinit()` here. Clay keeps a process-global pointer
    // into the arena that deinit frees, so the next Host.init() would read
    // a dangling currentContext and segfault in Clay_MinMemorySize. The
    // page-allocator arena is intentionally left alive for the rest of the
    // test process — exactly what testing/root.zig's Driver.deinit does.
    var host = try glinlandui.host.Host.init(alloc, &app, App.root);
    host.keys.register(App.onKey, &app);

    var opt = glinlandui.frame.FrameOptions{};
    opt.probe = Rec.probe;
    opt.probe_user_data = null;
    _ = host.frameWithOptions(360, 440, &opt);

    // 20 buttons + root + display = 22 rects (the display is opaque; the
    // row boxes are transparent and emit nothing).
    try std.testing.expectEqual(@as(usize, 22), Rec.rects);
    // One label per button + the display value; the expression line is
    // empty until an operation is pending.
    try std.testing.expectEqual(@as(usize, 21), Rec.texts);
}

test "a click on a declared key fires its indexed handler" {
    const alloc = std.heap.page_allocator;
    var app = App{};
    // NOTE: no `host.deinit()` here. Clay keeps a process-global pointer
    // into the arena that deinit frees, so the next Host.init() would read
    // a dangling currentContext and segfault in Clay_MinMemorySize. The
    // page-allocator arena is intentionally left alive for the rest of the
    // test process — exactly what testing/root.zig's Driver.deinit does.
    var host = try glinlandui.host.Host.init(alloc, &app, App.root);
    host.keys.register(App.onKey, &app);
    host.frame(360, 440);

    // Click the "7" key (row 1, col 0) at its own center, the same way
    // dispatch.pointerEvent does on a release.
    const eid = cl.getElementId(KEY_IDS[4]);
    const data = cl.getElementData(eid);
    try std.testing.expect(data.found);
    const bb = data.bounding_box;
    try std.testing.expect(registry.dispatchClick(
        bb.x + bb.width * 0.5,
        bb.y + bb.height * 0.5,
    ));
    try std.testing.expectEqualStrings("7", app.m.display());

    // And the whole keypad is a registered, cursor-bearing hit target.
    try std.testing.expectEqual(
        registry.Cursor.pointer,
        registry.hoverCursorAt(bb.x + bb.width * 0.5, bb.y + bb.height * 0.5),
    );
}

test "the keypad lays out as five rows of four, without overlap" {
    const alloc = std.heap.page_allocator;
    var app = App{};
    // NOTE: no `host.deinit()` here. Clay keeps a process-global pointer
    // into the arena that deinit frees, so the next Host.init() would read
    // a dangling currentContext and segfault in Clay_MinMemorySize. The
    // page-allocator arena is intentionally left alive for the rest of the
    // test process — exactly what testing/root.zig's Driver.deinit does.
    var host = try glinlandui.host.Host.init(alloc, &app, App.root);
    host.frame(360, 440);

    for (KEY_IDS, 0..) |id, i| {
        const data = cl.getElementData(cl.getElementId(id));
        try std.testing.expect(data.found);
        const bb = data.bounding_box;
        // Fixed-size keys inside the window.
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(key_w)), bb.width, 1.0);
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(key_h)), bb.height, 1.0);
        // Grid position matches the declared order: column = i % cols.
        const col = i % cols;
        const row = i / cols;
        if (col > 0) {
            const left = cl.getElementData(cl.getElementId(KEY_IDS[i - 1])).bounding_box;
            // Same row, strictly to the right of its left neighbour.
            try std.testing.expect(bb.x > left.x);
            try std.testing.expectApproxEqAbs(left.y, bb.y, 0.01);
            try std.testing.expectApproxEqAbs(
                @as(f32, @floatFromInt(key_gap)),
                bb.x - (left.x + left.width),
                1.0,
            );
        }
        if (row > 0) {
            const above = cl.getElementData(cl.getElementId(KEY_IDS[i - cols])).bounding_box;
            try std.testing.expect(bb.y > above.y);
        }
    }
}

// ---- Reactivity: the rendered view must follow the machine ----
//
// The tests above prove that a callback fires and that the machine
// mutates. Those are two halves of a contract; the third half is that the
// NEXT frame actually shows the new state. The helpers below read the
// real render commands straight off the Host's normal frame path, so
// these assertions are on the pixels the compositor would receive, not on
// the machine's own fields.

/// Font sizes make the display, the expression line and the key labels
/// unambiguous inside one frame's command list.
const render = glinlandui.render;

/// `cl.Color` is `[4]f32`, which has no `==`/`!=` operator, so
/// inequality goes through an element-wise compare.
fn colorDiffers(a: cl.Color, b: cl.Color) bool {
    for (a, b) |x, y| {
        if (x != y) return true;
    }
    return false;
}

const DISPLAY_FONT: u16 = 34;
const EXPR_FONT: u16 = 14;

fn cmdText(cmd: cl.RenderCommand) ?[]const u8 {
    const td = cmd.render_data.text;
    return td.string_contents.chars[0..@intCast(td.string_contents.length)];
}

/// The big display string as the view emits it (null when absent).
fn displayString(cmds: []const cl.RenderCommand) ?[]const u8 {
    for (cmds) |c| {
        if (c.command_type != .text) continue;
        const td = c.render_data.text;
        if (td.font_size == DISPLAY_FONT) return cmdText(c);
    }
    return null;
}

/// The "12 +" line, which the view omits entirely when no operation is
/// pending — so its presence is itself a reactive signal.
fn expressionString(cmds: []const cl.RenderCommand) ?[]const u8 {
    for (cmds) |c| {
        if (c.command_type != .text) continue;
        const td = c.render_data.text;
        if (td.font_size == EXPR_FONT) return cmdText(c);
    }
    return null;
}

fn displayColor(cmds: []const cl.RenderCommand) ?cl.Color {
    for (cmds) |c| {
        if (c.command_type != .text) continue;
        const td = c.render_data.text;
        if (td.font_size == DISPLAY_FONT) return td.text_color;
    }
    return null;
}

fn textCount(cmds: []const cl.RenderCommand) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < cmds.len) : (i += 1) {
        if (cmds[i].command_type == .text) n += 1;
    }
    return n;
}

/// Fill color of the rectangle belonging to keypad key `index`.
fn keyFill(cmds: []const cl.RenderCommand, index: usize) ?cl.Color {
    for (cmds) |c| {
        if (c.command_type != .rectangle) continue;
        if (c.id == cl.getElementId(KEY_IDS[index]).id) {
            return c.render_data.rectangle.background_color;
        }
    }
    return null;
}

const Capture = struct {
    var cmds: []const cl.RenderCommand = &.{};

    fn probe(_: ?*anyopaque, c: []const cl.RenderCommand, _: u32, _: u32) void {
        cmds = c;
    }
};

/// Run one frame through the Host's normal path and return its commands.
/// NOTE: the returned slice is owned by the Clay arena and stays valid
/// only until the next frame — assert before calling again.
fn drawFrame(host: *glinlandui.host.Host) []const cl.RenderCommand {
    var opt = glinlandui.frame.FrameOptions{};
    opt.probe = Capture.probe;
    opt.probe_user_data = null;
    _ = host.frameWithOptions(360, 440, &opt);
    return Capture.cmds;
}

test "the view shows 0 before any input" {
    const alloc = std.heap.page_allocator;
    var app = App{};
    var host = try glinlandui.host.Host.init(alloc, &app, App.root);
    const cmds = drawFrame(&host);
    try std.testing.expectEqualStrings("0", displayString(cmds).?);
    // No operation pending, so the expression line is not declared.
    try std.testing.expect(expressionString(cmds) == null);
    try std.testing.expectEqual(@as(usize, 21), textCount(cmds));
}

test "typing updates the display the view renders" {
    const alloc = std.heap.page_allocator;
    var app = App{};
    var host = try glinlandui.host.Host.init(alloc, &app, App.root);

    try std.testing.expectEqualStrings("0", displayString(drawFrame(&host)).?);

    // Each keystroke must be visible in the very next frame.
    for ([_]u8{ '1', '2', '3' }) |c| {
        _ = App.onKey(@ptrCast(&app), .{}, switch (c) {
            '1' => 2,
            '2' => 3,
            '3' => 4,
            else => unreachable,
        });
        const want = switch (c) {
            '1' => "1",
            '2' => "12",
            else => "123",
        };
        try std.testing.expectEqualStrings(want, displayString(drawFrame(&host)).?);
    }
}

test "the expression line appears and disappears with the pending operation" {
    const alloc = std.heap.page_allocator;
    var app = App{};
    var host = try glinlandui.host.Host.init(alloc, &app, App.root);

    // Fresh: no expression line, so one text per key + one display.
    try std.testing.expectEqual(@as(usize, 21), textCount(drawFrame(&host)));

    for ("12") |c| app.m.feedChar(c);
    app.m.feedChar('+');
    const pending = drawFrame(&host);
    // One EXTRA text command appears purely because state changed.
    try std.testing.expectEqual(@as(usize, 22), textCount(pending));
    try std.testing.expectEqualStrings("12 +", expressionString(pending).?);
    try std.testing.expectEqualStrings("12", displayString(pending).?);

    app.m.feedChar('=');
    const done = drawFrame(&host);
    // Consuming the operation removes it from the view again. The right
    // operand is the still-displayed "12", so this is 12 + 12 = 24.
    try std.testing.expectEqual(@as(usize, 21), textCount(done));
    try std.testing.expect(expressionString(done) == null);
    try std.testing.expectEqualStrings("24", displayString(done).?);
}

test "a computed result replaces the display, and the operand line follows" {
    const alloc = std.heap.page_allocator;
    var app = App{};
    var host = try glinlandui.host.Host.init(alloc, &app, App.root);
    for ("12345") |c| app.m.feedChar(c);
    app.m.feedChar('*');
    app.m.feedChar('2');
    app.m.feedChar('=');
    const cmds = drawFrame(&host);
    // 12345 * 2 folds to 24690 — a five-digit result the view must show.
    try std.testing.expectEqualStrings("24690", displayString(cmds).?);
    try std.testing.expect(expressionString(cmds) == null);
}

test "divide by zero turns the display red in the next frame" {
    const alloc = std.heap.page_allocator;
    var app = App{};
    var host = try glinlandui.host.Host.init(alloc, &app, App.root);
    const healthy = displayColor(drawFrame(&host)).?;
    try std.testing.expectEqual(render.u32ToClayColor(COLOR_FG), healthy);

    for ("50") |c| app.m.feedChar(c);
    app.m.feedChar('/');
    app.m.feedChar('0');
    app.m.feedChar('=');
    const broken = drawFrame(&host);
    // Both the text AND its color are reactive to the error latch.
    try std.testing.expectEqualStrings("ERR", displayString(broken).?);
    try std.testing.expectEqual(render.u32ToClayColor(COLOR_ERR), displayColor(broken).?);
    try std.testing.expect(colorDiffers(displayColor(broken).?, healthy));
}

test "a keypad click is visible in the next frame" {
    const alloc = std.heap.page_allocator;
    var app = App{};
    var host = try glinlandui.host.Host.init(alloc, &app, App.root);
    host.frame(360, 440);

    // Press "7" the way dispatch.pointerEvent does, then redraw.
    const bb = cl.getElementData(cl.getElementId(KEY_IDS[4])).bounding_box;
    try std.testing.expect(registry.dispatchClick(bb.x + bb.width * 0.5, bb.y + bb.height * 0.5));
    try std.testing.expectEqualStrings("7", displayString(drawFrame(&host)).?);

    // Then "8", one column right, on a freshly laid-out frame.
    const bb8 = cl.getElementData(cl.getElementId(KEY_IDS[5])).bounding_box;
    try std.testing.expect(registry.dispatchClick(bb8.x + bb8.width * 0.5, bb8.y + bb8.height * 0.5));
    try std.testing.expectEqualStrings("78", displayString(drawFrame(&host)).?);
}

test "the keypad repaints on hover as the pointer moves" {
    const alloc = std.heap.page_allocator;
    var app = App{};
    var host = try glinlandui.host.Host.init(alloc, &app, App.root);

    // Frame 1: pointer far away, so every key shows its resting fill.
    host.onPointerEvent(-1, -1, false, 0);
    const resting = drawFrame(&host);
    const rest_8 = keyFill(resting, 5).?;
    try std.testing.expectEqual(render.u32ToClayColor(COLOR_DIGIT), rest_8);
    const rest_eq = keyFill(resting, 19).?;
    try std.testing.expectEqual(render.u32ToClayColor(COLOR_ACCENT), rest_eq);

    // Frame 2: pointer over the "8" key, whose box is known from frame 1.
    const bb8 = cl.getElementData(cl.getElementId(KEY_IDS[5])).bounding_box;
    host.onPointerEvent(bb8.x + bb8.width * 0.5, bb8.y + bb8.height * 0.5, false, 0);
    const hovered = drawFrame(&host);
    // Only the hovered key changes fill; its neighbours do not.
    try std.testing.expectEqual(render.u32ToClayColor(COLOR_DIGIT_HOVER), keyFill(hovered, 5).?);
    try std.testing.expect(colorDiffers(keyFill(hovered, 5).?, rest_8));
    try std.testing.expectEqual(rest_8, keyFill(hovered, 4).?);
    try std.testing.expectEqual(rest_8, keyFill(hovered, 6).?);
    try std.testing.expectEqual(rest_eq, keyFill(hovered, 19).?);
}

test "the operators keep their tint across a state change" {
    const alloc = std.heap.page_allocator;
    var app = App{};
    var host = try glinlandui.host.Host.init(alloc, &app, App.root);
    host.onPointerEvent(-1, -1, false, 0);
    const before = drawFrame(&host);

    for ("8+8") |c| app.m.feedChar(c);
    app.m.feedChar('=');
    const after = drawFrame(&host);

    // The state change must not disturb the static key chrome: a
    // regression here would mean the grid rebuilds wrong when a value
    // lands on the display.
    for (0..Key.count) |i| {
        try std.testing.expectEqual(keyFill(before, i), keyFill(after, i));
    }
    try std.testing.expectEqual(render.u32ToClayColor(COLOR_OP), keyFill(after, 3).?); // "/"
    try std.testing.expectEqual(render.u32ToClayColor(COLOR_OP), keyFill(after, 15).?); // "+"
    try std.testing.expectEqual(render.u32ToClayColor(COLOR_ACCENT), keyFill(after, 19).?); // "="
    try std.testing.expectEqualStrings("16", displayString(after).?);
}
