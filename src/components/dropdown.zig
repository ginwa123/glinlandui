// Agnostic reusable Clay dropdown (toolkit-style, library only).
// Composes the input field (search) + generic list (matches) from the
// sibling components: one search box over a filtered string list with
// owner-side selection dispatch (same stored-props pattern as list).
// Imports: std + zclay + wayland/render_gles3 + sibling components ONLY.
// Never: app/theme/layout/views/content/sidebar.
const std = @import("std");
const cl = @import("zclay");
const render = @import("../wayland/render_common.zig");
const registry = @import("click_registry.zig");
const list = @import("list.zig");
const input = @import("input.zig");

/// Selection callback: plain fn pointer + opaque ctx (no closures).
/// Stored in DropdownProps (declare-only dropdown never fires it); the
/// owner reads the built props back and fires
/// `props.on_select(props.ctx, i)` with the DISPLAY index on pointer
/// dispatch (see the app views). Re-exported shape mirrors ListSelectFn.
pub const DropdownSelectFn = ?*const fn (?*anyopaque, usize) void;

/// Caret + keyboard-selection passthrough for the search field
/// (owner-held input.EditState; null = legacy caret-at-end render).
/// Pages use this alias so they never import input.zig directly.
pub const QueryEdit = ?input.EditState;

/// Dropdown row kinds: info rows are display-only (search results
/// headers, previews), action rows fire on_select, back rows are
/// rendered without the drill-in chevron (the owner maps them back).
pub const RowKind = enum {
    info,
    action,
    back,
};

/// Case-insensitive substring match for the search filter. Empty
/// query matches everything.
pub fn matches(query: []const u8, item: []const u8) bool {
    if (query.len == 0) return true;
    if (query.len > item.len) return false;
    var i: usize = 0;
    while (i + query.len <= item.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(query, item[i..][0..query.len])) return true;
    }
    return false;
}

/// Filter `items` by query into `out` (caller-owned scratch, must fit
/// items.len). Returns the matched count; out[0..n] holds ORIGINAL
/// indices so selection maps back to the source slice.
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

/// Toolkit-style dropdown props. All styling via props with neutral
/// dark defaults — no theme/app imports. `field_id` / `list_id` become
/// the Clay element IDs (stable across frames for hit-testing).
/// `query` is caller-owned (Shell draft buffers), read synchronously
/// during declare. `on_select`/`ctx` are stored verbatim for
/// owner-side dispatch; the dropdown itself never fires callbacks.
pub const DropdownProps = struct {
    field_id: []const u8,
    list_id: []const u8,
    show_search: bool = true,
    font_size: u16 = 14,
    row_h: u32 = 40,
    row_bg: u32 = 0x1e1e1e,
    selected_bg: u32 = 0x3a3a3a,
    row_fg: u32 = 0xe8e8e8,
    hover_bg: u32 = 0x2d2d2d,
    field_bg: u32 = 0x262626,
    radius: u32 = 4,
    gap: u16 = 8,
    /// Uniform border for the search field + rows (0 = none) + color.
    border_width: u16 = 0,
    border_color: u32 = 0x000000,
    /// Disabled dropdown: field dims + list takes no hover/clicks.
    disabled: bool = false,
    disabled_bg: u32 = 0x1a1a1a,
    disabled_fg: u32 = 0x777777,
    /// Field sizing: fixed overrides (null = grow/fit) + min/max clamps.
    field_w: ?f32 = null,
    field_h: ?f32 = null,
    field_min_w: f32 = 0,
    field_max_w: f32 = 0,
    field_min_h: f32 = 0,
    field_max_h: f32 = 0,
    /// List sizing clamps (grow container width; row height clamp).
    list_min_w: f32 = 0,
    list_max_w: f32 = 0,
    row_min_h: f32 = 0,
    row_max_h: f32 = 0,
    /// Overlay card border (defaults to border_* when 0-width + default color).
    overlay_border_width: u16 = 0,
    overlay_border_color: u32 = 0x000000,
    /// Caret + keyboard selection for the search field (owner-held, one
    /// per draft). Null keeps the legacy caret-at-end render.
    query_edit: ?input.EditState = null,
    on_select: DropdownSelectFn = null,
    ctx: ?*anyopaque = null,
    /// Per-row clicks passthrough (Stage B): forwarded verbatim to the
    /// inner list. When non-null, the inner list registers clicks[i]
    /// per row; when null, the legacy on_select path is unchanged.
    clicks: ?[]const registry.RowClick = null,
    /// Dispatch priority for inline declares (forwarded to the inner
    /// list). Overlay declares ignore this and register at z_index
    /// instead, so the float always wins over covered in-flow rows
    /// without callers passing anything.
    click_z: i16 = 0,
    /// Overlay mode: when true + anchor_id set, the field + list (+
    /// footer) render in a floating container anchored under
    /// IDI(anchor_id, anchor_index + 1) so opening never pushes siblings
    /// down. Inline (false) keeps the legacy in-flow declare.
    overlay: bool = false,
    /// Anchor row list base id (e.g. "defaults-row-0"); the float attaches
    /// to IDI(anchor_id, anchor_index + 1) (same +1 scheme as list rows).
    anchor_id: ?[]const u8 = null,
    /// Item index inside the anchor list (0 for single-row header lists).
    anchor_index: usize = 0,
    /// Floating container id (one open at a time per page, so a single id
    /// is safe; override per page to avoid cross-page collisions).
    overlay_id: []const u8 = "dropdown-float",
    /// Opaque bg for the floating card so rows underneath don't show
    /// through the gaps. Agnostic default (callers pass theme bg).
    overlay_bg: u32 = 0x222222,
    overlay_pad: u16 = 8,
    overlay_radius: u32 = 4,
    z_index: i16 = 10,
    /// Optional footer hint rendered inside the dropdown (inside the float
    /// when overlay, inline otherwise) so it never takes layout room alone.
    footer: ?[]const u8 = null,
};

