// The View: pure declaration from the state.
// Nothing here writes the model: a key raises an intent on the ViewModel and the next frame draws whatever the model says.
const std = @import("std");
const glinlandui = @import("glinlandui");
const Color = glinlandui.Color;

const components = glinlandui.components;
const props = glinlandui.props;
const registry = components.click_registry;
const frame = glinlandui.frame;

const state_mod = @import("state.zig");
const view_model = @import("view_model.zig");

const CalculatorViewModel = view_model.CalculatorViewModel;

// ---- Palette (app-local; components stay theme-neutral) ----

const COLOR_BG = Color.hexC("#101014");
const COLOR_PANEL = Color.hexC("#1b1b21");
const COLOR_FG = Color.hexC("#f0f0f5");
const COLOR_DIM = Color.hexC("#8a8a99");
const COLOR_ERR = Color.hexC("#ff6b6b");
const COLOR_DIGIT = Color.hexC("#26262e");
const COLOR_DIGIT_HOVER = Color.hexC("#33333d");
const COLOR_OP = Color.hexC("#3a3a46");
const COLOR_OP_HOVER = Color.hexC("#4a4a58");
const COLOR_ACCENT = Color.hexC("#2f6df6");
const COLOR_ACCENT_HOVER = Color.hexC("#4a82ff");

/// Keypad geometry. Four columns x five rows, fixed-size keys: `box` has no wrap/flex-grow for its children, so the grid is laid out explicitly rather than left to the layout engine.
const key_w: u32 = 72;
const key_h: u32 = 52;
const key_gap: u32 = 8;

const ROW_IDS = [_][]const u8{
    "calc-row-0",
    "calc-row-1",
    "calc-row-2",
    "calc-row-3",
    "calc-row-4",
};

const DISPLAY_H: f32 = 72;

/// Font sizes make the display, the expression line and the key labels unambiguous inside one frame's command list.
const DISPLAY_FONT: u16 = 34;
const EXPR_FONT: u16 = 14;

/// What a composable reads: the model, and nothing else. The machine, its scratch buffers and the click context all live there, because dispatch runs after the declare returns.
pub const Scope = struct {
    vm: *CalculatorViewModel,
};

// The Clay root for this screen, with the MODEL as ctx: the Activity's `content` looks the model up in the store and calls `show`, and the view's own tests drive the same tree through this.
pub fn root(ctx: ?*anyopaque, w: u32, h: u32) void {
    _ = w;
    _ = h;
    const vm: *CalculatorViewModel = @ptrCast(@alignCast(ctx.?));
    show(vm);
}

// `setContent { CalculatorScreen() }`, minus the store lookup.
pub fn show(vm: *CalculatorViewModel) void {
    var scope = Scope{ .vm = vm };
    CalculatorScreen(&scope);
}

// `@Composable fun CalculatorScreen()`
pub fn CalculatorScreen(scope: *Scope) void {
    components.box.box(.{
        .id = .{ .text = "calc-root" },
        .direction = .column,
        .w = .grow,
        .h = .grow,
        .bg = COLOR_BG,
        .pad = props.Pad.all(12),
        .gap = 10,
    }, scope, children);
}

fn children(scope: *Scope) void {
    const expr = scope.vm.expression();
    if (expr.len > 0) {
        components.text.label(.{
            .label = .{ .text = expr, .size = EXPR_FONT, .color = COLOR_DIM },
        });
    }
    components.box.box(.{
        .id = .{ .text = "calc-display" },
        .w = .grow,
        .h = .{ .fixed = DISPLAY_H },
        .bg = COLOR_PANEL,
        .radius = props.Radius.all(10),
        .pad = props.Pad.all(12),
        .child_align = .{ .x = .right, .y = .center },
    }, scope, displayChildren);
    components.box.column(.{
        .id = .{ .text = "calc-keys" },
        .w = .grow,
        .h = .grow,
        .gap = @intCast(key_gap),
    }, scope, keysChildren);
}

fn displayChildren(scope: *Scope) void {
    components.text.label(.{
        .label = .{ .text = scope.vm.display(), .size = DISPLAY_FONT, .color = if (scope.vm.hasError()) COLOR_ERR else COLOR_FG },
    });
}

