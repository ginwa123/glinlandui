// Agnostic reusable Clay list (toolkit-style, library only).
// Generic over the item type: callers pass any slice + a comptime render
// callback. Selection is caller-owned by index (props.selected).
// Imports: std + zclay + core/render_common + sibling components ONLY.
// Never: app/theme/layout/views/content/sidebar.
const std = @import("std");
const cl = @import("zclay");
const render = @import("../render_common.zig");
const registry = @import("click_registry.zig");
const semantics = @import("../semantics.zig");

/// Selection callback: plain fn pointer + opaque ctx (no closures).
/// Stored in ListProps (declare-only list never fires it); the owner
/// (views/host) reads the built props back and fires
/// `props.on_select(props.ctx, i)` on pointer dispatch.
pub const ListSelectFn = ?*const fn (?*anyopaque, usize) void;

/// Per-row click target (re-exported from the click registry so pages
/// import list only). See click_registry.RowClick.
pub const RowClick = registry.RowClick;

/// List layout direction: vertical (rows top-to-bottom), horizontal
/// (cells left-to-right in one row), or grid (rows of `cols` cells).
pub const Direction = enum {
    vertical,
    horizontal,
    grid,
};

/// List props. All styling via props with neutral dark defaults.
/// `radius` rounds each row; `gap` separates rows (child_gap of the
/// list container — callers nested in a gapped column pass the same
/// gap so wrapped rows keep their original pitch).
/// `selected` is caller-owned selection by index (null = none).
/// `on_select`/`ctx` are stored verbatim for owner-side dispatch.
pub const ListProps = struct {
    id: []const u8,
    direction: Direction = .vertical,
    /// Grid only: fixed column count for this frame (see gridCols).
    cols: usize = 3,
    /// Grid only: fixed cell size in px (see gridCell).
    cell_w: u32 = 140,
    cell_h: u32 = 78,
    row_h: u32 = 40,
    row_bg: u32 = 0x1e1e1e,
    selected_bg: u32 = 0x3a3a3a,
    row_fg: u32 = 0xe8e8e8,
    selected_fg: u32 = 0xffffff,
    hover_bg: u32 = 0x2d2d2d,
    radius: u32 = 4,
    gap: u16 = 0,
    /// Container width clamps (grow axis, 0 = no constraint).
    min_w: f32 = 0,
    max_w: f32 = 0,
    /// Row height clamps (0 = no constraint; clamps row_h per row).
    row_min_h: f32 = 0,
    row_max_h: f32 = 0,
    /// Uniform row border (0 = none) + color; emits a Clay BORDER per row.
    border_width: u16 = 0,
    border_color: u32 = 0x000000,
    /// Grid/horizontal cell fill (null = transparent, e.g. image grids).
    /// Vertical rows always use row_bg/selected_bg/hover_bg.
    cell_bg: ?u32 = null,
    /// Grid/horizontal selected ring (0 = none; vertical rows show
    /// selected_bg instead and ignore these unless border_width is set).
    selected_border_width: u16 = 0,
    selected_border_color: u32 = 0x7ab8ff,
    /// Grid/horizontal hover ring on enabled unselected cells (0 = none;
    /// vertical rows show hover_bg instead).
    hover_border_width: u16 = 0,
    hover_border_color: u32 = 0x5a5a5a,
    /// Disabled list: rows render `disabled_bg`, never take hover chrome,
    /// and register no clicks (declare never fires; owners must also check).
    disabled: bool = false,
    disabled_bg: u32 = 0x1a1a1a,
    selected: ?usize = null,
    on_select: ListSelectFn = null,
    ctx: ?*anyopaque = null,
    /// Per-row clicks (Stage B): when non-null, row i registers
    /// clicks[i] (guard i < clicks.len; rows beyond get no entry).
    /// When null, the legacy on_select path is unchanged.
    clicks: ?[]const RowClick = null,
    /// Dispatch priority for this list's rows: highest-z containing match
    /// wins regardless of declare order (overlay dropdowns float above
    /// in-flow rows). Default 0.
    click_z: i16 = 0,
};

fn rowHeight(props: ListProps) f32 {
    var h: f32 = @floatFromInt(props.row_h);
    if (props.row_min_h > 0 and h < props.row_min_h) h = props.row_min_h;
    if (props.row_max_h > 0 and h > props.row_max_h) h = props.row_max_h;
    return h;
}

fn listSizingW(props: ListProps) cl.SizingAxis {
    if (props.min_w > 0 or props.max_w > 0) return .growMinMax(.{ .min = props.min_w, .max = props.max_w });
    return .grow;
}

/// Pure: responsive grid column count for a content width. 2 cols
/// under 420px, 3 under 640px, else 4 (clamped 2..4 so narrow windows
/// get big cards and wide windows stay within click-slot caps).
pub fn gridCols(content_w: u32) usize {
    if (content_w < 420) return 2;
    if (content_w < 640) return 3;
    return 4;
}

/// Pure: grid cell size filling content_w with `cols` columns at `gap`
/// px. 16:9 cells. Returns [w, h] (min 1).
pub fn gridCell(content_w: u32, cols: usize, gap: u16) [2]u32 {
    const c: u32 = @intCast(@max(cols, 1));
    const g: u32 = gap;
    const total_gap = (c - 1) * g;
    const w: u32 = if (content_w > total_gap) (content_w - total_gap) / c else 1;
    const h: u32 = @max((w * 9) / 16, 1);
    return .{ @max(w, 1), h };
}

