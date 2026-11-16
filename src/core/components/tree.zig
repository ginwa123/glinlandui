//! A tree view: rows with depth, a caret, expansion state, selection and a right-aligned meta.

const std = @import("std");
const cl = @import("zclay");
const headless = @import("../testing/headless.zig");
const prop = @import("../props.zig");
const Color = @import("../color.zig").Color;
const registry = @import("click_registry.zig");
const reorder_mod = @import("reorder.zig");
const context_menu = @import("context_menu.zig");
const semantics = @import("../semantics.zig");
const text_fit = @import("../text_backend.zig");

/// What a row is, which decides its colour.
pub const RowKind = enum { group, item, leaf };

/// Where a drop landed, in the same words `reorder.zig` decides it with: above a row, inside it, or below it.
pub const Zone = reorder_mod.Zone;

/// The drag spec a tree hands in: `on_drop` is reported with the row under the pointer and the zone.
pub const Reorder = reorder_mod.Reorder;

/// One row. `depth` is the indent level, 0 for a top-level node.
pub const Row = struct {
    label: []const u8,
    depth: u16 = 0,
    has_children: bool = false,
    expanded: bool = false,
    selected: bool = false,
    meta: []const u8 = "",
    kind: RowKind = .item,
};

/// Row click: the index in the slice the tree was given.
pub const SelectFn = ?*const fn (?*anyopaque, usize) void;

pub const TreeProps = struct {
    id: prop.Id,
    // Where the app declared this widget: `@src()` at the call site, which the devtool then shows as the declaration.
    src: ?std.builtin.SourceLocation = null,
    rows: []const Row = &.{},
    row_h: prop.Len = .{ .px = 26 },
    indent: prop.Len = .{ .px = 17 },
    pad_lr: prop.Len = .{ .px = 8 },
    bg: ?Color = null,
    row_bg: Color = Color.rgb(0x1a, 0x1a, 0x1d),
    selected_bg: Color = Color.rgb(0x2d, 0x3a, 0x52),
    hover_bg: Color = Color.rgb(0x22, 0x22, 0x2a),
    fg: Color = Color.rgb(0xd8, 0xd8, 0xdc),
    selected_fg: Color = Color.rgb(0xf0, 0xf0, 0xf4),
    group_fg: Color = Color.rgb(0xf0, 0xf0, 0xf4),
    meta_fg: Color = Color.rgb(0x5a, 0x5a, 0x64),
    caret_fg: Color = Color.rgb(0x5a, 0x5a, 0x64),
    radius: prop.Len = .{ .px = 4 },
    /// The selected row's 2px left bar, so selection is a fill AND a mark. Null draws no bar at all.
    selected_bar: ?Color = null,
    // The three caret glyphs: an open node, the closed one, and the blank a leaf keeps its label aligned with.
    caret_open: []const u8 = "-",
    caret_closed: []const u8 = "+",
    caret_leaf: []const u8 = " ",
    label_size: prop.Len = .{ .px = 13 },
    caret_size: prop.Len = .{ .px = 12 },
    // The space between two rows: 0 stacks them into a block, a point or two lets the bands read apart.
    row_gap: prop.Len = .{},
    // A group's label is drawn one point larger: this font has a single weight, so size is the lever.
    group_bold: bool = false,
    on_select: prop.Select = .{},
    click_z: i16 = 0,
    // A right-click menu per row; a shorter slice (or null) leaves the remaining rows without one.
    context_menus: ?[]const prop.ContextMenu = null,
    // Drag a row onto another to reorder it; null (the default) leaves the rows static.
    reorder: ?reorder_mod.Reorder = null,
    // The app's own leading content for a row (a chip, an icon), declared between the caret and the label.
    row_extra: prop.RowExtra = .{},
    /// How wide `row_extra` draws, so a label's budget can subtract it: the one thing about the row only the app knows.
    extra_width: prop.Len = .{},
};

/// The element id of row `i`. `+1` so row 0 never collides with the container's own id.
pub fn rowId(base: []const u8, i: usize) cl.ElementId {
    return cl.ElementId.IDI(base, @as(u32, @intCast(i + 1)));
}