fn keysChildren(scope: *Scope) void {
    var r: usize = 0;
    while (r < state_mod.rows) : (r += 1) {
        // The row callback runs INSIDE `box.row`, so a stack context outlives it; only the CLICK contexts must outlive the frame.
        var rc = RowCtx{ .vm = scope.vm, .row = r };
        components.box.row(.{
            .id = .{ .text = ROW_IDS[r] },
            .w = .grow,
            .h = .{ .fixed = @floatFromInt(key_h) },
            .gap = @intCast(key_gap),
        }, &rc, rowChildren);
    }
}

/// One keypad row. `row` picks the four keys, so a single callback covers all five rows. Passed by pointer, which is what lets the comptime child-callback type dedupe.
const RowCtx = struct {
    vm: *CalculatorViewModel,
    row: usize,
};

fn rowChildren(ctx: *RowCtx) void {
    var c: usize = 0;
    while (c < state_mod.cols) : (c += 1) {
        const i = ctx.row * state_mod.cols + c;
        const key = state_mod.KEYS_BY_INDEX[i];
        const fill = tint(key);
        components.button.button(.{
            .id = .{ .text = state_mod.KEY_IDS[i] },
            .label = .{ .text = state_mod.KEY_LABELS[i], .size = 18 },
            .w = .{ .fixed = @floatFromInt(key_w) },
            .h = .{ .fixed = @floatFromInt(key_h) },
            .radius = props.Radius.all(10),
            .pad = .{},
            .bg = fill.bg,
            .hover_bg = fill.hover_bg,
            // on_click stays null so button() does not self-register: the indexed registration below carries the key index.
        });
        // One handler for all twenty keys: dispatch passes the grid index, and the context is the model because a click lands after this frame is gone.
        registry.registerZCursor(
            frame.clayId(state_mod.KEY_IDS[i]),
            onKeyPress,
            ctx.vm,
            i,
            0,
            .pointer,
        );
    }
}

fn onKeyPress(ctx: ?*anyopaque, index: usize) void {
    const vm: *CalculatorViewModel = @ptrCast(@alignCast(ctx.?));
    vm.pressIndex(index);
}

/// Button fill for a key: digits neutral, operators tinted, `=` accented.
pub fn tint(key: state_mod.Key) struct { bg: Color, hover_bg: Color } {
    return switch (key) {
        .divide, .times, .minus, .plus => .{ .bg = COLOR_OP, .hover_bg = COLOR_OP_HOVER },
        .equals => .{ .bg = COLOR_ACCENT, .hover_bg = COLOR_ACCENT_HOVER },
        else => .{ .bg = COLOR_DIGIT, .hover_bg = COLOR_DIGIT_HOVER },
    };
}

// ---- tests ---------------------------------------------------------------------------------------------------
//
// These are part of the cross-platform PARITY suite: they compile and run identically on Linux and macOS, so `ci/check_test_parity.sh` counts them on both. They read the real render commands off the Host's normal frame path — the text backend resolves to the deterministic estimator in every test build, so the command stream is the same on both platforms.

/// `[4]f32` is `[4]f32`, which has no `==`/`!=` operator, so inequality goes through an element-wise compare.
fn colorDiffers(a: [4]f32, b: [4]f32) bool {
    for (a, b) |x, y| {
        if (x != y) return true;
    }
    return false;
}

fn cmdText(cmd: glinlandui.RenderCommand) ?[]const u8 {
    const td = cmd.render_data.text;
    return td.string_contents.chars[0..@intCast(td.string_contents.length)];
}

/// The big display string as the view emits it (null when absent).
fn displayString(cmds: []const glinlandui.RenderCommand) ?[]const u8 {
    for (cmds) |c| {
        if (c.command_type != .text) continue;
        const td = c.render_data.text;
        if (td.font_size == DISPLAY_FONT) return cmdText(c);
    }
    return null;
}

/// The "12 +" line, which the view omits entirely when no operation is pending — so its presence is itself a reactive signal.
fn expressionString(cmds: []const glinlandui.RenderCommand) ?[]const u8 {
    for (cmds) |c| {
        if (c.command_type != .text) continue;
        const td = c.render_data.text;
        if (td.font_size == EXPR_FONT) return cmdText(c);
    }
    return null;
}