/// Declare a list over any slice: container (.ID(props.id)) + one cell
/// per item (.IDI(props.id, index + 1)).
///
/// Direction branches:
/// - vertical: rows top-to-bottom (existing behavior, pixel parity).
///   Row chrome: bg = selected ? selected_bg : hover ? hover_bg :
///   row_bg (hover via cl.hovered() inside the row literal).
/// - horizontal: cells left-to-right in one row (fixed height row_h,
///   fit width). Same bg chrome as vertical rows.
/// - grid: rows of `cols` fixed cells (cell_w × cell_h). Cells are
///   transparent unless cell_bg is set; the selected index draws the
///   selected ring, a hovered enabled unselected cell draws the hover
///   ring (both evaluated inside the cell literal).
///
/// Content is declared by the caller's comptime
/// `renderItem(item_ctx, items[i], i)`. Text color stays the render
/// callback's job (list owns bg/border chrome only).
///
/// The +1 cell-ID offset is load-bearing: Clay defines
/// `CLAY_ID(x) == CLAY_IDI(x, 0)`, so cell 0 as IDI(props.id, 0) would
/// collide with the container .ID(props.id). Cells are therefore
/// IDI(base, 1..N) for items 0..N-1 — same scheme, unique identities.
///
/// `items` must be a slice (comptime-asserted, else @compileError).
/// Click/selection handling stays owner-side: the owner stores the
/// built ListProps and fires on_select on pointer dispatch; list()
/// itself never fires callbacks and never mutates selection.
pub fn list(
    props: ListProps,
    items: anytype,
    item_ctx: anytype,
    comptime renderItem: fn (@TypeOf(item_ctx), std.meta.Child(@TypeOf(items)), usize) void,
) void {
    const ItemsT = @TypeOf(items);
    const ti = @typeInfo(ItemsT);
    if (ti != .pointer or ti.pointer.size != .slice) @compileError("list: items must be a slice");
    // Semantics: the container is a list; each cell registers itself below.
    semantics.register(.{
        .id = cl.getElementId(props.id),
        .tag = props.id,
        .role = .list,
        .flags = .{ .enabled = !props.disabled },
    });
    switch (props.direction) {
        .vertical => listVertical(props, items, item_ctx, renderItem),
        .horizontal => listHorizontal(props, items, item_ctx, renderItem),
        .grid => listGrid(props, items, item_ctx, renderItem),
    }
}

/// Shared click wiring for one cell/row (Stage B clicks win over the
/// legacy on_select; disabled registers nothing so hover stays .default).
/// Rows that register use the .pointer cursor.
fn registerCell(props: ListProps, i: usize) void {
    // Semantics FIRST, before the disabled early-return: a disabled row must
    // still be discoverable so `assertIsDisabled` has something to assert on.
    // Rows carry no label of their own (the text comes from the caller's
    // renderItem), so tests select them by container plus index:
    //     onNodeWithIndex(.{ .role = .list_item }, 3)
    semantics.register(.{
        .id = rowId(props.id, i),
        .role = .list_item,
        .flags = .{
            .enabled = !props.disabled,
            .selected = (props.selected != null and props.selected.? == i),
        },
    });
    if (props.disabled) return;
    if (props.clicks) |clicks| {
        if (i < clicks.len) {
            registry.registerZCursor(rowId(props.id, i), clicks[i].on_click, clicks[i].ctx, i, props.click_z, .pointer);
        }
    } else if (props.on_select) |cb| {
        registry.registerZCursor(rowId(props.id, i), cb, props.ctx, i, props.click_z, .pointer);
    }
}

fn listVertical(
    props: ListProps,
    items: anytype,
    item_ctx: anytype,
    comptime renderItem: fn (@TypeOf(item_ctx), std.meta.Child(@TypeOf(items)), usize) void,
) void {
    cl.UI()(.{
        .id = .ID(props.id),
        .layout = .{
            .direction = .top_to_bottom,
            .sizing = .{ .w = listSizingW(props), .h = .fit },
            .child_gap = props.gap,
        },
    })({
        for (items, 0..) |item, i| {
            const is_sel: bool = if (props.selected) |sel| sel == i else false;
            const base_bg: u32 = if (props.disabled) props.disabled_bg else if (is_sel) props.selected_bg else props.row_bg;
            // NOTE: cl.hovered() must be evaluated INSIDE this row's UI()
            // config literal (while the row element is open) so it queries
            // this row — calling it beforehand would query the list
            // container instead and leak hover_bg to every unselected row.
            cl.UI()(.{
                // +1: CLAY_ID(base) == CLAY_IDI(base, 0) — row i takes
                // IDI(base, i + 1) so row 0 never collides with the
                // container .ID(props.id) above.
                .id = .IDI(props.id, @as(u32, @intCast(i + 1))),
                .layout = .{
                    .direction = .left_to_right,
                    .sizing = .{ .w = .grow, .h = .fixed(rowHeight(props)) },
                    .padding = .axes(8, 12),
                    .child_alignment = .{ .x = .left, .y = .center },
                    .child_gap = 8,
                },
                .background_color = render.u32ToClayColor(if (!props.disabled and !is_sel and cl.hovered()) props.hover_bg else base_bg),
                .corner_radius = .all(@floatFromInt(props.radius)),
                .border = if (props.border_width > 0) .{
                    .color = render.u32ToClayColor(props.border_color),
                    .width = .outside(props.border_width),
                } else .{},
            })({
                renderItem(item_ctx, item, i);
            });
            registerCell(props, i);
        }
    });
}