/// The element id of a row's inner box, offset far enough that it cannot collide with a row.
fn innerId(base: []const u8, i: usize, slot: u32) cl.ElementId {
    return cl.ElementId.IDI(base, @as(u32, @intCast(i + 1)) + slot * 0x10000);
}

/// The glyph a row's caret shows: the app's open mark, its closed mark, or the blank a leaf keeps.
pub fn caretOf(props: TreeProps, row: Row) []const u8 {
    if (!row.has_children) return props.caret_leaf;
    return if (row.expanded) props.caret_open else props.caret_closed;
}

/// How much of a label still fits, and whether the rest has to be shown as dots.
const Fitted = struct { keep: usize, dots: bool };

/// The label cut to the row's own box from the previous frame, so a long name is shortened instead of wrapping into the row below.
fn fitLabel(props: TreeProps, row: Row, i: usize, size: u16) Fitted {
    if (row.label.len == 0) return .{ .keep = 0, .dots = false };
    const el = cl.getElementData(rowId(props.id.str(), i));
    if (!el.found) return .{ .keep = row.label.len, .dots = false };
    const row_w = el.bounding_box.width;
    if (row_w <= 0) return .{ .keep = row.label.len, .dots = false };
    // What the row spends before the label: its two paddings, the indent, the caret, the app's decor, the count and the gaps.
    const caret_w = text_fit.measureText(caretOf(props, row), props.caret_size.whole()).w;
    const meta_w = if (row.meta.len > 0) text_fit.measureText(row.meta, 11).w else 0;
    const gaps: f32 = 6 * @as(f32, if (row.meta.len > 0) 3 else 2);
    const indent_w = props.indent.pts() * @as(f32, @floatFromInt(row.depth));
    const budget = row_w - props.pad_lr.pts() * 2 - indent_w - caret_w - props.extra_width.pts() - meta_w - gaps;
    if (budget <= 0) return .{ .keep = 0, .dots = true };
    if (text_fit.measureText(row.label, size).w <= budget) return .{ .keep = row.label.len, .dots = false };
    const dots_w = text_fit.measureText("...", size).w;
    if (dots_w >= budget) return .{ .keep = 0, .dots = false };
    // The longest prefix that still fits beside the dots: a binary search over codepoint counts, so a 200 char label costs a handful of measures.
    var lo: usize = 0;
    var hi: usize = codepoints(row.label);
    while (lo < hi) {
        const mid = lo + (hi - lo + 1) / 2;
        if (text_fit.measureText(prefix(row.label, mid), size).w + dots_w <= budget) lo = mid else hi = mid - 1;
    }
    return .{ .keep = prefix(row.label, lo).len, .dots = true };
}

/// A count of codepoints, so a cut never lands inside a UTF-8 sequence.
fn codepoints(text: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (n += 1) {
        i += 1;
        while (i < text.len and (text[i] & 0xC0) == 0x80) i += 1;
    }
    return n;
}

/// The first `n` codepoints of `text`.
fn prefix(text: []const u8, n: usize) []const u8 {
    var i: usize = 0;
    var k: usize = 0;
    while (i < text.len and k < n) : (k += 1) {
        i += 1;
        while (i < text.len and (text[i] & 0xC0) == 0x80) i += 1;
    }
    return text[0..i];
}

/// Declare a tree: one clickable row per entry, indented by `depth`.
pub fn tree(props: TreeProps) void {
    semantics.registerAt(@src(), .{
        .declared = semantics.declaredAt(props.src),
        .id = props.id.clay(),
        .tag = props.id.str(),
        .role = .list,
        .flags = .{ .enabled = true },
    });

    cl.UI()(.{
        .id = props.id.clay(),
        .layout = .{
            .direction = .top_to_bottom,
            .sizing = .{ .w = .grow, .h = .fit },
            .child_gap = props.row_gap.whole(),
        },
        .background_color = if (props.bg) |b| b.toClay() else .{ 0, 0, 0, 0 },
    })({
        // Rows belong to the tree view that declares them, which is what the devtool nests them under.
        semantics.pushAncestor(props.id.clay(), false);
        for (props.rows, 0..) |row, i| rowUi(props, row, i);
        semantics.popAncestor();
        // Last, so the indicator paints over the rows it separates.
        declareDrop(props);
    });
}