fn displayColor(cmds: []const glinlandui.RenderCommand) ?[4]f32 {
    for (cmds) |c| {
        if (c.command_type != .text) continue;
        const td = c.render_data.text;
        if (td.font_size == DISPLAY_FONT) return td.text_color;
    }
    return null;
}

fn textCount(cmds: []const glinlandui.RenderCommand) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < cmds.len) : (i += 1) {
        if (cmds[i].command_type == .text) n += 1;
    }
    return n;
}

/// Fill color of the rectangle belonging to keypad key `index`.
fn keyFill(cmds: []const glinlandui.RenderCommand, index: usize) ?[4]f32 {
    for (cmds) |c| {
        if (c.command_type != .rectangle) continue;
        if (c.id == frame.clayId(state_mod.KEY_IDS[index]).id) {
            return c.render_data.rectangle.background_color;
        }
    }
    return null;
}

const Capture = struct {
    var cmds: []const glinlandui.RenderCommand = &.{};

    fn probe(_: ?*anyopaque, c: []const glinlandui.RenderCommand, _: u32, _: u32) void {
        cmds = c;
    }
};

/// Run one frame through the Host's normal path and return its commands. NOTE: the returned slice is owned by the Clay arena and stays valid only until the next frame — assert before calling again.
fn drawFrame(host: *glinlandui.host.Host) []const glinlandui.RenderCommand {
    var opt = glinlandui.frame.FrameOptions{};
    opt.probe = Capture.probe;
    opt.probe_user_data = null;
    _ = host.frameWithOptions(360, 440, &opt);
    return Capture.cmds;
}

test "declaring the app emits the display, every key and the row boxes" {
    const Rec = struct {
        var rects: usize = 0;
        var texts: usize = 0;
        fn probe(_: ?*anyopaque, cmds: []const glinlandui.RenderCommand, _: u32, _: u32) void {
            for (cmds) |c| switch (c.command_type) {
                .rectangle => rects += 1,
                .text => texts += 1,
                else => {},
            };
        }
    };
    const alloc = std.heap.page_allocator;
    var vm = CalculatorViewModel.init();
    // NOTE: no `host.deinit()` here. Clay keeps a process-global pointer into the arena that deinit frees, so the next Host.init() would read a dangling currentContext and segfault in Clay_MinMemorySize. The page-allocator arena is intentionally left alive for the rest of the test process — exactly what core/testing/root.zig's Driver.deinit does.
    var host = try glinlandui.host.Host.init(alloc, &vm, root);

    var opt = glinlandui.frame.FrameOptions{};
    opt.probe = Rec.probe;
    opt.probe_user_data = null;
    _ = host.frameWithOptions(360, 440, &opt);

    // 20 buttons + root + display = 22 rects (the display is opaque; the row boxes are transparent and emit nothing).
    try std.testing.expectEqual(@as(usize, 22), Rec.rects);
    // One label per button + the display value; the expression line is empty until an operation is pending.
    try std.testing.expectEqual(@as(usize, 21), Rec.texts);
}

test "a click on a declared key fires its indexed handler" {
    const alloc = std.heap.page_allocator;
    var vm = CalculatorViewModel.init();
    // NOTE: no `host.deinit()` here. Clay keeps a process-global pointer into the arena that deinit frees, so the next Host.init() would read a dangling currentContext and segfault in Clay_MinMemorySize. The page-allocator arena is intentionally left alive for the rest of the test process — exactly what core/testing/root.zig's Driver.deinit does.
    var host = try glinlandui.host.Host.init(alloc, &vm, root);

    host.frame(360, 440);

    // Click the "7" key (row 1, col 0) at its own center, the same way dispatch.pointerEvent does on a release.
    const bb = frame.bounds(frame.clayId(state_mod.KEY_IDS[4])) orelse return error.TestUnexpectedResult;
    try std.testing.expect(registry.dispatchClick(
        bb.x + bb.width * 0.5,
        bb.y + bb.height * 0.5,
    ));
    try std.testing.expectEqualStrings("7", vm.display());

    // And the whole keypad is a registered, cursor-bearing hit target.
    try std.testing.expectEqual(
        registry.Cursor.pointer,
        registry.hoverCursorAt(bb.x + bb.width * 0.5, bb.y + bb.height * 0.5),
    );
}