fn listHorizontal(
    props: ListProps,
    items: anytype,
    item_ctx: anytype,
    comptime renderItem: fn (@TypeOf(item_ctx), std.meta.Child(@TypeOf(items)), usize) void,
) void {
    cl.UI()(.{
        .id = .ID(props.id),
        .layout = .{
            .direction = .left_to_right,
            .sizing = .{ .w = listSizingW(props), .h = .fit },
            .child_gap = props.gap,
        },
    })({
        for (items, 0..) |item, i| {
            const is_sel: bool = if (props.selected) |sel| sel == i else false;
            const base_bg: u32 = if (props.disabled) props.disabled_bg else if (is_sel) props.selected_bg else props.row_bg;
            cl.UI()(.{
                .id = .IDI(props.id, @as(u32, @intCast(i + 1))),
                .layout = .{
                    .direction = .left_to_right,
                    .sizing = .{ .w = .fit, .h = .fixed(rowHeight(props)) },
                    .padding = .axes(8, 12),
                    .child_alignment = .{ .x = .center, .y = .center },
                    .child_gap = 8,
                },
                .background_color = render.u32ToClayColor(if (!props.disabled and !is_sel and cl.hovered()) props.hover_bg else base_bg),
                .corner_radius = .all(@floatFromInt(props.radius)),
                .border = if (props.border_width > 0) .{
                    .color = render.u32ToClayColor(props.border_color),
                    .width = .outside(props.border_width),
                } else .{},
            })({
                renderItem(item_ctx, item, i);
            });
            registerCell(props, i);
        }
    });
}

fn listGrid(
    props: ListProps,
    items: anytype,
    item_ctx: anytype,
    comptime renderItem: fn (@TypeOf(item_ctx), std.meta.Child(@TypeOf(items)), usize) void,
) void {
    const cols = @max(props.cols, 1);
    cl.UI()(.{
        .id = .ID(props.id),
        .layout = .{
            .direction = .top_to_bottom,
            .sizing = .{ .w = listSizingW(props), .h = .fit },
            .child_gap = props.gap,
        },
    })({
        var row: usize = 0;
        while (row * cols < items.len) : (row += 1) {
            // Row boxes are layout-only (no id — hit-testing lives on
            // the cells, so no identity is needed here).
            cl.UI()(.{
                .layout = .{
                    .direction = .left_to_right,
                    .sizing = .{ .w = .grow, .h = .fit },
                    .child_gap = props.gap,
                },
            })({
                var col: usize = 0;
                while (col < cols) : (col += 1) {
                    const i = row * cols + col;
                    if (i >= items.len) break;
                    const item = items[i];
                    const is_sel: bool = if (props.selected) |sel| sel == i else false;
                    cl.UI()(.{
                        .id = .IDI(props.id, @as(u32, @intCast(i + 1))),
                        .layout = .{
                            .direction = .left_to_right,
                            .sizing = .{ .w = .fixed(@floatFromInt(props.cell_w)), .h = .fixed(@floatFromInt(props.cell_h)) },
                            .child_alignment = .{ .x = .center, .y = .center },
                        },
                        .background_color = if (props.cell_bg) |bg| render.u32ToClayColor(bg) else .{ 0, 0, 0, 0 },
                        .corner_radius = .all(@floatFromInt(props.radius)),
                        // Selected ring wins; hover ring only on enabled
                        // unselected cells (evaluated inside the literal).
                        .border = if (is_sel and props.selected_border_width > 0) .{
                            .color = render.u32ToClayColor(props.selected_border_color),
                            .width = .outside(props.selected_border_width),
                        } else if (!props.disabled and !is_sel and props.hover_border_width > 0 and cl.hovered()) .{
                            .color = render.u32ToClayColor(props.hover_border_color),
                            .width = .outside(props.hover_border_width),
                        } else .{},
                    })({
                        renderItem(item_ctx, item, i);
                    });
                    registerCell(props, i);
                }
            });
        }
    });
}

// Stub text estimator for headless tests (no font backend needed).
fn stubMeasure(s: []const u8, cfg: *cl.TextElementConfig, _: void) cl.Dimensions {
    return .{
        .w = @as(f32, @floatFromInt(s.len)) * @as(f32, @floatFromInt(cfg.font_size)) * 0.6,
        .h = @as(f32, @floatFromInt(cfg.font_size)),
    };
}

// ---- Generic test fixtures: TWO different item types prove anytype ----

/// Item type A: struct with title (+ optional subtitle).
const TitleItem = struct {
    title: []const u8,
    subtitle: ?[]const u8 = null,
};

const CtxA = struct {
    fg: u32,
};

fn renderA(ctx: CtxA, item: TitleItem, index: usize) void {
    _ = index;
    cl.text(item.title, .{
        .font_size = 14,
        .color = render.u32ToClayColor(ctx.fg),
    });
    if (item.subtitle) |sub| {
        cl.text(sub, .{
            .font_size = 12,
            .color = render.u32ToClayColor(ctx.fg),
        });
    }
}

