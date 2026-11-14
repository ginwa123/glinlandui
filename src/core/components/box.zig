// Agnostic reusable Clay box (div-like container, toolkit-style, library only).
const std = @import("std");
const cl = @import("zclay");
const Color = @import("../color.zig").Color;
const prop = @import("../props.zig");

/// The sizing type a container props uses. One definition, named where a box needs it.
pub const Size = prop.Size;

/// Box layout direction: row = left-to-right, column = top-to-bottom.
pub const Direction = enum {
    row,
    column,
};

/// Toolkit-style box props: an id, a size per axis, padding, a radius, a border, and the layout it arranges.
pub const BoxProps = struct {
    id: prop.Id,
    direction: Direction = .column,
    w: prop.Size = .fit,
    h: prop.Size = .fit,
    bg: ?Color = null,
    /// The background while the pointer is over this box, or `bg` when it is not.
    hover_bg: ?Color = null,
    pad: prop.Pad = .{},
    gap: u16 = 0,
    radius: prop.Radius = .{},
    border: prop.Border = .{},
    child_align: cl.ChildAlignment = .{},
};

/// Declare a div-like container: a Clay element named by `id`, with the mapped direction, sizing, padding, gap, radius and border; a background only when one is given.
pub fn box(p: BoxProps, ctx: anytype, comptime children: fn (@TypeOf(ctx)) void) void {
    const dir: cl.LayoutDirection = switch (p.direction) {
        .row => .left_to_right,
        .column => .top_to_bottom,
    };
    const bg = if (p.hover_bg) |hover| (if (cl.pointerOver(p.id.clay())) hover else p.bg) else p.bg;
    cl.UI()(.{
        .id = p.id.clay(),
        .layout = .{
            .direction = dir,
            .sizing = .{ .w = p.w.clay(), .h = p.h.clay() },
            .padding = p.pad.clay(),
            .child_gap = p.gap,
            .child_alignment = p.child_align,
        },
        .background_color = if (bg) |b| b.toClay() else .{ 0, 0, 0, 0 },
        .corner_radius = p.radius.clay(),
        .border = p.border.clay(),
    })({
        children(ctx);
    });
}

// ---- Arrange helpers: Row / Column / Spacer over Box ----

/// Row container: Box forced to left-to-right.
pub fn row(p: BoxProps, ctx: anytype, comptime children: fn (@TypeOf(ctx)) void) void {
    var next = p;
    next.direction = .row;
    box(next, ctx, children);
}

/// Column container: Box forced to top-to-bottom.
pub fn column(p: BoxProps, ctx: anytype, comptime children: fn (@TypeOf(ctx)) void) void {
    var next = p;
    next.direction = .column;
    box(next, ctx, children);
}

/// Grow spacer: a transparent Box that expands on both axes, pushing siblings apart.
pub fn spacer(id: prop.Id) void {
    box(.{ .id = id, .w = .grow, .h = .grow }, {}, noChildren);
}

fn noChildren(_: void) void {}

// Stub text estimator for headless tests (no font backend needed).
fn stubMeasure(s: []const u8, cfg: *cl.TextElementConfig, _: void) cl.Dimensions {
    return .{
        .w = @as(f32, @floatFromInt(s.len)) * @as(f32, @floatFromInt(cfg.font_size)) * 0.6,
        .h = @as(f32, @floatFromInt(cfg.font_size)),
    };
}

fn frameCommands(declare_fn: *const fn () void) ![]cl.RenderCommand {
    const mem_size = cl.minMemorySize();
    // NOTE: intentionally leaked (page_allocator, never freed).
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    // Park the pointer far outside the layout so hover state is deterministic.
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declare_fn();
    return cl.endLayout();
}

fn emptyChildren(_: void) void {}

