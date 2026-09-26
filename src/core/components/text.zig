// Agnostic reusable Clay label widget (toolkit-style, library only).
// NOTE: this `text.zig` is the label widget — NOT font utils. Font
// measurement/rendering lives in wayland.text (glinlandui); the name
// overlap is coincidental. This file never imports wayland.text.
// Imports: std + zclay + core/color + core/render_common ONLY.
// Never: app/theme/layout/views/content/sidebar.
const std = @import("std");
const cl = @import("zclay");
const Color = @import("../color.zig").Color;

/// Click callback: plain fn pointer + opaque ctx (no closures).
/// Stored in TextProps for future ID-lookup dispatch; label() itself
/// stays declare-only (never fires it) — the owner (views/host) may fire it
/// via element-ID lookup later.
pub const ClickFn = ?*const fn (?*anyopaque) void;

/// Label props. All styling via props with neutral defaults.
/// `on_click`/`ctx` are stored verbatim and documented; label() ignores
/// them (declare-only leaf: no hover, no selection — those stay
/// caller-side).
pub const TextProps = struct {
    str: []const u8,
    font_size: u16 = 14,
    color: Color = Color.rgb(0xe8, 0xe8, 0xe8),
    wrap: bool = false,
    disabled: bool = false,
    disabled_color: Color = Color.rgb(0x77, 0x77, 0x77),
    on_click: ClickFn = null,
    ctx: ?*anyopaque = null,
};

/// Declare a single text element. `wrap` maps to the Clay wrap_mode
/// (.words when true, .none when false). Declare-only leaf: no hover,
/// no selection — those stay caller-side.
pub fn label(props: TextProps) void {
    cl.text(props.str, .{
        .font_size = props.font_size,
        .color = (if (props.disabled) props.disabled_color else props.color).toClay(),
        .wrap_mode = if (props.wrap) .words else .none,
    });
}

// Stub text estimator for headless tests (no font backend needed).
fn stubMeasure(s: []const u8, cfg: *cl.TextElementConfig, _: void) cl.Dimensions {
    return .{
        .w = @as(f32, @floatFromInt(s.len)) * @as(f32, @floatFromInt(cfg.font_size)) * 0.6,
        .h = @as(f32, @floatFromInt(cfg.font_size)),
    };
}

fn declareLabel() void {
    label(.{ .str = "Hello" });
}

/// Run one headless Clay frame around `declare_fn`, counting rectangle
/// and text render commands.
fn countCommands(declare_fn: *const fn () void, rects: *usize, texts: *usize) !void {
    const mem_size = cl.minMemorySize();
    // NOTE: intentionally leaked (page_allocator, never freed). Clay keeps
    // a global currentContext pointer inside this arena, so freeing it
    // would dangle the *next* test's minMemorySize/initialize (segfault).
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declare_fn();
    const cmds = cl.endLayout();
    var r: usize = 0;
    var t: usize = 0;
    for (cmds) |c| switch (c.command_type) {
        .rectangle => r += 1,
        .text => t += 1,
        else => {},
    };
    rects.* = r;
    texts.* = t;
}

test "label emits exactly one text command, no rectangles" {
    var rects: usize = 0;
    var texts: usize = 0;
    try countCommands(declareLabel, &rects, &texts);
    try std.testing.expectEqual(@as(usize, 0), rects);
    try std.testing.expectEqual(@as(usize, 1), texts);
}

test "TextProps carries neutral defaults" {
    const p = TextProps{ .str = "x" };
    try std.testing.expectEqual(@as(u16, 14), p.font_size);
    try std.testing.expectEqual(Color.rgb(0xe8, 0xe8, 0xe8), p.color);
    try std.testing.expectEqual(false, p.wrap);
    try std.testing.expect(!p.disabled);
    try std.testing.expectEqual(Color.rgb(0x77, 0x77, 0x77), p.disabled_color);
    try std.testing.expect(p.on_click == null);
    try std.testing.expect(p.ctx == null);
}

const ClickCtx = struct {
    calls: usize = 0,
};

fn testOnClick(ctx: ?*anyopaque) void {
    const c: *ClickCtx = @ptrCast(@alignCast(ctx.?));
    c.calls += 1;
}

test "TextProps stores on_click/ctx; label stays declare-only" {
    var c = ClickCtx{};
    const p = TextProps{ .str = "x", .on_click = testOnClick, .ctx = &c };
    try std.testing.expect(p.on_click != null);
    // Declare-only: label() ignores the stored callback (no fire here).
    var rects: usize = 0;
    var texts: usize = 0;
    try countCommands(declareLabel, &rects, &texts);
    try std.testing.expectEqual(@as(usize, 1), texts);
    // Direct invocation still delivers ctx.
    p.on_click.?(p.ctx);
    try std.testing.expectEqual(@as(usize, 1), c.calls);
}

fn declareDisabledLabel() void {
    label(.{ .str = "Hello", .disabled = true });
}

test "disabled label emits one text with the disabled color" {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declareDisabledLabel();
    const cmds = cl.endLayout();
    var texts: usize = 0;
    for (cmds) |c| {
        if (c.command_type == .text) {
            texts += 1;
            try std.testing.expectEqual(Color.rgb(0x77, 0x77, 0x77).toClay(), c.render_data.text.text_color);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), texts);
}