const demo_items = [_]TitleItem{
    .{ .title = "Alpha" },
    .{ .title = "Beta" },
    .{ .title = "Gamma" },
};

// NOTE (Zig 0.16): `arr[0..]` on a const global folds to *const [N]T,
// not a slice — so every call site coerces through an explicitly typed
// slice const (still static: points at the static array). list() takes
// true slices only (comptime-asserted).
const demo_slice: []const TitleItem = &demo_items;

fn declareList() void {
    list(.{ .id = "test-list" }, demo_slice, CtxA{ .fg = 0xe8e8e8 }, renderA);
}

const sub_items = [_]TitleItem{
    .{ .title = "One", .subtitle = "first" },
    .{ .title = "Two", .subtitle = "second" },
};

const sub_slice: []const TitleItem = &sub_items;

fn declareSubList() void {
    list(.{ .id = "test-sub-list" }, sub_slice, CtxA{ .fg = 0xe8e8e8 }, renderA);
}

/// Item type B: plain strings with a trailing chevron (content parity).
const str_items = [_][]const u8{ "One", "Two" };

const str_slice: []const []const u8 = &str_items;

fn renderB(_: void, item: []const u8, index: usize) void {
    _ = index;
    cl.text(item, .{
        .font_size = 14,
        .color = render.u32ToClayColor(0xe8e8e8),
    });
    cl.UI()(.{
        .layout = .{ .sizing = .grow },
    })({});
    cl.text(">", .{
        .font_size = 14,
        .color = render.u32ToClayColor(0xe8e8e8),
    });
}

fn declareStrList() void {
    list(.{ .id = "test-str-list" }, str_slice, {}, renderB);
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
    // Park the pointer far outside the layout so hovered() is false and
    // the test observes the resting bg path deterministically.
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

test "generic list with struct items emits 3 row rectangles + title texts" {
    var rects: usize = 0;
    var texts: usize = 0;
    try countCommands(declareList, &rects, &texts);
    try std.testing.expect(rects >= 3);
    try std.testing.expectEqual(@as(usize, 3), texts);
}

test "generic list renders subtitles as extra text commands" {
    var rects: usize = 0;
    var texts: usize = 0;
    try countCommands(declareSubList, &rects, &texts);
    try std.testing.expect(rects >= 2);
    // 2 titles + 2 subtitles.
    try std.testing.expectEqual(@as(usize, 4), texts);
}

test "generic list with string items renders title + trailing per row" {
    var rects: usize = 0;
    var texts: usize = 0;
    try countCommands(declareStrList, &rects, &texts);
    try std.testing.expect(rects >= 2);
    // 2 titles + 2 trailing chevrons (proves a second item type).
    try std.testing.expectEqual(@as(usize, 4), texts);
}

test "ListProps carries neutral dark defaults + null selection/callbacks" {
    const p = ListProps{ .id = "x" };
    try std.testing.expectEqual(@as(u32, 40), p.row_h);
    try std.testing.expectEqual(@as(u32, 0x1e1e1e), p.row_bg);
    try std.testing.expectEqual(@as(u32, 0x3a3a3a), p.selected_bg);
    try std.testing.expectEqual(@as(u32, 0xe8e8e8), p.row_fg);
    try std.testing.expectEqual(@as(u32, 0xffffff), p.selected_fg);
    try std.testing.expectEqual(@as(u32, 0x2d2d2d), p.hover_bg);
    try std.testing.expectEqual(@as(u32, 4), p.radius);
    try std.testing.expectEqual(@as(u16, 0), p.gap);
    try std.testing.expect(p.selected == null);
    try std.testing.expect(p.on_select == null);
    try std.testing.expect(p.ctx == null);
}

const SelectCtx = struct {
    calls: usize = 0,
    last: ?usize = null,
};

fn testOnSelect(ctx: ?*anyopaque, i: usize) void {
    const c: *SelectCtx = @ptrCast(@alignCast(ctx.?));
    c.calls += 1;
    c.last = i;
}

test "ListProps stores on_select/ctx; direct invocation delivers index" {
    var c = SelectCtx{};
    const p = ListProps{
        .id = "x",
        .selected = 1,
        .on_select = testOnSelect,
        .ctx = &c,
    };
    try std.testing.expectEqual(@as(?usize, 1), p.selected);
    try std.testing.expect(p.on_select != null);
    try std.testing.expect(p.ctx != null);
    p.on_select.?(p.ctx, 2);
    try std.testing.expectEqual(@as(usize, 1), c.calls);
    try std.testing.expectEqual(@as(?usize, 2), c.last);
}

fn rectColorForId(cmds: []cl.RenderCommand, id: u32) ?cl.Color {
    for (cmds) |c| {
        if (c.command_type == .rectangle and c.id == id) return c.render_data.rectangle.background_color;
    }
    return null;
}

/// Row identity for item i (mirrors list()'s +1 IDI offset).
fn rowId(base: []const u8, i: usize) cl.ElementId {
    return cl.ElementId.IDI(base, @as(u32, @intCast(i + 1)));
}

const hover_items = [_]TitleItem{
    .{ .title = "Alpha" },
    .{ .title = "Beta" },
    .{ .title = "Gamma" },
};

const hover_slice: []const TitleItem = &hover_items;

fn declareHoverList() void {
    list(.{ .id = "test-hover-list", .selected = 2 }, hover_slice, CtxA{ .fg = 0xe8e8e8 }, renderA);
}

test "generic list selected index uses selected_bg; hover hits one row" {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);

    const props = ListProps{ .id = "test-hover-list", .selected = 2 };
    const rest_c = render.u32ToClayColor(props.row_bg);
    const hover_c = render.u32ToClayColor(props.hover_bg);
    const sel_c = render.u32ToClayColor(props.selected_bg);

    // Frame 1: pointer parked offscreen — resting row_bg, nothing hovered.
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declareHoverList();
    const cmds1 = cl.endLayout();
    try std.testing.expect(!cl.pointerOver(rowId("test-hover-list", 0)));
    const bg1 = rectColorForId(cmds1, rowId("test-hover-list", 0).id);
    try std.testing.expect(bg1 != null);
    try std.testing.expectEqual(rest_c, bg1.?);
    // Selected row keeps selected_bg even with no hover.
    const sel1 = rectColorForId(cmds1, rowId("test-hover-list", 2).id);
    try std.testing.expect(sel1 != null);
    try std.testing.expectEqual(sel_c, sel1.?);

    // Frame 2: pointer over row-0 center (frame-1 box). Only row-0 takes
    // hover_bg; the sibling unselected row keeps row_bg and the selected
    // row keeps selected_bg.
    const box = cl.getElementData(rowId("test-hover-list", 0)).bounding_box;
    cl.setPointerState(.{ .x = box.x + box.width * 0.5, .y = box.y + box.height * 0.5 }, false);
    cl.beginLayout();
    declareHoverList();
    const cmds2 = cl.endLayout();
    try std.testing.expect(cl.pointerOver(rowId("test-hover-list", 0)));
    try std.testing.expect(!cl.pointerOver(rowId("test-hover-list", 1)));
    const bg_row0 = rectColorForId(cmds2, rowId("test-hover-list", 0).id);
    const bg_row1 = rectColorForId(cmds2, rowId("test-hover-list", 1).id);
    const bg_row2 = rectColorForId(cmds2, rowId("test-hover-list", 2).id);
    try std.testing.expect(bg_row0 != null);
    try std.testing.expect(bg_row1 != null);
    try std.testing.expect(bg_row2 != null);
    try std.testing.expectEqual(hover_c, bg_row0.?);
    try std.testing.expectEqual(rest_c, bg_row1.?);
    try std.testing.expectEqual(sel_c, bg_row2.?);
}

