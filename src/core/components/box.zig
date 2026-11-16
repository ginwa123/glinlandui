// Agnostic reusable Clay box (div-like container, toolkit-style, library only).
const std = @import("std");
const cl = @import("zclay");
const headless = @import("../testing/headless.zig");
const Color = @import("../color.zig").Color;
const prop = @import("../props.zig");
const registry = @import("click_registry.zig");
const context_menu = @import("context_menu.zig");
const semantics = @import("../semantics.zig");
const erased = @import("../erased.zig");
const Ctx = erased.Ctx;

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
    // Where the app declared this widget: `@src()` at the call site, which the devtool then shows as the declaration.
    src: ?std.builtin.SourceLocation = null,
    direction: Direction = .column,
    w: prop.Size = .fit,
    h: prop.Size = .fit,
    bg: ?Color = null,
    /// The background while the pointer is over this box, or `bg` when it is not.
    hover_bg: ?Color = null,
    pad: prop.Pad = .{},
    gap: prop.Len = .{},
    radius: prop.Radius = .{},
    border: prop.Border = .{},
    child_align: cl.ChildAlignment = .{},
    // The click this container raises: an app hands one in instead of reaching for the click registry itself.
    on_click: prop.Click = .{},
    // The pointer shape over the hit target; only read when `on_click` has a handler.
    cursor: prop.Cursor = .pointer,
    // The right-click menu this container offers; empty (the default) means it has none.
    context_menu: prop.ContextMenu = .{},
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
            .child_gap = p.gap.whole(),
            .child_alignment = p.child_align,
        },
        .background_color = if (bg) |b| b.toClay() else .{ 0, 0, 0, 0 },
        .corner_radius = p.radius.clay(),
        .border = p.border.clay(),
    })({
        // The box's own hit target answers first, so a clickable child drawn on top of it wins the tie.
        if (p.on_click.f) |cb| registry.registerClickCursor(p.id.clay(), cb, p.on_click.ctx, p.cursor);
        // A right click opens the card the engine draws, so a container is all a menu needs.
        if (!p.context_menu.isNone()) context_menu.register(p.id.clay(), p.context_menu, 0);
        // A container is part of the component tree: the children it declares record it as their parent, which is what the devtool's tree shows.
        semantics.pushAncestor(p.id.clay(), false);
        children(ctx);
        semantics.popAncestor();
    });
    // Registered AFTER the pop, so a container is never its own ancestor.
    semantics.registerAt(@src(), .{
        .declared = semantics.declaredAt(p.src),
        .id = p.id.clay(),
        .tag = p.id.str(),
        .role = if (p.on_click.f != null) .button else .container,
        .flags = .{ .enabled = true },
        .actions = .{ .click = p.on_click.f != null },
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

fn emptyChildren(_: void) void {}

fn declareEmptyBox() void {
    box(.{ .id = .{ .text = "test-empty-box" } }, {}, emptyChildren);
}

test "empty box with no bg emits no rectangles" {
    var rects: usize = 0;
    var texts: usize = 0;
    try headless.countCommands(declareEmptyBox, &rects, &texts);
    try std.testing.expectEqual(@as(usize, 0), rects);
    try std.testing.expectEqual(@as(usize, 0), texts);
}

fn declareBgBox() void {
    box(.{ .id = .{ .text = "test-bg-box" }, .bg = Color.rgb(0x1e, 0x1e, 0x1e) }, {}, emptyChildren);
}

test "box with bg emits exactly one rectangle" {
    var rects: usize = 0;
    var texts: usize = 0;
    try headless.countCommands(declareBgBox, &rects, &texts);
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
    try headless.countCommands(declareChildBox, &rects, &texts);
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
    try headless.countCommands(declareNestedBox, &rects, &texts);
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
    _ = try headless.frameCommands(declareRowBox);
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
    _ = try headless.frameCommands(declareColBox);
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
    try std.testing.expectEqual(@as(f32, 0), p.pad.top.pts());
    try std.testing.expectEqual(@as(f32, 0), p.gap.pts());
    try std.testing.expectEqual(@as(f32, 0), p.radius.top_left.pts());
    try std.testing.expectEqual(@as(f32, 0), p.border.width.pts());
}

fn declareFractional() void {
    box(.{ .id = .{ .text = "test-fractional" }, .w = .{ .fixed = 12.5 }, .h = .{ .fixed = 7.5 }, .bg = Color.rgb(0x1e, 0x1e, 0x1e) }, {}, emptyChildren);
}

test "fixed size keeps fractional pixels" {
    _ = try headless.frameCommands(declareFractional);
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
    _ = try headless.frameCommands(declareCentered);
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
    try headless.countCommands(declareSpacer, &rects, &texts);
    // A spacer is transparent, so Clay emits no rectangle for it — that is the point of a spacer.
    try std.testing.expectEqual(@as(usize, 0), rects);
    try std.testing.expectEqual(@as(usize, 0), texts);
}

// ---- on_click: a container that answers the pointer without the app touching the registry ----

const BoxClickRec = struct {
    outer: usize = 0,
    inner: usize = 0,
};

var box_click: BoxClickRec = .{};

fn onOuterBox(_: Ctx) void {
    box_click.outer += 1;
}

fn onInnerBox(_: Ctx) void {
    box_click.inner += 1;
}

fn declareClickableBox() void {
    box(.{
        .id = .{ .text = "test-click-box" },
        .w = .{ .fixed = 80 },
        .h = .{ .fixed = 40 },
        .on_click = .{ .f = onOuterBox, .ctx = Ctx.from(&box_click) },
    }, {}, emptyChildren);
}

test "a clickable box answers a click at its centre, and a plain box answers nothing" {
    registry.beginFrame();
    _ = try headless.frameCommands(declareClickableBox);
    const bb = cl.getElementData(cl.getElementId("test-click-box")).bounding_box;
    try std.testing.expect(registry.dispatchClick(bb.x + bb.width * 0.5, bb.y + bb.height * 0.5));
    try std.testing.expectEqual(@as(usize, 1), box_click.outer);

    registry.beginFrame();
    _ = try headless.frameCommands(declareBgBox);
    const plain = cl.getElementData(cl.getElementId("test-bg-box")).bounding_box;
    try std.testing.expect(!registry.dispatchClick(plain.x + plain.width * 0.5, plain.y + plain.height * 0.5));
    try std.testing.expectEqual(@as(usize, 1), box_click.outer);
}

fn innerClickable(_: void) void {
    box(.{
        .id = .{ .text = "test-inner-click" },
        .w = .{ .fixed = 40 },
        .h = .{ .fixed = 20 },
        .on_click = .{ .f = onInnerBox, .ctx = Ctx.from(&box_click) },
    }, {}, emptyChildren);
}

fn declareNestedClickable() void {
    box(.{
        .id = .{ .text = "test-outer-click" },
        .w = .{ .fixed = 120 },
        .h = .{ .fixed = 60 },
        .on_click = .{ .f = onOuterBox, .ctx = Ctx.from(&box_click) },
    }, {}, innerClickable);
}

test "a clickable child wins a click over the clickable box that contains it" {
    box_click = .{};
    registry.beginFrame();
    _ = try headless.frameCommands(declareNestedClickable);
    const inner = cl.getElementData(cl.getElementId("test-inner-click")).bounding_box;
    try std.testing.expect(registry.dispatchClick(inner.x + inner.width * 0.5, inner.y + inner.height * 0.5));
    try std.testing.expectEqual(@as(usize, 1), box_click.inner);
    try std.testing.expectEqual(@as(usize, 0), box_click.outer);
    // Outside the child but inside the container: the container answers.
    const outer = cl.getElementData(cl.getElementId("test-outer-click")).bounding_box;
    try std.testing.expect(registry.dispatchClick(outer.x + 2, outer.y + outer.height - 2));
    try std.testing.expectEqual(@as(usize, 1), box_click.outer);
}

test "a clickable box is a button with a click action; a plain box stays a container" {
    _ = try headless.frameCommands(declareClickableBox);
    const clickable = semantics.byId(cl.getElementId("test-click-box")).?;
    try std.testing.expectEqual(semantics.Role.button, clickable.role);
    try std.testing.expect(clickable.actions.click);

    _ = try headless.frameCommands(declareBgBox);
    const plain = semantics.byId(cl.getElementId("test-bg-box")).?;
    try std.testing.expectEqual(semantics.Role.container, plain.role);
    try std.testing.expect(!plain.actions.click);
}

test "a clickable box asks for the pointer shape it was given" {
    const text_box = BoxProps{ .id = .{ .text = "t" }, .on_click = .{ .f = onOuterBox }, .cursor = .text };
    try std.testing.expectEqual(prop.Cursor.text, text_box.cursor);
    // The default is a hand, because a clickable container is a button unless it says otherwise.
    try std.testing.expectEqual(prop.Cursor.pointer, (BoxProps{ .id = .{ .text = "t" } }).cursor);
}