/// Declare a dropdown: search field (unless show_search is false) +
/// one row per item under the list id namespace
/// (IDI(list_id, index + 1), same +1 scheme as list — row 0 never
/// collides with the container). Row content comes from the caller's
/// comptime `renderItem(item_ctx, rows[i], i)`; the kind-driven chrome
/// (chevron vs plain) is the render callback's job via item_ctx, same
/// split as list (chrome bg in the component, fg in the callback).
///
/// Overlay (props.overlay + anchor_id): field + list + footer render in a
/// floating card anchored under IDI(anchor_id, anchor_index + 1) — no
/// sibling shift. Inline otherwise (legacy).
///
/// `rows`/`query` must outlive declare only (synchronous) — Shell-owned
/// buffers or statics; props never retain items.
///
/// Cursor note: dropdown builds no registry entries of its own — the
/// search field registers a hover-only .text entry via input.field /
/// fieldEdit (.ID(field_id)) and each row registers .pointer via
/// list.registerCell (IDI(list_id, i+1)). The overlay card
/// (.ID(overlay_id)) is a layout container like box (no entry, .default).
/// Disabled forwards to both children so hover stays .default.
pub fn dropdown(
    props: DropdownProps,
    query: []const u8,
    rows: []const []const u8,
    item_ctx: anytype,
    comptime renderItem: fn (@TypeOf(item_ctx), []const u8, usize) void,
) void {
    if (props.overlay and props.anchor_id != null) {
        const aid = props.anchor_id.?;
        const parent_id = cl.ElementId.IDI(aid, @as(u32, @intCast(props.anchor_index + 1))).id;
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
                .padding = .all(props.overlay_pad),
                .child_gap = props.gap,
            },
            .background_color = render.u32ToClayColor(props.overlay_bg),
            .corner_radius = .all(@floatFromInt(props.overlay_radius)),
            .border = if (props.overlay_border_width > 0) .{
                .color = render.u32ToClayColor(props.overlay_border_color),
                .width = .outside(props.overlay_border_width),
            } else if (props.border_width > 0) .{
                .color = render.u32ToClayColor(props.border_color),
                .width = .outside(props.border_width),
            } else .{},
        })({
            dropdownInner(props, query, rows, item_ctx, renderItem);
        });
        return;
    }
    dropdownInner(props, query, rows, item_ctx, renderItem);
}

fn dropdownInner(
    props: DropdownProps,
    query: []const u8,
    rows: []const []const u8,
    item_ctx: anytype,
    comptime renderItem: fn (@TypeOf(item_ctx), []const u8, usize) void,
) void {
    if (props.show_search) {
        const field_props = input.FieldProps{
            .id = props.field_id,
            .font_size = props.font_size,
            .fg = props.row_fg,
            .bg = props.field_bg,
            .radius = props.radius,
            .w = props.field_w,
            .h = props.field_h,
            .min_w = props.field_min_w,
            .max_w = props.field_max_w,
            .min_h = props.field_min_h,
            .max_h = props.field_max_h,
            .border_width = props.border_width,
            .border_color = props.border_color,
            .disabled = props.disabled,
            .disabled_bg = props.disabled_bg,
            .disabled_fg = props.disabled_fg,
        };
        if (props.query_edit) |st| {
            input.fieldEdit(field_props, query, st);
        } else {
            input.field(field_props, query);
        }
    }
    list.list(.{
        .id = props.list_id,
        .row_h = props.row_h,
        .row_bg = props.row_bg,
        .selected_bg = props.selected_bg,
        .row_fg = props.row_fg,
        .hover_bg = props.hover_bg,
        .radius = props.radius,
        .gap = props.gap,
        .min_w = props.list_min_w,
        .max_w = props.list_max_w,
        .row_min_h = props.row_min_h,
        .row_max_h = props.row_max_h,
        .border_width = props.border_width,
        .border_color = props.border_color,
        .disabled = props.disabled,
        .disabled_bg = props.disabled_bg,
        .on_select = props.on_select,
        .ctx = props.ctx,
        .clicks = props.clicks,
        // Overlay floats above in-flow rows: dispatch at the float's
        // z so covered headers can never fire through.
        .click_z = if (props.overlay) props.z_index else props.click_z,
    }, rows, item_ctx, renderItem);
    if (props.footer) |f| {
        cl.text(f, .{
            .font_size = props.font_size,
            .color = render.u32ToClayColor(props.row_fg),
        });
    }
}