test "the keypad lays out as five rows of four, without overlap" {
    const alloc = std.heap.page_allocator;
    var vm = CalculatorViewModel.init();
    // NOTE: no `host.deinit()` here. Clay keeps a process-global pointer into the arena that deinit frees, so the next Host.init() would read a dangling currentContext and segfault in Clay_MinMemorySize. The page-allocator arena is intentionally left alive for the rest of the test process — exactly what core/testing/root.zig's Driver.deinit does.
    var host = try glinlandui.host.Host.init(alloc, &vm, root);
    host.frame(360, 440);

    for (state_mod.KEY_IDS, 0..) |id, i| {
        const bb = frame.bounds(frame.clayId(id)) orelse return error.TestUnexpectedResult;
        // Fixed-size keys inside the window.
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(key_w)), bb.width, 1.0);
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(key_h)), bb.height, 1.0);
        // Grid position matches the declared order: column = i % cols.
        const col = i % state_mod.cols;
        const row = i / state_mod.cols;
        if (col > 0) {
            const left = frame.bounds(frame.clayId(state_mod.KEY_IDS[i - 1])).?;
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
            const above = frame.bounds(frame.clayId(state_mod.KEY_IDS[i - state_mod.cols])).?;
            try std.testing.expect(bb.y > above.y);
        }
    }
}

// ---- Reactivity: the rendered view must follow the machine ----
// A callback firing and the machine mutating are two halves of the contract; the third is that the NEXT frame shows the new state, so these assert on the commands the compositor would receive.

test "the view shows 0 before any input" {
    const alloc = std.heap.page_allocator;
    var vm = CalculatorViewModel.init();
    var host = try glinlandui.host.Host.init(alloc, &vm, root);
    const cmds = drawFrame(&host);
    try std.testing.expectEqualStrings("0", displayString(cmds).?);
    // No operation pending, so the expression line is not declared.
    try std.testing.expect(expressionString(cmds) == null);
    try std.testing.expectEqual(@as(usize, 21), textCount(cmds));
}

