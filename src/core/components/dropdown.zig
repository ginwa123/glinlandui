// Agnostic reusable Clay dropdown (toolkit-style, library only).
const std = @import("std");
const cl = @import("zclay");
const headless = @import("../testing/headless.zig");
const prop = @import("../props.zig");
const theme_mod = @import("../theme.zig");
const Color = @import("../color.zig").Color;
const registry = @import("click_registry.zig");
const list = @import("list.zig");
const input = @import("input.zig");
const semantics = @import("../semantics.zig");

/// Selection callback: plain fn pointer + opaque ctx (no closures).
pub const DropdownSelectFn = ?*const fn (?*anyopaque, usize) void;

/// Dropdown row kinds: info rows are display-only (search results headers, previews), action rows fire on_select, back rows are rendered without the.
pub const RowKind = enum {
    info,
    action,
    back,
};

/// Case-insensitive substring match for the search filter.
pub fn matches(query: []const u8, item: []const u8) bool {
    if (query.len == 0) return true;
    if (query.len > item.len) return false;
    var i: usize = 0;
    while (i + query.len <= item.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(query, item[i..][0..query.len])) return true;
    }
    return false;
}

/// Filter `items` by query into `out` (caller-owned scratch, must fit items.len).
pub fn filter(query: []const u8, items: []const []const u8, out: []usize) usize {
    var n: usize = 0;
    for (items, 0..) |item, i| {
        if (n >= out.len) break;
        if (matches(query, item)) {
            out[n] = i;
            n += 1;
        }
    }
    return n;
}

/// Toolkit-style dropdown props.
pub const DropdownProps = struct {
    field_id: []const u8 = "",
    list_id: []const u8 = "",
    // Where the app declared this widget: `@src()` at the call site, which the devtool then shows as the declaration.
    src: ?std.builtin.SourceLocation = null,
    /// The search field, when there is one: the app owns it, and the dropdown only paints it. Null draws no field.
    field: ?*input.Field = null,
    font_size: prop.Len = .{ .px = 14 },
    row_h: prop.Len = .{ .px = 40 },
    row_bg: Color = Color.rgb(0x1e, 0x1e, 0x1e),
    selected_bg: Color = Color.rgb(0x3a, 0x3a, 0x3a),
    row_fg: Color = Color.rgb(0xe8, 0xe8, 0xe8),
    hover_bg: Color = Color.rgb(0x2d, 0x2d, 0x2d),
    field_bg: Color = Color.rgb(0x26, 0x26, 0x26),
    // The theme decides the list's corner and the gap between its rows unless the app does.
    radius: prop.Len = prop.Len.themed,
    gap: prop.Len = prop.Len.themed,
    /// Uniform border for the search field + rows (0 = none) + color.
    border_width: prop.Len = .{},
    border_color: Color = Color.rgb(0x00, 0x00, 0x00),
    /// Disabled dropdown: field dims + list takes no hover/clicks.
    disabled: bool = false,
    disabled_bg: Color = Color.rgb(0x1a, 0x1a, 0x1a),
    disabled_fg: Color = Color.rgb(0x77, 0x77, 0x77),
    /// Field sizing: fixed overrides (null = grow/fit) + min/max clamps.
    field_w: ?prop.Len = null,
    field_h: ?prop.Len = null,
    field_min_w: prop.Len = .{},
    field_max_w: prop.Len = .{},
    field_min_h: prop.Len = .{},
    field_max_h: prop.Len = .{},
    /// List sizing clamps (grow container width; row height clamp).
    list_min_w: prop.Len = .{},
    list_max_w: prop.Len = .{},
    row_min_h: prop.Len = .{},
    row_max_h: prop.Len = .{},
    /// Overlay card border (defaults to border_* when 0-width + default color).
    overlay_border_width: prop.Len = .{},
    overlay_border_color: Color = Color.rgb(0x00, 0x00, 0x00),
    on_select: prop.Select = .{},
    /// Per-row clicks passthrough (Stage B): forwarded verbatim to the inner list.
    clicks: ?[]const registry.RowClick = null,
    /// Dispatch priority for inline declares (forwarded to the inner list).
    click_z: i16 = 0,
    /// Overlay mode: when true + anchor_id set, the field + list (+ footer) render in a floating container anchored under IDI(anchor_id, anchor_index + 1).
    overlay: bool = false,
    /// Anchor named by a TEXT id (a standalone trigger): app code cannot build a Clay IDI id, only a list can.
    anchor_text: ?[]const u8 = null,
    /// Anchor row list base id (e.g.
    anchor_id: ?[]const u8 = null,
    /// Item index inside the anchor list (0 for single-row header lists).
    anchor_index: usize = 0,
    /// Floating container id (one open at a time per page, so a single id is safe; override per page to avoid cross-page collisions).
    overlay_id: []const u8 = "dropdown-float",
    /// Opaque bg for the floating card so rows underneath don't show through the gaps.
    overlay_bg: Color = Color.rgb(0x22, 0x22, 0x22),
    overlay_pad: prop.Len = .{ .px = 8 },
    overlay_radius: prop.Len = .{ .px = 4 },
    z_index: i16 = 10,
    /// Optional footer hint rendered inside the dropdown (inside the float when overlay, inline otherwise) so it never takes layout room alone.
    footer: ?[]const u8 = null,
};