// ---- Agnostic extensions for app wiring (sidebar/content parity) ----

/// Run one headless Clay frame around `declare_fn`, returning the render
/// commands (valid until the next beginLayout).
fn layoutCommands(declare_fn: *const fn () void) ![]cl.RenderCommand {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declare_fn();
    return cl.endLayout();
}

fn rectDataForId(cmds: []cl.RenderCommand, id: u32) ?cl.RectangleRenderData {
    for (cmds) |c| {
        if (c.command_type == .rectangle and c.id == id) return c.render_data.rectangle;
    }
    return null;
}

const gap_items = [_]TitleItem{
    .{ .title = "A" },
    .{ .title = "B" },
};

const gap_slice: []const TitleItem = &gap_items;

fn declareGapList() void {
    list(.{ .id = "test-gap-list", .gap = 8 }, gap_slice, CtxA{ .fg = 0xe8e8e8 }, renderA);
}

fn declareNoGapList() void {
    list(.{ .id = "test-nogap-list" }, gap_slice, CtxA{ .fg = 0xe8e8e8 }, renderA);
}

fn pitchFor(declare_fn: *const fn () void, base: []const u8) !f32 {
    const cmds = try layoutCommands(declare_fn);
    _ = cmds;
    const y0 = cl.getElementData(rowId(base, 0)).bounding_box.y;
    const y1 = cl.getElementData(rowId(base, 1)).bounding_box.y;
    return y1 - y0;
}

test "list gap separates rows by row_h + gap" {
    // Default row_h 40, no gap: pitch 40.
    try std.testing.expectEqual(@as(f32, 40), try pitchFor(declareNoGapList, "test-nogap-list"));
    // gap 8 (content parity): pitch 48.
    try std.testing.expectEqual(@as(f32, 48), try pitchFor(declareGapList, "test-gap-list"));
}

fn declareRadiusList() void {
    list(.{ .id = "test-radius-list", .radius = 12 }, gap_slice, CtxA{ .fg = 0xe8e8e8 }, renderA);
}

test "list radius prop reaches row rects" {
    const cmds_default = try layoutCommands(declareNoGapList);
    const rect_default = rectDataForId(cmds_default, rowId("test-nogap-list", 0).id);
    try std.testing.expect(rect_default != null);
    try std.testing.expectEqual(@as(f32, 4), rect_default.?.corner_radius.top_left);

    const cmds_custom = try layoutCommands(declareRadiusList);
    const rect_custom = rectDataForId(cmds_custom, rowId("test-radius-list", 0).id);
    try std.testing.expect(rect_custom != null);
    try std.testing.expectEqual(@as(f32, 12), rect_custom.?.corner_radius.top_left);
}