test "typing updates the display the view renders" {
    const alloc = std.heap.page_allocator;
    var vm = CalculatorViewModel.init();
    var host = try glinlandui.host.Host.init(alloc, &vm, root);

    try std.testing.expectEqualStrings("0", displayString(drawFrame(&host)).?);

    // Each keystroke must be visible in the very next frame.
    for ([_]u8{ '1', '2', '3' }) |c| {
        _ = vm.onKeycode(.{}, switch (c) {
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
    var vm = CalculatorViewModel.init();
    var host = try glinlandui.host.Host.init(alloc, &vm, root);

    // Fresh: no expression line, so one text per key + one display.
    try std.testing.expectEqual(@as(usize, 21), textCount(drawFrame(&host)));

    for ("12") |c| vm.feedChar(c);
    vm.feedChar('+');
    const pending = drawFrame(&host);
    // One EXTRA text command appears purely because state changed.
    try std.testing.expectEqual(@as(usize, 22), textCount(pending));
    try std.testing.expectEqualStrings("12 +", expressionString(pending).?);
    try std.testing.expectEqualStrings("12", displayString(pending).?);

    vm.feedChar('=');
    const done = drawFrame(&host);
    // Consuming the operation removes it from the view again. The right operand is the still-displayed "12", so this is 12 + 12 = 24.
    try std.testing.expectEqual(@as(usize, 21), textCount(done));
    try std.testing.expect(expressionString(done) == null);
    try std.testing.expectEqualStrings("24", displayString(done).?);
}

test "a computed result replaces the display, and the operand line follows" {
    const alloc = std.heap.page_allocator;
    var vm = CalculatorViewModel.init();
    var host = try glinlandui.host.Host.init(alloc, &vm, root);
    for ("12345") |c| vm.feedChar(c);
    vm.feedChar('*');
    vm.feedChar('2');
    vm.feedChar('=');
    const cmds = drawFrame(&host);
    // 12345 * 2 folds to 24690 — a five-digit result the view must show.
    try std.testing.expectEqualStrings("24690", displayString(cmds).?);
    try std.testing.expect(expressionString(cmds) == null);
}

test "divide by zero turns the display red in the next frame" {
    const alloc = std.heap.page_allocator;
    var vm = CalculatorViewModel.init();
    var host = try glinlandui.host.Host.init(alloc, &vm, root);
    const healthy = displayColor(drawFrame(&host)).?;
    try std.testing.expectEqual(COLOR_FG.toClay(), healthy);

    for ("50") |c| vm.feedChar(c);
    vm.feedChar('/');
    vm.feedChar('0');
    vm.feedChar('=');
    const broken = drawFrame(&host);
    // Both the text AND its color are reactive to the error latch.
    try std.testing.expectEqualStrings("ERR", displayString(broken).?);
    try std.testing.expectEqual(COLOR_ERR.toClay(), displayColor(broken).?);
    try std.testing.expect(colorDiffers(displayColor(broken).?, healthy));
}

test "a keypad click is visible in the next frame" {
    const alloc = std.heap.page_allocator;
    var vm = CalculatorViewModel.init();
    var host = try glinlandui.host.Host.init(alloc, &vm, root);
    host.frame(360, 440);

    // Press "7" the way dispatch.pointerEvent does, then redraw.
    const bb = frame.bounds(frame.clayId(state_mod.KEY_IDS[4])).?;
    try std.testing.expect(registry.dispatchClick(bb.x + bb.width * 0.5, bb.y + bb.height * 0.5));
    try std.testing.expectEqualStrings("7", displayString(drawFrame(&host)).?);

    // Then "8", one column right, on a freshly laid-out frame.
    const bb8 = frame.bounds(frame.clayId(state_mod.KEY_IDS[5])).?;
    try std.testing.expect(registry.dispatchClick(bb8.x + bb8.width * 0.5, bb8.y + bb8.height * 0.5));
    try std.testing.expectEqualStrings("78", displayString(drawFrame(&host)).?);
}

test "the keypad repaints on hover as the pointer moves" {
    const alloc = std.heap.page_allocator;
    var vm = CalculatorViewModel.init();
    var host = try glinlandui.host.Host.init(alloc, &vm, root);

    // Frame 1: pointer far away, so every key shows its resting fill.
    host.onPointerEvent(-1, -1, false, 0);
    const resting = drawFrame(&host);
    const rest_8 = keyFill(resting, 5).?;
    try std.testing.expectEqual(COLOR_DIGIT.toClay(), rest_8);
    const rest_eq = keyFill(resting, 19).?;
    try std.testing.expectEqual(COLOR_ACCENT.toClay(), rest_eq);

    // Frame 2: pointer over the "8" key, whose box is known from frame 1.
    const bb8 = frame.bounds(frame.clayId(state_mod.KEY_IDS[5])).?;
    host.onPointerEvent(bb8.x + bb8.width * 0.5, bb8.y + bb8.height * 0.5, false, 0);
    const hovered = drawFrame(&host);
    // Only the hovered key changes fill; its neighbours do not.
    try std.testing.expectEqual(COLOR_DIGIT_HOVER.toClay(), keyFill(hovered, 5).?);
    try std.testing.expect(colorDiffers(keyFill(hovered, 5).?, rest_8));
    try std.testing.expectEqual(rest_8, keyFill(hovered, 4).?);
    try std.testing.expectEqual(rest_8, keyFill(hovered, 6).?);
    try std.testing.expectEqual(rest_eq, keyFill(hovered, 19).?);
}

test "the operators keep their tint across a state change" {
    const alloc = std.heap.page_allocator;
    var vm = CalculatorViewModel.init();
    var host = try glinlandui.host.Host.init(alloc, &vm, root);
    host.onPointerEvent(-1, -1, false, 0);
    const before = drawFrame(&host);

    for ("8+8") |c| vm.feedChar(c);
    vm.feedChar('=');
    const after = drawFrame(&host);

    // The state change must not disturb the static key chrome: a regression here would mean the grid rebuilds wrong when a value lands on the display.
    for (0..state_mod.Key.count) |i| {
        try std.testing.expectEqual(keyFill(before, i), keyFill(after, i));
    }
    try std.testing.expectEqual(COLOR_OP.toClay(), keyFill(after, 3).?); // "/"
    try std.testing.expectEqual(COLOR_OP.toClay(), keyFill(after, 15).?); // "+"
    try std.testing.expectEqual(COLOR_ACCENT.toClay(), keyFill(after, 19).?); // "="
    try std.testing.expectEqualStrings("16", displayString(after).?);
}