/// Declare a dropdown: search field (unless show_search is false) + one row per item under the list id namespace (IDI(list_id, index + 1), same +1.
fn fieldSize(fixed: ?prop.Len, min: prop.Len, max: prop.Len, grow: bool) prop.Size {
    if (fixed) |v| return .{ .fixed = v.pts() };
    if (!min.isNone() or !max.isNone()) return .{ .clamp = .{ .min = min.pts(), .max = max.pts(), .grow = grow } };
    return if (grow) .grow else .fit;
}

pub fn dropdown(
    props: DropdownProps,
    rows: []const []const u8,
    item_ctx: anytype,
    comptime renderItem: fn (@TypeOf(item_ctx), []const u8, usize) void,
) void {
    // Semantics: the closed field is the dropdown's identity; the expanded rows come from list.zig and register themselves as list items.
    semantics.registerAt(@src(), .{
        .declared = semantics.declaredAt(props.src),
        .id = cl.getElementId(props.field_id),
        .tag = props.field_id,
        .role = .dropdown,
        .flags = .{ .enabled = !props.disabled },
    });
    const anchor: ?u32 = if (props.anchor_text) |name|
        cl.getElementId(name).id
    else if (props.anchor_id) |aid|
        cl.ElementId.IDI(aid, @as(u32, @intCast(props.anchor_index + 1))).id
    else
        null;
    if (props.overlay and anchor != null) {
        const parent_id = anchor.?;
        cl.UI()(.{
            .id = .ID(props.overlay_id),
            .floating = .{
                .attach_to = .to_element_with_id,
                .parentId = parent_id,
                .attach_points = .{ .element = .left_top, .parent = .left_bottom },
                .offset = .{ .x = 0, .y = 4 },
                .z_index = props.z_index,
            },
            .layout = .{
                .direction = .top_to_bottom,
                .sizing = .{ .w = .grow, .h = .fit },
                .padding = .all(props.overlay_pad.whole()),
                .child_gap = props.gap.resolve(theme_mod.current().metrics.control_gap).whole(),
            },
            .background_color = props.overlay_bg.toClay(),
            .corner_radius = .all(props.overlay_radius.pts()),
            .border = if (!props.overlay_border_width.isNone()) .{
                .color = props.overlay_border_color.toClay(),
                .width = .outside(props.overlay_border_width.whole()),
            } else if (!props.border_width.isNone()) .{
                .color = props.border_color.toClay(),
                .width = .outside(props.border_width.whole()),
            } else .{},
        })({
            // The card floats above the page and paints its own fill, so a click on it is the card's, never the widget it covers.
            registry.occludeFillZ(.ID(props.overlay_id), props.overlay_bg, props.z_index);
            dropdownInner(props, rows, item_ctx, renderItem);
        });
        return;
    }
    dropdownInner(props, rows, item_ctx, renderItem);
}