test "list indexed rows declare IDI identities under the list id" {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);

    // Frame 1: pointer parked offscreen — both IDI rows exist but idle.
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declareGapList();
    _ = cl.endLayout();
    try std.testing.expect(cl.getElementData(rowId("test-gap-list", 0)).found);
    try std.testing.expect(cl.getElementData(rowId("test-gap-list", 1)).found);
    try std.testing.expect(!cl.pointerOver(rowId("test-gap-list", 0)));

    // Frame 2: pointer over row-0 center — only row 0 reports hover.
    const box = cl.getElementData(rowId("test-gap-list", 0)).bounding_box;
    cl.setPointerState(.{ .x = box.x + box.width * 0.5, .y = box.y + box.height * 0.5 }, false);
    cl.beginLayout();
    declareGapList();
    _ = cl.endLayout();
    try std.testing.expect(cl.pointerOver(rowId("test-gap-list", 0)));
    try std.testing.expect(!cl.pointerOver(rowId("test-gap-list", 1)));
}

var select_rec = SelectCtx{};

fn declareSelectList() void {
    list(.{ .id = "test-select-list", .on_select = testOnSelect, .ctx = &select_rec }, demo_slice, CtxA{ .fg = 0xe8e8e8 }, renderA);
}

test "list self-registers on_select per row; dispatchClick fires index" {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    select_rec = .{};
    registry.beginFrame();
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declareSelectList();
    _ = cl.endLayout();
    const bb = cl.getElementData(rowId("test-select-list", 2)).bounding_box;
    try std.testing.expect(registry.dispatchClick(bb.x + bb.width * 0.5, bb.y + bb.height * 0.5));
    try std.testing.expectEqual(@as(usize, 1), select_rec.calls);
    try std.testing.expectEqual(@as(?usize, 2), select_rec.last);
    try std.testing.expect(!registry.dispatchClick(700, 460));
    try std.testing.expectEqual(@as(usize, 1), select_rec.calls);
}

fn declareNoSelectList() void {
    list(.{ .id = "test-noselect-list" }, demo_slice, CtxA{ .fg = 0xe8e8e8 }, renderA);
}

test "list without on_select registers nothing; dispatchClick returns false" {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    registry.beginFrame();
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declareNoSelectList();
    _ = cl.endLayout();
    const bb = cl.getElementData(rowId("test-noselect-list", 1)).bounding_box;
    try std.testing.expect(cl.getElementData(rowId("test-noselect-list", 1)).found);
    try std.testing.expect(!registry.dispatchClick(bb.x + bb.width * 0.5, bb.y + bb.height * 0.5));
}

// ---- Per-row clicks (Stage B): distinct fn+ctx per row ----

const ClickRec = struct {
    calls: usize = 0,
    last: ?usize = null,
};

var clicks_a = ClickRec{};
var clicks_b = ClickRec{};

fn onClickA(ctx: ?*anyopaque, i: usize) void {
    const c: *ClickRec = @ptrCast(@alignCast(ctx.?));
    c.calls += 1;
    c.last = i;
}

fn onClickB(ctx: ?*anyopaque, i: usize) void {
    const c: *ClickRec = @ptrCast(@alignCast(ctx.?));
    c.calls += 1;
    c.last = i;
}

fn declareClicksList() void {
    const clicks = [_]registry.RowClick{
        .{ .on_click = onClickA, .ctx = &clicks_a },
        .{ .on_click = onClickB, .ctx = &clicks_b },
    };
    list(.{ .id = "test-clicks-list", .clicks = &clicks }, gap_slice, CtxA{ .fg = 0xe8e8e8 }, renderA);
}

fn declareShortClicksList() void {
    const clicks = [_]registry.RowClick{
        .{ .on_click = onClickA, .ctx = &clicks_a },
    };
    list(.{ .id = "test-short-clicks-list", .clicks = &clicks }, gap_slice, CtxA{ .fg = 0xe8e8e8 }, renderA);
}

test "list clicks fires each row own fn once with own ctx" {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    clicks_a = .{};
    clicks_b = .{};
    registry.beginFrame();
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declareClicksList();
    _ = cl.endLayout();
    const bb0 = cl.getElementData(rowId("test-clicks-list", 0)).bounding_box;
    try std.testing.expect(registry.dispatchClick(bb0.x + bb0.width * 0.5, bb0.y + bb0.height * 0.5));
    try std.testing.expectEqual(@as(usize, 1), clicks_a.calls);
    try std.testing.expectEqual(@as(?usize, 0), clicks_a.last);
    try std.testing.expectEqual(@as(usize, 0), clicks_b.calls);
    const bb1 = cl.getElementData(rowId("test-clicks-list", 1)).bounding_box;
    try std.testing.expect(registry.dispatchClick(bb1.x + bb1.width * 0.5, bb1.y + bb1.height * 0.5));
    try std.testing.expectEqual(@as(usize, 1), clicks_b.calls);
    try std.testing.expectEqual(@as(?usize, 1), clicks_b.last);
    try std.testing.expectEqual(@as(usize, 1), clicks_a.calls);
}