// The drop indicator: a 2 pt line between two rows, or a ring around the container the drop would fill.
fn declareDrop(props: TreeProps) void {
    const spec = props.reorder orelse return;
    const list = props.id.str();
    const owner = reorder_mod.draggingList() orelse return;
    if (!std.mem.eql(u8, owner, list)) return;
    const zone = reorder_mod.dropZone() orelse return;
    if (zone.isReorder()) return reorder_mod.declareLine(list);
    const target = reorder_mod.dropTarget() orelse return;
    const data = cl.getElementData(rowId(list, target));
    if (!data.found) return;
    const bb = data.bounding_box;
    if (bb.width <= 4 or bb.height <= 4) return;
    // A ring two points inside the row's own box, so it reads as a container about to be filled.
    cl.UI()(.{
        .id = .ID("glin.tree.into"),
        .layout = .{ .sizing = .{ .w = .fixed(bb.width - 4), .h = .fixed(bb.height - 4) } },
        .floating = .{
            .attach_to = .to_root,
            .offset = .{ .x = bb.x + 2, .y = bb.y + 2 },
            .z_index = reorder_mod.z_index,
            .pointer_capture_mode = .passthrough,
        },
        .background_color = Color.withAlpha(spec.line, 34).toClay(),
        .border = .{ .color = spec.line.toClay(), .width = .outside(2) },
        .corner_radius = .all(props.radius.pts()),
    })({});
}

fn rowUi(props: TreeProps, row: Row, i: usize) void {
    const fg = if (row.selected)
        props.selected_fg
    else if (row.kind == .group)
        props.group_fg
    else
        props.fg;
    const base_bg = if (row.selected) props.selected_bg else props.row_bg;
    const left = props.pad_lr.add(props.indent.scaled(@floatFromInt(row.depth)));
    // A group's label outweighs its items by a point: the font has one weight, so size is the lever.
    const label_size = if (props.group_bold and row.kind == .group) props.label_size.add(.{ .px = 1 }) else props.label_size;

    cl.UI()(.{
        .id = .IDI(props.id.str(), @as(u32, @intCast(i + 1))),
        .layout = .{
            .direction = .left_to_right,
            .sizing = .{ .w = .grow, .h = .fixed(props.row_h.pts()) },
            .padding = .{
                .left = left.whole(),
                .right = props.pad_lr.whole(),
            },
            .child_alignment = .{ .x = .left, .y = .center },
            .child_gap = 6,
        },
        .background_color = (if (!row.selected and cl.hovered()) props.hover_bg else base_bg).toClay(),
        .corner_radius = .all(props.radius.pts()),
        // Always 2px wide, transparent when the row is not selected, so selecting a row moves nothing.
        .border = if (props.selected_bar) |bar| .{
            .color = (if (row.selected) bar else Color.rgb(0x00, 0x00, 0x00)).toClay(),
            .width = .{ .left = 2 },
        } else .{},
    })({
        // A fixed-width caret so labels line up whether or not a row expands.
        cl.text(caretOf(props, row), .{
            .font_size = props.caret_size.whole(),
            .color = props.caret_fg.toClay(),
        });
        // The app's own decor comes between the caret and the label, so a chip keeps the label's alignment.
        if (props.row_extra.f) |extra| extra(props.row_extra.ctx, i);
        // The label grows, which is what pushes the meta to the right edge.
        cl.UI()(.{
            .id = innerId(props.id.str(), i, 1),
            .layout = .{
                .direction = .left_to_right,
                .sizing = .{ .w = .grow, .h = .grow },
                .child_alignment = .{ .x = .left, .y = .center },
                .child_gap = 0,
            },
        })({
            const fitted = fitLabel(props, row, i, label_size.whole());
            cl.text(row.label[0..fitted.keep], .{ .font_size = label_size.whole(), .color = fg.toClay() });
            // Three dots rather than U+2026: the bundled face has Latin-1, and a missing glyph would read worse than a shortened name.
            if (fitted.dots) cl.text("...", .{ .font_size = label_size.whole(), .color = fg.toClay() });
        });
        if (row.meta.len > 0) {
            cl.text(row.meta, .{ .font_size = 11, .color = props.meta_fg.toClay() });
        }
    });

    semantics.registerAt(@src(), .{
        .declared = semantics.declaredAt(props.src),
        .id = rowId(props.id.str(), i),
        .role = .list_item,
        .flags = .{ .enabled = true, .selected = row.selected },
    });
    if (props.on_select.f) |cb| {
        registry.registerZCursor(rowId(props.id.str(), i), cb, props.on_select.ctx, i, props.click_z, .pointer);
    }
    // A row that holds children accepts a drop INTO it; anything else only accepts a boundary.
    if (props.reorder) |spec| {
        const id = rowId(props.id.str(), i);
        if (row.has_children or row.kind == .group) {
            reorder_mod.registerContainer(props.id.str(), id, i, spec);
        } else {
            reorder_mod.register(props.id.str(), id, i, spec);
        }
    }
    if (props.context_menus) |menus| {
        if (i < menus.len and !menus[i].isNone()) context_menu.register(rowId(props.id.str(), i), menus[i], props.click_z);
    }
}

