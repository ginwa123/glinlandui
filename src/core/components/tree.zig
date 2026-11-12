//! A tree view: rows with depth, a caret, expansion state, selection and a right-aligned meta.

const std = @import("std");
const cl = @import("zclay");
const Color = @import("../color.zig").Color;
const registry = @import("click_registry.zig");
const semantics = @import("../semantics.zig");

/// What a row is, which decides its colour.
pub const RowKind = enum { group, item, leaf };

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
    id: []const u8,
    rows: []const Row,
    row_h: u32 = 24,
    indent: u16 = 13,
    pad_lr: u16 = 6,
    bg: ?Color = null,
    row_bg: Color = Color.rgb(0x1a, 0x1a, 0x1d),
    selected_bg: Color = Color.rgb(0x2d, 0x3a, 0x52),
    hover_bg: Color = Color.rgb(0x22, 0x22, 0x2a),
    fg: Color = Color.rgb(0xd8, 0xd8, 0xdc),
    selected_fg: Color = Color.rgb(0xf0, 0xf0, 0xf4),
    group_fg: Color = Color.rgb(0xf0, 0xf0, 0xf4),
    meta_fg: Color = Color.rgb(0x5a, 0x5a, 0x64),
    caret_fg: Color = Color.rgb(0x5a, 0x5a, 0x64),
    radius: u32 = 4,
    on_select: SelectFn = null,
    ctx: ?*anyopaque = null,
    click_z: i16 = 0,
};

/// The element id of row `i`. `+1` so row 0 never collides with the container's own id.
fn rowId(base: []const u8, i: usize) cl.ElementId {
    return cl.ElementId.IDI(base, @as(u32, @intCast(i + 1)));
}

/// The element id of a row's inner box, offset far enough that it cannot collide with a row.
fn innerId(base: []const u8, i: usize, slot: u32) cl.ElementId {
    return cl.ElementId.IDI(base, @as(u32, @intCast(i + 1)) + slot * 0x10000);
}

/// Declare a tree: one clickable row per entry, indented by `depth`.
pub fn tree(props: TreeProps) void {
    semantics.register(.{
        .id = cl.getElementId(props.id),
        .tag = props.id,
        .role = .list,
        .flags = .{ .enabled = true },
    });

    cl.UI()(.{
        .id = .ID(props.id),
        .layout = .{
            .direction = .top_to_bottom,
            .sizing = .{ .w = .grow, .h = .fit },
            .child_gap = 0,
        },
        .background_color = if (props.bg) |b| b.toClay() else .{ 0, 0, 0, 0 },
    })({
        for (props.rows, 0..) |row, i| rowUi(props, row, i);
    });
}

fn rowUi(props: TreeProps, row: Row, i: usize) void {
    const fg = if (row.selected)
        props.selected_fg
    else if (row.kind == .group)
        props.group_fg
    else
        props.fg;
    const base_bg = if (row.selected) props.selected_bg else props.row_bg;

    cl.UI()(.{
        .id = .IDI(props.id, @as(u32, @intCast(i + 1))),
        .layout = .{
            .direction = .left_to_right,
            .sizing = .{ .w = .grow, .h = .fixed(@floatFromInt(props.row_h)) },
            .padding = .{
                .left = props.pad_lr + row.depth * props.indent,
                .right = props.pad_lr,
            },
            .child_alignment = .{ .x = .left, .y = .center },
            .child_gap = 6,
        },
        .background_color = (if (!row.selected and cl.hovered()) props.hover_bg else base_bg).toClay(),
        .corner_radius = .all(@floatFromInt(props.radius)),
    })({
        // A fixed-width caret so labels line up whether or not a row expands.
        cl.text(if (!row.has_children) " " else if (row.expanded) "-" else "+", .{
            .font_size = 12,
            .color = props.caret_fg.toClay(),
        });
        // The label grows, which is what pushes the meta to the right edge.
        cl.UI()(.{
            .id = innerId(props.id, i, 1),
            .layout = .{
                .direction = .left_to_right,
                .sizing = .{ .w = .grow, .h = .grow },
                .child_alignment = .{ .x = .left, .y = .center },
            },
        })({
            cl.text(row.label, .{ .font_size = 13, .color = fg.toClay() });
        });
        if (row.meta.len > 0) {
            cl.text(row.meta, .{ .font_size = 11, .color = props.meta_fg.toClay() });
        }
    });

    semantics.register(.{
        .id = rowId(props.id, i),
        .role = .list_item,
        .flags = .{ .enabled = true, .selected = row.selected },
    });
    if (props.on_select) |cb| {
        registry.registerZCursor(rowId(props.id, i), cb, props.ctx, i, props.click_z, .pointer);
    }
}

// ---- tests ----

fn stubMeasure(s: []const u8, cfg: *cl.TextElementConfig, _: void) cl.Dimensions {
    return .{
        .w = @as(f32, @floatFromInt(s.len)) * @as(f32, @floatFromInt(cfg.font_size)) * 0.6,
        .h = @as(f32, @floatFromInt(cfg.font_size)),
    };
}

fn countCommands(declare_fn: *const fn () void, rects: *usize, texts: *usize) !void {
    const mem_size = cl.minMemorySize();
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

const sample_rows = [_]Row{
    .{ .label = "demo.db", .depth = 0, .has_children = true, .expanded = true, .kind = .group },
    .{ .label = "Tables", .depth = 1, .has_children = true, .expanded = true, .kind = .group },
    .{ .label = "users", .depth = 2, .meta = "1,284" },
    .{ .label = "orders", .depth = 2, .meta = "512", .selected = true },
};

fn declareSample() void {
    tree(.{ .id = "t", .rows = &sample_rows });
}

test "a tree draws one row per entry, plus the container" {
    var rects: usize = 0;
    var texts: usize = 0;
    try countCommands(declareSample, &rects, &texts);
    // One rect per row: the container and the label boxes are transparent, so they emit none.
    try std.testing.expectEqual(sample_rows.len, rects);
    // A caret and a label per row, plus a meta on the two that carry one.
    try std.testing.expectEqual(sample_rows.len * 2 + 2, texts);
}

test "an empty tree still declares its container" {
    var rects: usize = 0;
    var texts: usize = 0;
    try countCommands(declareEmpty, &rects, &texts);
    try std.testing.expectEqual(@as(usize, 0), rects);
    try std.testing.expectEqual(@as(usize, 0), texts);
}

fn declareEmpty() void {
    tree(.{ .id = "t-empty", .rows = &.{} });
}