test "list clicks short slice leaves extra rows without entry" {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    clicks_a = .{};
    clicks_b = .{};
    registry.beginFrame();
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declareShortClicksList();
    _ = cl.endLayout();
    const bb0 = cl.getElementData(rowId("test-short-clicks-list", 0)).bounding_box;
    try std.testing.expect(registry.dispatchClick(bb0.x + bb0.width * 0.5, bb0.y + bb0.height * 0.5));
    try std.testing.expectEqual(@as(usize, 1), clicks_a.calls);
    const bb1 = cl.getElementData(rowId("test-short-clicks-list", 1)).bounding_box;
    try std.testing.expect(!registry.dispatchClick(bb1.x + bb1.width * 0.5, bb1.y + bb1.height * 0.5));
    try std.testing.expectEqual(@as(usize, 1), clicks_a.calls);
}

fn declareDisabledList() void {
    list(.{ .id = "test-disabled-list", .disabled = true, .on_select = testOnSelect, .ctx = &disabled_rec }, demo_slice, CtxA{ .fg = 0xe8e8e8 }, renderA);
}

var disabled_rec = SelectCtx{};

test "disabled list registers no clicks and dims rows" {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    disabled_rec = .{};
    registry.beginFrame();
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declareDisabledList();
    const cmds = cl.endLayout();
    const dim = render.u32ToClayColor(0x1a1a1a);
    const bg0 = rectColorForId(cmds, rowId("test-disabled-list", 0).id);
    try std.testing.expect(bg0 != null);
    try std.testing.expectEqual(dim, bg0.?);
    const bb = cl.getElementData(rowId("test-disabled-list", 0)).bounding_box;
    try std.testing.expect(!registry.dispatchClick(bb.x + bb.width * 0.5, bb.y + bb.height * 0.5));
    try std.testing.expectEqual(@as(usize, 0), disabled_rec.calls);
}

// ---- Horizontal + grid directions ----

test "ListProps direction defaults to vertical with grid sizing defaults" {
    const p = ListProps{ .id = "x" };
    try std.testing.expectEqual(Direction.vertical, p.direction);
    try std.testing.expectEqual(@as(usize, 3), p.cols);
    try std.testing.expectEqual(@as(u32, 140), p.cell_w);
    try std.testing.expectEqual(@as(u32, 78), p.cell_h);
    try std.testing.expect(p.cell_bg == null);
    try std.testing.expectEqual(@as(u16, 0), p.selected_border_width);
    try std.testing.expectEqual(@as(u16, 0), p.hover_border_width);
}

test "gridCols adapts 2/3/4 across breakpoints" {
    try std.testing.expectEqual(@as(usize, 2), gridCols(0));
    try std.testing.expectEqual(@as(usize, 2), gridCols(300));
    try std.testing.expectEqual(@as(usize, 2), gridCols(419));
    try std.testing.expectEqual(@as(usize, 3), gridCols(420));
    try std.testing.expectEqual(@as(usize, 3), gridCols(639));
    try std.testing.expectEqual(@as(usize, 4), gridCols(640));
    try std.testing.expectEqual(@as(usize, 4), gridCols(1200));
}

test "gridCell fills width at 16:9" {
    // 3 cols in 479px: (479 - 16) / 3 = 154 wide, 86 tall.
    try std.testing.expectEqual([2]u32{ 154, 86 }, gridCell(479, 3, 8));
    // 2 cols in 300px: (300 - 8) / 2 = 146 wide, 82 tall.
    try std.testing.expectEqual([2]u32{ 146, 82 }, gridCell(300, 2, 8));
    try std.testing.expectEqual([2]u32{ 1, 1 }, gridCell(0, 3, 8));
}

const h_items = [_]TitleItem{
    .{ .title = "A" },
    .{ .title = "B" },
    .{ .title = "C" },
};

const h_slice: []const TitleItem = &h_items;

fn declareHList() void {
    list(.{ .id = "test-h-list", .direction = .horizontal }, h_slice, CtxA{ .fg = 0xe8e8e8 }, renderA);
}

test "horizontal list lays cells in one row with advancing x" {
    const cmds = try layoutCommands(declareHList);
    var texts: usize = 0;
    for (cmds) |c| if (c.command_type == .text) {
        texts += 1;
    };
    try std.testing.expectEqual(@as(usize, 3), texts);
    const y0 = cl.getElementData(rowId("test-h-list", 0)).bounding_box.y;
    const y1 = cl.getElementData(rowId("test-h-list", 1)).bounding_box.y;
    const y2 = cl.getElementData(rowId("test-h-list", 2)).bounding_box.y;
    try std.testing.expectApproxEqAbs(y0, y1, 0.5);
    try std.testing.expectApproxEqAbs(y0, y2, 0.5);
    const x0 = cl.getElementData(rowId("test-h-list", 0)).bounding_box.x;
    const x1 = cl.getElementData(rowId("test-h-list", 1)).bounding_box.x;
    try std.testing.expect(x1 > x0 + 10);
}

const g_items = [_]TitleItem{
    .{ .title = "a" },
    .{ .title = "b" },
    .{ .title = "c" },
    .{ .title = "d" },
    .{ .title = "e" },
};

const g_slice: []const TitleItem = &g_items;

fn declareGrid() void {
    list(.{ .id = "test-grid", .direction = .grid, .cols = 3, .cell_w = 100, .cell_h = 60 }, g_slice, CtxA{ .fg = 0xe8e8e8 }, renderA);
}