const sample_rows = [_]Row{
    .{ .label = "demo.db", .depth = 0, .has_children = true, .expanded = true, .kind = .group },
    .{ .label = "Tables", .depth = 1, .has_children = true, .expanded = true, .kind = .group },
    .{ .label = "users", .depth = 2, .meta = "1,284" },
    .{ .label = "orders", .depth = 2, .meta = "512", .selected = true },
};

fn declareSample() void {
    tree(.{ .id = .{ .text = "t" }, .rows = &sample_rows });
}

test "a tree draws one row per entry, plus the container" {
    var rects: usize = 0;
    var texts: usize = 0;
    try headless.countCommands(declareSample, &rects, &texts);
    // One rect per row: the container and the label boxes are transparent, so they emit none.
    try std.testing.expectEqual(sample_rows.len, rects);
    // A caret and a label per row, plus a meta on the two that carry one.
    try std.testing.expectEqual(sample_rows.len * 2 + 2, texts);
}

test "an empty tree still declares its container" {
    var rects: usize = 0;
    var texts: usize = 0;
    try headless.countCommands(declareEmpty, &rects, &texts);
    try std.testing.expectEqual(@as(usize, 0), rects);
    try std.testing.expectEqual(@as(usize, 0), texts);
}

fn declareEmpty() void {
    tree(.{ .id = .{ .text = "t-empty" }, .rows = &.{} });
}

const bar_rows = [_]Row{ .{ .label = "a" }, .{ .label = "b", .selected = true } };

fn declareWithBar() void {
    tree(.{ .id = .{ .text = "t-bar" }, .rows = &bar_rows, .selected_bar = Color.rgb(0x8b, 0xa4, 0xb0) });
}

test "selected_bar draws one 2px left border per row, transparent when unselected" {
    var rects: usize = 0;
    var texts: usize = 0;
    try headless.countCommands(declareWithBar, &rects, &texts);
    // The bar rides on the row's own border, so it adds no rectangle and no text.
    try std.testing.expectEqual(bar_rows.len, rects);
    // Without the prop the rows are unchanged.
    try headless.countCommands(declareSample, &rects, &texts);
    try std.testing.expectEqual(sample_rows.len, rects);
}

test "TreeProps needs only an id" {
    const p = TreeProps{ .id = .{ .text = "x" } };
    try std.testing.expectEqual(@as(usize, 0), p.rows.len);
}

var extra_ctx: struct { seen: usize = 0, last: usize = 0 } = .{};

fn onExtra(ctx: ?*anyopaque, index: usize) void {
    const c: *@TypeOf(extra_ctx) = @ptrCast(@alignCast(ctx.?));
    c.seen += 1;
    c.last = index;
}

const menu_items = [_][]const u8{ "Rename", "Delete" };

fn declareDecorated() void {
    const menus = [_]prop.ContextMenu{
        .{ .items = &menu_items },
        .{},
    };
    tree(.{
        .id = .{ .text = "t-decor" },
        .rows = &bar_rows,
        .row_extra = .{ .f = onExtra, .ctx = &extra_ctx },
        .context_menus = &menus,
    });
}

// ONE canvas for this file, never freed: Clay keeps a context pointer, and re-initialising on a released buffer faults.
var canvas: ?[]u8 = null;