fn dropdownInner(
    props: DropdownProps,
    rows: []const []const u8,
    item_ctx: anytype,
    comptime renderItem: fn (@TypeOf(item_ctx), []const u8, usize) void,
) void {
    if (props.field) |field| {
        // The dropdown paints the app's field with its own look; the draft and the caret stay the app's.
        field.font_size = props.font_size;
        field.fg = props.row_fg;
        field.bg = props.field_bg;
        field.radius = prop.Radius.all(props.radius.resolve(theme_mod.current().metrics.radius_sm).pts());
        field.w = fieldSize(props.field_w, props.field_min_w, props.field_max_w, true);
        // A field with no stated height is a control, not a line of text: the kit's 28, never `.fit`.
        field.h = fieldSize(props.field_h orelse .{ .px = 28 }, props.field_min_h, props.field_max_h, false);
        field.border = .{ .width = props.border_width, .color = props.border_color };
        field.disabled = props.disabled;
        field.disabled_bg = props.disabled_bg;
        field.disabled_fg = props.disabled_fg;
        input.textField(field);
    }
    list.list(.{
        .id = .{ .text = props.list_id },
        .row_h = props.row_h,
        .row_bg = props.row_bg,
        .selected_bg = props.selected_bg,
        .row_fg = props.row_fg,
        .hover_bg = props.hover_bg,
        .radius = prop.Len.of(props.radius.resolve(theme_mod.current().metrics.radius_sm).pts()),
        .gap = prop.Len.of(props.gap.resolve(theme_mod.current().metrics.control_gap).pts()),
        .min_w = props.list_min_w,
        .max_w = props.list_max_w,
        .row_min_h = props.row_min_h,
        .row_max_h = props.row_max_h,
        .border_width = props.border_width,
        .border_color = props.border_color,
        .disabled = props.disabled,
        .disabled_bg = props.disabled_bg,
        .on_select = props.on_select,
        .clicks = props.clicks,
        // Overlay floats above in-flow rows: dispatch at the float's z so covered headers can never fire through.
        .click_z = if (props.overlay) props.z_index else props.click_z,
    }, rows, item_ctx, renderItem);
    if (props.footer) |f| {
        cl.text(f, .{
            .font_size = props.font_size.whole(),
            .color = props.row_fg.toClay(),
        });
    }
}

fn layoutCommands(declare_fn: *const fn () void) ![]cl.RenderCommand {
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declare_fn();
    return cl.endLayout();
}

test "matches is case-insensitive substring, empty matches all" {
    try std.testing.expect(matches("", "Asia/Jakarta"));
    try std.testing.expect(matches("jak", "Asia/Jakarta"));
    try std.testing.expect(matches("JAK", "Asia/Jakarta"));
    try std.testing.expect(matches("asia", "Asia/Jakarta"));
    try std.testing.expect(matches("/", "Asia/Jakarta"));
    try std.testing.expect(!matches("/", "UTC"));
    try std.testing.expect(!matches("jak", "UTC"));
    try std.testing.expect(!matches("asia/jakarta/extra", "Asia/Jakarta"));
}

test "filter returns original indices of matches" {
    const items = [_][]const u8{ "Local", "UTC", "Asia/Jakarta", "Asia/Makassar" };
    const slice: []const []const u8 = &items;
    var out: [4]usize = undefined;
    try std.testing.expectEqual(@as(usize, 4), filter("", slice, &out));
    try std.testing.expectEqual(@as(usize, 2), filter("asia", slice, &out));
    try std.testing.expectEqual(@as(usize, 2), out[0]);
    try std.testing.expectEqual(@as(usize, 3), out[1]);
    try std.testing.expectEqual(@as(usize, 0), filter("zzz", slice, &out));
}