fn countCommands(declare_fn: *const fn () void, rects: *usize, texts: *usize) !void {
    const cmds = try frameCommands(declare_fn);
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

fn declareEmptyBox() void {
    box(.{ .id = .{ .text = "test-empty-box" } }, {}, emptyChildren);
}

test "empty box with no bg emits no rectangles" {
    var rects: usize = 0;
    var texts: usize = 0;
    try countCommands(declareEmptyBox, &rects, &texts);
    try std.testing.expectEqual(@as(usize, 0), rects);
    try std.testing.expectEqual(@as(usize, 0), texts);
}

fn declareBgBox() void {
    box(.{ .id = .{ .text = "test-bg-box" }, .bg = Color.rgb(0x1e, 0x1e, 0x1e) }, {}, emptyChildren);
}

test "box with bg emits exactly one rectangle" {
    var rects: usize = 0;
    var texts: usize = 0;
    try countCommands(declareBgBox, &rects, &texts);
    try std.testing.expectEqual(@as(usize, 1), rects);
    try std.testing.expectEqual(@as(usize, 0), texts);
}

var child_calls: usize = 0;

const ChildCtx = struct {
    n: usize,
};

fn childLabels(ctx: ChildCtx) void {
    child_calls += 1;
    var i: usize = 0;
    while (i < ctx.n) : (i += 1) {
        cl.text("x", .{ .font_size = 14, .color = Color.rgb(0xe8, 0xe8, 0xe8).toClay() });
    }
}

fn declareChildBox() void {
    box(.{ .id = .{ .text = "test-child-box" } }, ChildCtx{ .n = 3 }, childLabels);
}

test "children callback invoked; N child labels emit N texts" {
    child_calls = 0;
    var rects: usize = 0;
    var texts: usize = 0;
    try countCommands(declareChildBox, &rects, &texts);
    try std.testing.expectEqual(@as(usize, 1), child_calls);
    try std.testing.expectEqual(@as(usize, 3), texts);
}

fn innerBox(_: void) void {
    box(.{ .id = .{ .text = "test-nested-inner" }, .bg = Color.rgb(0x2d, 0x2d, 0x2d) }, {}, emptyChildren);
}

fn outerChildren(_: void) void {
    innerBox({});
}

fn declareNestedBox() void {
    box(.{ .id = .{ .text = "test-nested-outer" }, .bg = Color.rgb(0x1e, 0x1e, 0x1e) }, {}, outerChildren);
}

test "nested boxes declare both rects" {
    var rects: usize = 0;
    var texts: usize = 0;
    try countCommands(declareNestedBox, &rects, &texts);
    try std.testing.expectEqual(@as(usize, 2), rects);
    try std.testing.expectEqual(@as(usize, 0), texts);
}

fn rowChildren(_: void) void {
    box(.{ .id = .{ .text = "test-row-a" }, .w = .{ .fixed = 20 }, .h = .{ .fixed = 10 }, .bg = Color.rgb(0x1e, 0x1e, 0x1e) }, {}, emptyChildren);
    box(.{ .id = .{ .text = "test-row-b" }, .w = .{ .fixed = 20 }, .h = .{ .fixed = 10 }, .bg = Color.rgb(0x1e, 0x1e, 0x1e) }, {}, emptyChildren);
}

fn declareRowBox() void {
    box(.{ .id = .{ .text = "test-row" }, .direction = .row }, {}, rowChildren);
}

test "row direction lays children out horizontally (x differs, y equal)" {
    _ = try frameCommands(declareRowBox);
    const a = cl.getElementData(cl.getElementId("test-row-a")).bounding_box;
    const b = cl.getElementData(cl.getElementId("test-row-b")).bounding_box;
    try std.testing.expect(b.x > a.x);
    try std.testing.expectEqual(a.y, b.y);
}

fn colChildren(_: void) void {
    box(.{ .id = .{ .text = "test-col-a" }, .w = .{ .fixed = 20 }, .h = .{ .fixed = 10 }, .bg = Color.rgb(0x1e, 0x1e, 0x1e) }, {}, emptyChildren);
    box(.{ .id = .{ .text = "test-col-b" }, .w = .{ .fixed = 20 }, .h = .{ .fixed = 10 }, .bg = Color.rgb(0x1e, 0x1e, 0x1e) }, {}, emptyChildren);
}

fn declareColBox() void {
    box(.{ .id = .{ .text = "test-col" }, .direction = .column }, {}, colChildren);
}

test "column direction lays children out vertically (y differs, x equal)" {
    _ = try frameCommands(declareColBox);
    const a = cl.getElementData(cl.getElementId("test-col-a")).bounding_box;
    const b = cl.getElementData(cl.getElementId("test-col-b")).bounding_box;
    try std.testing.expect(b.y > a.y);
    try std.testing.expectEqual(a.x, b.x);
}

test "BoxProps carries neutral defaults" {
    const p = BoxProps{ .id = .{ .text = "x" } };
    try std.testing.expectEqual(Direction.column, p.direction);
    try std.testing.expect(std.meta.activeTag(p.w) == .fit);
    try std.testing.expect(std.meta.activeTag(p.h) == .fit);
    try std.testing.expect(p.bg == null);
    try std.testing.expectEqual(@as(u16, 0), p.pad.top);
    try std.testing.expectEqual(@as(u16, 0), p.gap);
    try std.testing.expectEqual(@as(u16, 0), p.radius.top_left);
    try std.testing.expectEqual(@as(u16, 0), p.border.width);
}

fn declareFractional() void {
    box(.{ .id = .{ .text = "test-fractional" }, .w = .{ .fixed = 12.5 }, .h = .{ .fixed = 7.5 }, .bg = Color.rgb(0x1e, 0x1e, 0x1e) }, {}, emptyChildren);
}

test "fixed size keeps fractional pixels" {
    _ = try frameCommands(declareFractional);
    const bb = cl.getElementData(cl.getElementId("test-fractional")).bounding_box;
    try std.testing.expectEqual(@as(f32, 12.5), bb.width);
    try std.testing.expectEqual(@as(f32, 7.5), bb.height);
}

fn tallChild(_: void) void {
    box(.{ .id = .{ .text = "test-tall-child" }, .w = .{ .fixed = 10 }, .h = .{ .fixed = 10 }, .bg = Color.rgb(0x1e, 0x1e, 0x1e) }, {}, emptyChildren);
}

fn declareCentered() void {
    box(.{
        .id = .{ .text = "test-centered" },
        .w = .{ .fixed = 40 },
        .h = .{ .fixed = 40 },
        .bg = Color.rgb(0x1e, 0x1e, 0x1e),
        .child_align = .{ .y = .center },
    }, {}, tallChild);
}

test "align y=center vertically centres the child" {
    _ = try frameCommands(declareCentered);
    const parent = cl.getElementData(cl.getElementId("test-centered")).bounding_box;
    const child = cl.getElementData(cl.getElementId("test-tall-child")).bounding_box;
    try std.testing.expect(child.y > parent.y);
    try std.testing.expect(child.y + child.height < parent.y + parent.height);
}

fn declareSpacer() void {
    spacer(.{ .text = "test-spacer" });
}

test "spacer grows on both axes and has no children" {
    var rects: usize = 0;
    var texts: usize = 0;
    try countCommands(declareSpacer, &rects, &texts);
    // A spacer is transparent, so Clay emits no rectangle for it — that is the point of a spacer.
    try std.testing.expectEqual(@as(usize, 0), rects);
    try std.testing.expectEqual(@as(usize, 0), texts);
}