fn canvasOnce() void {
    if (canvas != null) return;
    const mem = std.heap.page_allocator.alloc(u8, cl.minMemorySize()) catch @panic("OOM");
    const arena = cl.Arena.init(mem);
    _ = cl.initialize(arena, .{ .w = 320, .h = 240 }, .{});
    cl.setMeasureTextFunction(void, {}, headless.stubMeasure);
    canvas = mem;
}

test "row_extra runs once per row, and only the rows with a menu answer a right click" {
    canvasOnce();
    extra_ctx = .{};
    context_menu.close();
    registry.beginFrame();
    context_menu.beginFrame();
    reorder_mod.beginFrame();
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declareDecorated();
    _ = cl.endLayout();

    // The app's decor was asked for every row, in order.
    try std.testing.expectEqual(bar_rows.len, extra_ctx.seen);
    try std.testing.expectEqual(bar_rows.len - 1, extra_ctx.last);

    // Row 1 has no menu of its own, so a right click on it is nobody's.
    const none = cl.getElementData(rowId("t-decor", 1)).bounding_box;
    try std.testing.expect(!context_menu.secondaryClick(none.x + 4, none.y + 4, 320, 240));
    // Row 0 does.
    const with_menu = cl.getElementData(rowId("t-decor", 0)).bounding_box;
    try std.testing.expect(context_menu.secondaryClick(with_menu.x + 4, with_menu.y + 4, 320, 240));
    try std.testing.expect(context_menu.isOpen());
    context_menu.close();
}

test "the three caret props say what a font without those glyphs should draw" {
    const plain = TreeProps{ .id = .{ .text = "d" } };
    try std.testing.expectEqualStrings("-", caretOf(plain, .{ .label = "a", .has_children = true, .expanded = true }));
    try std.testing.expectEqualStrings("+", caretOf(plain, .{ .label = "a", .has_children = true }));
    try std.testing.expectEqualStrings(" ", caretOf(plain, .{ .label = "a" }));

    const carved = TreeProps{ .id = .{ .text = "d" }, .caret_open = "v", .caret_closed = ">", .caret_leaf = " " };
    try std.testing.expectEqualStrings("v", caretOf(carved, .{ .label = "a", .has_children = true, .expanded = true }));
    try std.testing.expectEqualStrings(">", caretOf(carved, .{ .label = "a", .has_children = true }));
    try std.testing.expectEqualStrings(" ", caretOf(carved, .{ .label = "a" }));
}

const tuned_rows = [_]Row{
    .{ .label = "Group", .depth = 0, .has_children = true, .expanded = true, .kind = .group },
    .{ .label = "Item", .depth = 1 },
};

fn declareTuned() void {
    tree(.{
        .id = .{ .text = "t-tuned" },
        .rows = &tuned_rows,
        .row_h = .{ .px = 26 },
        .label_size = .{ .px = 13 },
        .caret_size = .{ .px = 10 },
        .row_gap = .{ .px = 2 },
        .group_bold = true,
    });
}

test "row_gap separates the bands, and group_bold outweighs a group's label by a point" {
    const cmds = try headless.frameCommands(declareTuned);
    const first = cl.getElementData(rowId("t-tuned", 0)).bounding_box;
    const second = cl.getElementData(rowId("t-tuned", 1)).bounding_box;
    // One band is row_h, and the gap is the empty line between two of them.
    try std.testing.expectEqual(@as(f32, 26), first.height);
    try std.testing.expectEqual(@as(f32, 2), second.y - (first.y + first.height));

    var group_size: u16 = 0;
    var item_size: u16 = 0;
    var caret_size: u16 = 0;
    for (cmds) |c| {
        if (c.command_type != .text) continue;
        const slice = c.render_data.text.string_contents;
        const bytes = slice.chars[0..@intCast(slice.length)];
        if (std.mem.eql(u8, bytes, "Group")) group_size = c.render_data.text.font_size;
        if (std.mem.eql(u8, bytes, "Item")) item_size = c.render_data.text.font_size;
        if (std.mem.eql(u8, bytes, "-")) caret_size = c.render_data.text.font_size;
    }
    // The font has one weight, so a bolder group is a point larger, and an item keeps label_size.
    try std.testing.expectEqual(@as(u16, 14), group_size);
    try std.testing.expectEqual(@as(u16, 13), item_size);
    try std.testing.expectEqual(@as(u16, 10), caret_size);
}