test "DropdownProps carries neutral dark defaults + null callbacks" {
    const p = DropdownProps{ .field_id = "f", .list_id = "l" };
    try std.testing.expect(p.field == null);
    try std.testing.expectEqual(@as(f32, 14), p.font_size.pts());
    try std.testing.expectEqual(@as(f32, 40), p.row_h.pts());
    try std.testing.expectEqual(Color.rgb(0x1e, 0x1e, 0x1e), p.row_bg);
    try std.testing.expectEqual(Color.rgb(0x26, 0x26, 0x26), p.field_bg);
    try std.testing.expect(p.on_select.f == null);
    try std.testing.expect(p.on_select.ctx == null);
}

const Ctx = struct {
    kinds: []const RowKind,
    fg: Color,
};

fn renderRow(ctx: Ctx, item: []const u8, index: usize) void {
    const kind: RowKind = if (index < ctx.kinds.len) ctx.kinds[index] else .info;
    cl.text(item, .{
        .font_size = 14,
        .color = ctx.fg.toClay(),
    });
    switch (kind) {
        .info, .back => {},
        .action => {
            cl.UI()(.{
                .layout = .{ .sizing = .grow },
            })({});
            cl.text(">", .{
                .font_size = 14,
                .color = ctx.fg.toClay(),
            });
        },
    }
}

const demo_rows = [_][]const u8{ "Alpha", "Beta", "< Back" };
const demo_slice: []const []const u8 = &demo_rows;
const demo_kinds = [_]RowKind{ .action, .action, .back };
const demo_kinds_slice: []const RowKind = &demo_kinds;

var dd_ctx: input.Field = .{ .id = .{ .text = "test-dd-field" } };

fn declareDropdown() void {
    dropdown(.{ .field_id = "test-dd-field", .list_id = "test-dd-list", .field = &dd_ctx }, demo_slice, Ctx{
        .kinds = demo_kinds_slice,
        .fg = Color.rgb(0xe8, 0xe8, 0xe8),
    }, renderRow);
}

fn declareNoSearch() void {
    dropdown(.{ .field_id = "test-dd-ns-field", .list_id = "test-dd-ns-list" }, demo_slice, Ctx{
        .kinds = demo_kinds_slice,
        .fg = Color.rgb(0xe8, 0xe8, 0xe8),
    }, renderRow);
}

fn rowId(base: []const u8, i: usize) cl.ElementId {
    return cl.ElementId.IDI(base, @as(u32, @intCast(i + 1)));
}

test "dropdown declares field id + IDI row identities" {
    _ = try layoutCommands(declareDropdown);
    try std.testing.expect(cl.getElementData(cl.getElementId("test-dd-field")).found);
    try std.testing.expect(cl.getElementData(rowId("test-dd-list", 0)).found);
    try std.testing.expect(cl.getElementData(rowId("test-dd-list", 2)).found);
}

test "dropdown show_search=false skips the field" {
    _ = try layoutCommands(declareNoSearch);
    try std.testing.expect(!cl.getElementData(cl.getElementId("test-dd-ns-field")).found);
    try std.testing.expect(cl.getElementData(rowId("test-dd-ns-list", 0)).found);
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

test "DropdownProps stores on_select/ctx; direct invocation delivers index" {
    var c = SelectCtx{};
    const p = DropdownProps{
        .field_id = "f",
        .list_id = "l",
        .on_select = .{ .f = testOnSelect, .ctx = &c },
    };
    p.on_select.f.?(p.on_select.ctx, 2);
    try std.testing.expectEqual(@as(usize, 1), c.calls);
    try std.testing.expectEqual(@as(?usize, 2), c.last);
}

var click_rec = SelectCtx{};

fn declareClickDropdown() void {
    dropdown(.{
        .field_id = "test-dd-click-field",
        .list_id = "test-dd-click-list",
        .on_select = .{ .f = testOnSelect, .ctx = &click_rec },
    }, demo_slice, Ctx{
        .kinds = demo_kinds_slice,
        .fg = Color.rgb(0xe8, 0xe8, 0xe8),
    }, renderRow);
}

test "dropdown forwards on_select to rows; dispatchClick fires display index" {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, headless.stubMeasure);
    click_rec = .{};
    registry.beginFrame();
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declareClickDropdown();
    _ = cl.endLayout();
    const bb = cl.getElementData(rowId("test-dd-click-list", 1)).bounding_box;
    try std.testing.expect(registry.dispatchClick(bb.x + bb.width * 0.5, bb.y + bb.height * 0.5));
    try std.testing.expectEqual(@as(usize, 1), click_rec.calls);
    try std.testing.expectEqual(@as(?usize, 1), click_rec.last);
    try std.testing.expect(!registry.dispatchClick(700, 460));
    try std.testing.expectEqual(@as(usize, 1), click_rec.calls);
}