// Stub text estimator for headless tests (no font backend needed).
fn stubMeasure(s: []const u8, cfg: *cl.TextElementConfig, _: void) cl.Dimensions {
    return .{
        .w = @as(f32, @floatFromInt(s.len)) * @as(f32, @floatFromInt(cfg.font_size)) * 0.6,
        .h = @as(f32, @floatFromInt(cfg.font_size)),
    };
}

fn layoutCommands(declare_fn: *const fn () void) ![]cl.RenderCommand {
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
    try std.testing.expect(p.show_search);
    try std.testing.expectEqual(@as(u16, 14), p.font_size);
    try std.testing.expectEqual(@as(u32, 40), p.row_h);
    try std.testing.expectEqual(@as(u32, 0x1e1e1e), p.row_bg);
    try std.testing.expectEqual(@as(u32, 0x262626), p.field_bg);
    try std.testing.expect(p.on_select == null);
    try std.testing.expect(p.ctx == null);
}

const Ctx = struct {
    kinds: []const RowKind,
    fg: u32,
};

fn renderRow(ctx: Ctx, item: []const u8, index: usize) void {
    const kind: RowKind = if (index < ctx.kinds.len) ctx.kinds[index] else .info;
    cl.text(item, .{
        .font_size = 14,
        .color = render.u32ToClayColor(ctx.fg),
    });
    switch (kind) {
        .info, .back => {},
        .action => {
            cl.UI()(.{
                .layout = .{ .sizing = .grow },
            })({});
            cl.text(">", .{
                .font_size = 14,
                .color = render.u32ToClayColor(ctx.fg),
            });
        },
    }
}

const demo_rows = [_][]const u8{ "Alpha", "Beta", "< Back" };
const demo_slice: []const []const u8 = &demo_rows;
const demo_kinds = [_]RowKind{ .action, .action, .back };
const demo_kinds_slice: []const RowKind = &demo_kinds;

fn declareDropdown() void {
    dropdown(.{ .field_id = "test-dd-field", .list_id = "test-dd-list" }, "a", demo_slice, Ctx{
        .kinds = demo_kinds_slice,
        .fg = 0xe8e8e8,
    }, renderRow);
}

fn declareNoSearch() void {
    dropdown(.{ .field_id = "test-dd-ns-field", .list_id = "test-dd-ns-list", .show_search = false }, "", demo_slice, Ctx{
        .kinds = demo_kinds_slice,
        .fg = 0xe8e8e8,
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
        .on_select = testOnSelect,
        .ctx = &c,
    };
    p.on_select.?(p.ctx, 2);
    try std.testing.expectEqual(@as(usize, 1), c.calls);
    try std.testing.expectEqual(@as(?usize, 2), c.last);
}

var click_rec = SelectCtx{};

fn declareClickDropdown() void {
    dropdown(.{
        .field_id = "test-dd-click-field",
        .list_id = "test-dd-click-list",
        .show_search = false,
        .on_select = testOnSelect,
        .ctx = &click_rec,
    }, "", demo_slice, Ctx{
        .kinds = demo_kinds_slice,
        .fg = 0xe8e8e8,
    }, renderRow);
}

test "dropdown forwards on_select to rows; dispatchClick fires display index" {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
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
        .show_search = false,
        .clicks = &clicks,
    }, "", demo_slice[0..2], Ctx{
        .kinds = demo_kinds_slice,
        .fg = 0xe8e8e8,
    }, renderRow);
}

test "dropdown forwards clicks passthrough; each row fires own fn" {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
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
            .show_search = false,
            .overlay = true,
            .anchor_id = "test-overlay-anchor",
            .anchor_index = 0,
            .overlay_id = "test-overlay-float",
            .footer = "hint",
        }, "", demo_slice[0..2], Ctx{
            .kinds = demo_kinds_slice,
            .fg = 0xe8e8e8,
        }, renderRow);
        declareAfterRow();
    });
}

fn frameY(declare_fn: *const fn () void, base: []const u8) !f32 {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    registry.beginFrame();
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declare_fn();
    _ = cl.endLayout();
    return cl.getElementData(cl.ElementId.IDI(base, 1)).bounding_box.y;
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