test "grid wraps 5 items in 3 cols with transparent cells" {
    const cmds = try layoutCommands(declareGrid);
    var texts: usize = 0;
    var rects: usize = 0;
    for (cmds) |c| switch (c.command_type) {
        .text => texts += 1,
        .rectangle => rects += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 5), texts);
    try std.testing.expectEqual(@as(usize, 0), rects);
    const y0 = cl.getElementData(rowId("test-grid", 0)).bounding_box.y;
    const y2 = cl.getElementData(rowId("test-grid", 2)).bounding_box.y;
    const y3 = cl.getElementData(rowId("test-grid", 3)).bounding_box.y;
    const y4 = cl.getElementData(rowId("test-grid", 4)).bounding_box.y;
    try std.testing.expectApproxEqAbs(y0, y2, 0.5);
    try std.testing.expect(y3 > y0 + 10);
    // Last row holds items 3..4 side by side.
    try std.testing.expectApproxEqAbs(y3, y4, 0.5);
    const x3 = cl.getElementData(rowId("test-grid", 3)).bounding_box.x;
    const x4 = cl.getElementData(rowId("test-grid", 4)).bounding_box.x;
    try std.testing.expect(x4 > x3 + 10);
}

fn gridBorderForId(cmds: []cl.RenderCommand, id: u32) ?cl.BorderRenderData {
    for (cmds) |c| {
        if (c.command_type == .border and c.id == id) return c.render_data.border;
    }
    return null;
}

fn declareSelGrid() void {
    list(
        .{ .id = "test-sel-grid", .direction = .grid, .cols = 3, .cell_w = 100, .cell_h = 60, .selected = 1, .selected_border_width = 2 },
        g_slice,
        CtxA{ .fg = 0xe8e8e8 },
        renderA,
    );
}

test "grid selected cell draws the selected ring, others none" {
    const cmds = try layoutCommands(declareSelGrid);
    // NOTE: Clay tags border commands with a derived id (not the cell
    // element id), so match by count + color instead of by id.
    var borders: usize = 0;
    for (cmds) |c| {
        if (c.command_type != .border) continue;
        borders += 1;
        try std.testing.expectEqual(render.u32ToClayColor(0x7ab8ff), c.render_data.border.color);
    }
    try std.testing.expectEqual(@as(usize, 1), borders);
}

fn declareNoSelGrid() void {
    list(
        .{ .id = "test-nosel-grid", .direction = .grid, .cols = 3, .cell_w = 100, .cell_h = 60, .selected_border_width = 2 },
        g_slice,
        CtxA{ .fg = 0xe8e8e8 },
        renderA,
    );
}

test "grid without selection draws no rings" {
    const cmds = try layoutCommands(declareNoSelGrid);
    for (cmds) |c| {
        try std.testing.expect(c.command_type != .border);
    }
}

test "grid hover draws the hover ring on one cell only" {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    var hover_grid = ListProps{
        .id = "test-hov-grid",
        .direction = .grid,
        .cols = 3,
        .cell_w = 100,
        .cell_h = 60,
        .selected = 1,
        .selected_border_width = 2,
        .hover_border_width = 2,
    };
    _ = &hover_grid;
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    list(hover_grid, g_slice, CtxA{ .fg = 0xe8e8e8 }, renderA);
    _ = cl.endLayout();
    const bb = cl.getElementData(rowId("test-hov-grid", 0)).bounding_box;
    cl.setPointerState(.{ .x = bb.x + bb.width * 0.5, .y = bb.y + bb.height * 0.5 }, false);
    cl.beginLayout();
    list(hover_grid, g_slice, CtxA{ .fg = 0xe8e8e8 }, renderA);
    const cmds = cl.endLayout();
    try std.testing.expect(cl.pointerOver(rowId("test-hov-grid", 0)));
    // One hover ring + the selected ring (matched by color: border
    // commands carry derived ids, not cell element ids).
    var hov_n: usize = 0;
    var sel_n: usize = 0;
    for (cmds) |c| {
        if (c.command_type != .border) continue;
        if (std.meta.eql(c.render_data.border.color, render.u32ToClayColor(0x5a5a5a))) hov_n += 1;
        if (std.meta.eql(c.render_data.border.color, render.u32ToClayColor(0x7ab8ff))) sel_n += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), hov_n);
    try std.testing.expectEqual(@as(usize, 1), sel_n);
}

var grid_click_rec = SelectCtx{};

fn declareClickGrid() void {
    list(
        .{ .id = "test-click-grid", .direction = .grid, .cols = 3, .cell_w = 100, .cell_h = 60, .on_select = testOnSelect, .ctx = &grid_click_rec },
        g_slice,
        CtxA{ .fg = 0xe8e8e8 },
        renderA,
    );
}

test "grid on_select fires with the cell index at its center" {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    grid_click_rec = .{};
    registry.beginFrame();
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declareClickGrid();
    _ = cl.endLayout();
    const bb = cl.getElementData(rowId("test-click-grid", 3)).bounding_box;
    try std.testing.expect(registry.dispatchClick(bb.x + bb.width * 0.5, bb.y + bb.height * 0.5));
    try std.testing.expectEqual(@as(usize, 1), grid_click_rec.calls);
    try std.testing.expectEqual(@as(?usize, 3), grid_click_rec.last);
}