var dd_clicks_a = SelectCtx{};
var dd_clicks_b = SelectCtx{};

fn onDdClickA(ctx: ?*anyopaque, i: usize) void {
    const c: *SelectCtx = @ptrCast(@alignCast(ctx.?));
    c.calls += 1;
    c.last = i;
}

fn onDdClickB(ctx: ?*anyopaque, i: usize) void {
    const c: *SelectCtx = @ptrCast(@alignCast(ctx.?));
    c.calls += 1;
    c.last = i;
}

fn declareDdClicksPassthrough() void {
    const clicks = [_]registry.RowClick{
        .{ .on_click = onDdClickA, .ctx = &dd_clicks_a },
        .{ .on_click = onDdClickB, .ctx = &dd_clicks_b },
    };
    dropdown(.{
        .field_id = "test-dd-clicks-field",
        .list_id = "test-dd-clicks-list",
        .clicks = &clicks,
    }, demo_slice[0..2], Ctx{
        .kinds = demo_kinds_slice,
        .fg = Color.rgb(0xe8, 0xe8, 0xe8),
    }, renderRow);
}

test "dropdown forwards clicks passthrough; each row fires own fn" {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, headless.stubMeasure);
    dd_clicks_a = .{};
    dd_clicks_b = .{};
    registry.beginFrame();
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declareDdClicksPassthrough();
    _ = cl.endLayout();
    const bb0 = cl.getElementData(rowId("test-dd-clicks-list", 0)).bounding_box;
    try std.testing.expect(registry.dispatchClick(bb0.x + bb0.width * 0.5, bb0.y + bb0.height * 0.5));
    try std.testing.expectEqual(@as(usize, 1), dd_clicks_a.calls);
    try std.testing.expectEqual(@as(?usize, 0), dd_clicks_a.last);
    try std.testing.expectEqual(@as(usize, 0), dd_clicks_b.calls);
    const bb1 = cl.getElementData(rowId("test-dd-clicks-list", 1)).bounding_box;
    try std.testing.expect(registry.dispatchClick(bb1.x + bb1.width * 0.5, bb1.y + bb1.height * 0.5));
    try std.testing.expectEqual(@as(usize, 1), dd_clicks_b.calls);
    try std.testing.expectEqual(@as(?usize, 1), dd_clicks_b.last);
}

fn declareAnchorRow() void {
    cl.UI()(.{
        .id = .IDI("test-overlay-anchor", 1),
        .layout = .{
            .direction = .left_to_right,
            .sizing = .{ .w = .grow, .h = .fixed(40) },
        },
        .background_color = .{ 30, 30, 30, 255 },
    })({});
}

fn declareAfterRow() void {
    cl.UI()(.{
        .id = .IDI("test-overlay-after", 1),
        .layout = .{
            .direction = .left_to_right,
            .sizing = .{ .w = .grow, .h = .fixed(40) },
        },
        .background_color = .{ 30, 30, 30, 255 },
    })({});
}

fn declareCollapsedFrame() void {
    cl.UI()(.{
        .id = .ID("test-overlay-frame"),
        .layout = .{
            .direction = .top_to_bottom,
            .sizing = .{ .w = .fixed(600), .h = .fit },
            .child_gap = 8,
        },
    })({
        declareAnchorRow();
        declareAfterRow();
    });
}

fn declareOverlayFrame() void {
    cl.UI()(.{
        .id = .ID("test-overlay-frame"),
        .layout = .{
            .direction = .top_to_bottom,
            .sizing = .{ .w = .fixed(600), .h = .fit },
            .child_gap = 8,
        },
    })({
        declareAnchorRow();
        dropdown(.{
            .field_id = "test-overlay-field",
            .list_id = "test-overlay-list",
            .overlay = true,
            .anchor_id = "test-overlay-anchor",
            .anchor_index = 0,
            .overlay_id = "test-overlay-float",
            .footer = "hint",
        }, demo_slice[0..2], Ctx{
            .kinds = demo_kinds_slice,
            .fg = Color.rgb(0xe8, 0xe8, 0xe8),
        }, renderRow);
        declareAfterRow();
    });
}

fn frameY(declare_fn: *const fn () void, base: []const u8) !f32 {
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
    registry.beginFrame();
    cl.beginLayout();
    declare_fn();
    _ = cl.endLayout();
    return cl.getElementData(cl.ElementId.IDI(base, 1)).bounding_box.y;
}

fn declareTextAnchor() void {
    cl.UI()(.{
        .id = .ID("test-text-anchor"),
        .layout = .{ .direction = .left_to_right, .sizing = .{ .w = .fixed(120), .h = .fixed(32) } },
        .background_color = .{ 30, 30, 30, 255 },
    })({});
}

fn declareTextAnchorOnly() void {
    cl.UI()(.{
        .id = .ID("test-text-frame"),
        .layout = .{ .direction = .top_to_bottom, .sizing = .{ .w = .fixed(400), .h = .fit }, .child_gap = 8 },
    })({
        declareTextAnchor();
        declareAfterRow();
    });
}

fn declareTextAnchorFrame() void {
    cl.UI()(.{
        .id = .ID("test-text-frame"),
        .layout = .{ .direction = .top_to_bottom, .sizing = .{ .w = .fixed(400), .h = .fit }, .child_gap = 8 },
    })({
        declareTextAnchor();
        dropdown(.{
            .field_id = "test-text-field",
            .list_id = "test-text-list",
            .overlay = true,
            .anchor_text = "test-text-anchor",
            .overlay_id = "test-text-float",
        }, demo_slice[0..2], Ctx{
            .kinds = demo_kinds_slice,
            .fg = Color.rgb(0xe8, 0xe8, 0xe8),
        }, renderRow);
        declareAfterRow();
    });
}

test "dropdown overlay anchored to a text id floats under it and shifts nothing" {
    const y_plain = try frameY(declareTextAnchorOnly, "test-overlay-after");
    const y_open = try frameY(declareTextAnchorFrame, "test-overlay-after");
    try std.testing.expectEqual(y_plain, y_open);

    const anchor = cl.getElementData(cl.getElementId("test-text-anchor")).bounding_box;
    const card = cl.getElementData(cl.getElementId("test-text-float")).bounding_box;
    try std.testing.expect(card.y >= anchor.y + anchor.height);
}

test "dropdown overlay floats without shifting following rows" {
    const y_collapsed = try frameY(declareCollapsedFrame, "test-overlay-after");
    const y_expanded = try frameY(declareOverlayFrame, "test-overlay-after");
    try std.testing.expectApproxEqAbs(y_collapsed, y_expanded, 0.5);
    // Overlay card + rows are still declared (clickable, visible).
    _ = try layoutCommands(declareOverlayFrame);
    try std.testing.expect(cl.getElementData(cl.getElementId("test-overlay-float")).found);
    try std.testing.expect(cl.getElementData(rowId("test-overlay-list", 0)).found);
    try std.testing.expect(cl.getElementData(rowId("test-overlay-list", 1)).found);
}

test "DropdownProps needs nothing: both ids default to empty" {
    const p = DropdownProps{};
    try std.testing.expectEqual(@as(usize, 0), p.field_id.len);
    try std.testing.expectEqual(@as(usize, 0), p.list_id.len);
}
