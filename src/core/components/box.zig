// Agnostic reusable Clay box (div-like container, toolkit-style, library only).
// Imports: std + zclay + core/render_common ONLY.
// Never: app/theme/layout/views/content/sidebar.
const std = @import("std");
const cl = @import("zclay");
const render = @import("../render_common.zig");

/// Box sizing per axis: fit contents, grow to fill, exact pixels, or
/// percent of the parent (0.0-1.0).
/// `fixed` is f32 (not u32) so fractional heights map 1:1 — e.g. the
/// sidebar gap (60 - 16 - measure("Settings",18).h ≈ 22.4) keeps its exact
/// Clay `.fixed(f32)` value instead of truncating to u32.
pub const Size = union(enum) {
    fit,
    grow,
    fixed: f32,
    percent: f32,
};

/// Box layout direction: row = left-to-right, column = top-to-bottom.
pub const Direction = enum {
    row,
    column,
};

/// Toolkit-style box props. All styling via props with neutral defaults —
/// no theme/app imports. `id` becomes the Clay element ID (stable across
/// frames for geometry/selection queries). `bg`, when non-null, paints a
/// rectangle (null = transparent = no rect command). `pad` is uniform
/// padding on all sides; `gap` separates children along the layout axis;
/// `radius` rounds the bg rect (a.k.a. `rounded`: 0 = square, >0 = pill
/// when >= half the height). `child_align` forwards to Clay `child_alignment`
/// (default left/top = Clay default, so existing boxes are unaffected —
/// the content header passes left/center for pixel parity).
/// `min_w`/`min_h`/`max_w`/`max_h` clamp the fit/grow axes (0 = no
/// constraint; forwarded to Clay fitMinMax/growMinMax). `percent` sizing
/// ignores min/max (Clay percent carries no minmax payload).
/// `border_width` (uniform, 0 = none) + `border_color` emit a Clay BORDER
/// command (drawn by the GLES3 renderer as an inset outline).
/// `disabled` is stored verbatim for owner-side dispatch: the box itself
/// never fires `on_click`, so owners must skip firing when disabled.
/// `on_click`/`ctx` are stored verbatim for
/// owner-side dispatch; the box declaration itself never fires them.
pub const BoxProps = struct {
    id: []const u8,
    direction: Direction = .column,
    w: Size = .fit,
    h: Size = .fit,
    min_w: f32 = 0,
    min_h: f32 = 0,
    max_w: f32 = 0,
    max_h: f32 = 0,
    bg: ?u32 = null,
    pad: u16 = 0,
    gap: u16 = 0,
    radius: u32 = 0,
    border_width: u16 = 0,
    border_color: u32 = 0x000000,
    disabled: bool = false,
    child_align: cl.ChildAlignment = .{},
    on_click: ?*const fn (?*anyopaque) void = null,
    ctx: ?*anyopaque = null,
};

fn toSizingAxis(s: Size, min: f32, max: f32) cl.SizingAxis {
    const constrained = min > 0 or max > 0;
    return switch (s) {
        .fit => if (constrained) .fitMinMax(.{ .min = min, .max = max }) else .fit,
        .grow => if (constrained) .growMinMax(.{ .min = min, .max = max }) else .grow,
        .fixed => |v| .fixed(v),
        .percent => |v| .percent(v),
    };
}

/// Declare a div-like container: Clay element (.ID(props.id)) with the
/// mapped direction/sizing/padding/gap/radius, bg only when non-null,
/// and `children(ctx)` invoked inside for caller-declared content.
/// Declare-only: never fires `on_click` (owner dispatches via stored props).
/// Cursor note: box stores on_click/ctx for owner-side dispatch but never
/// self-registers in click_registry (no registry import by design), so it
/// contributes no hover entry and hoverCursorAt reports .default over it.
/// This is intentional — boxes are layout containers, not click targets.
pub fn box(props: BoxProps, ctx: anytype, comptime children: fn (@TypeOf(ctx)) void) void {
    const dir: cl.LayoutDirection = switch (props.direction) {
        .row => .left_to_right,
        .column => .top_to_bottom,
    };
    cl.UI()(.{
        .id = .ID(props.id),
        .layout = .{
            .direction = dir,
            .sizing = .{
                .w = toSizingAxis(props.w, props.min_w, props.max_w),
                .h = toSizingAxis(props.h, props.min_h, props.max_h),
            },
            .padding = .all(props.pad),
            .child_gap = props.gap,
            .child_alignment = props.child_align,
        },
        .background_color = if (props.bg) |b| render.u32ToClayColor(b) else .{ 0, 0, 0, 0 },
        .corner_radius = .all(@floatFromInt(props.radius)),
        .border = if (props.border_width > 0) .{
            .color = render.u32ToClayColor(props.border_color),
            .width = .outside(props.border_width),
        } else .{},
    })({
        children(ctx);
    });
}

// ---- Arrange helpers: Row / Column / Spacer over Box ----
//
// Same declare-only Box underneath; these fix the layout direction (or
// the grow-spacer shape) so call sites read as intent:
//   row(.{ .id = "header", ... }, ctx, headerChildren)
//   column(.{ .id = "content", ... }, ctx, contentChildren)
//   spacer("content-spacer")
// `box()` stays the generic escape hatch (back-compat — all existing
// call sites keep working unchanged).

/// Row container: Box forced to left-to-right. `props.direction` is
/// ignored (overwritten to .row) so a stale .column can't slip through.
pub fn row(props: BoxProps, ctx: anytype, comptime children: fn (@TypeOf(ctx)) void) void {
    var p = props;
    p.direction = .row;
    box(p, ctx, children);
}

/// Column container: Box forced to top-to-bottom. `props.direction` is
/// ignored (overwritten to .column).
pub fn column(props: BoxProps, ctx: anytype, comptime children: fn (@TypeOf(ctx)) void) void {
    var p = props;
    p.direction = .column;
    box(p, ctx, children);
}

/// Grow spacer: transparent Box that expands on both axes, pushing
/// siblings apart (header/content/sidebar spacers). Emits no rectangle
/// (bg null) — layout-only.
pub fn spacer(id: []const u8) void {
    box(.{ .id = id, .w = .grow, .h = .grow }, {}, emptyChildren);
}

// Stub text estimator for headless tests (no font backend needed).
fn stubMeasure(s: []const u8, cfg: *cl.TextElementConfig, _: void) cl.Dimensions {
    return .{
        .w = @as(f32, @floatFromInt(s.len)) * @as(f32, @floatFromInt(cfg.font_size)) * 0.6,
        .h = @as(f32, @floatFromInt(cfg.font_size)),
    };
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
    // Park the pointer far outside the layout so hover state is
    // deterministic (box itself has no hover chrome; children might).
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

fn emptyChildren(_: void) void {}

fn declareEmptyBox() void {
    box(.{ .id = "test-empty-box" }, {}, emptyChildren);
}

test "empty box with no bg emits no rectangles" {
    var rects: usize = 0;
    var texts: usize = 0;
    try countCommands(declareEmptyBox, &rects, &texts);
    try std.testing.expectEqual(@as(usize, 0), rects);
    try std.testing.expectEqual(@as(usize, 0), texts);
}

fn declareBgBox() void {
    box(.{ .id = "test-bg-box", .bg = 0x1e1e1e }, {}, emptyChildren);
}

test "box with bg emits exactly one rectangle" {
    var rects: usize = 0;
    var texts: usize = 0;
    try countCommands(declareBgBox, &rects, &texts);
    try std.testing.expectEqual(@as(usize, 1), rects);
    try std.testing.expectEqual(@as(usize, 0), texts);
}

// ---- Children callback ----

var child_calls: usize = 0;

const ChildCtx = struct {
    n: usize,
};

fn childLabels(ctx: ChildCtx) void {
    child_calls += 1;
    var i: usize = 0;
    while (i < ctx.n) : (i += 1) {
        cl.text("x", .{
            .font_size = 14,
            .color = render.u32ToClayColor(0xe8e8e8),
        });
    }
}

fn declareChildBox() void {
    box(.{ .id = "test-child-box" }, ChildCtx{ .n = 3 }, childLabels);
}

test "children callback invoked; N child labels emit N texts" {
    child_calls = 0;
    var rects: usize = 0;
    var texts: usize = 0;
    try countCommands(declareChildBox, &rects, &texts);
    try std.testing.expectEqual(@as(usize, 1), child_calls);
    try std.testing.expectEqual(@as(usize, 3), texts);
}

// ---- Nesting ----

fn innerBox(_: void) void {
    box(.{ .id = "test-nested-inner", .bg = 0x2d2d2d }, {}, emptyChildren);
}

fn outerChildren(_: void) void {
    innerBox({});
}

fn declareNestedBox() void {
    box(.{ .id = "test-nested-outer", .bg = 0x1e1e1e }, {}, outerChildren);
}

test "nested boxes declare both rects" {
    var rects: usize = 0;
    var texts: usize = 0;
    try countCommands(declareNestedBox, &rects, &texts);
    try std.testing.expectEqual(@as(usize, 2), rects);
    try std.testing.expectEqual(@as(usize, 0), texts);
}

// ---- Direction proven by geometry ----

fn rowChildren(_: void) void {
    box(.{ .id = "test-row-a", .w = .{ .fixed = 20 }, .h = .{ .fixed = 10 }, .bg = 0x1e1e1e }, {}, emptyChildren);
    box(.{ .id = "test-row-b", .w = .{ .fixed = 20 }, .h = .{ .fixed = 10 }, .bg = 0x1e1e1e }, {}, emptyChildren);
}

fn declareRowBox() void {
    box(.{ .id = "test-row", .direction = .row }, {}, rowChildren);
}

test "row direction lays children out horizontally (x differs, y equal)" {
    const cmds = try layoutCommands(declareRowBox);
    _ = cmds;
    const a = cl.getElementData(cl.getElementId("test-row-a")).bounding_box;
    const b = cl.getElementData(cl.getElementId("test-row-b")).bounding_box;
    try std.testing.expect(b.x > a.x);
    try std.testing.expectEqual(a.y, b.y);
}

fn colChildren(_: void) void {
    box(.{ .id = "test-col-a", .w = .{ .fixed = 20 }, .h = .{ .fixed = 10 }, .bg = 0x1e1e1e }, {}, emptyChildren);
    box(.{ .id = "test-col-b", .w = .{ .fixed = 20 }, .h = .{ .fixed = 10 }, .bg = 0x1e1e1e }, {}, emptyChildren);
}

fn declareColBox() void {
    box(.{ .id = "test-col", .direction = .column }, {}, colChildren);
}

test "column direction lays children out vertically (y differs, x equal)" {
    const cmds = try layoutCommands(declareColBox);
    _ = cmds;
    const a = cl.getElementData(cl.getElementId("test-col-a")).bounding_box;
    const b = cl.getElementData(cl.getElementId("test-col-b")).bounding_box;
    try std.testing.expect(b.y > a.y);
    try std.testing.expectEqual(a.x, b.x);
}

// ---- Props defaults ----

test "BoxProps carries neutral defaults" {
    const p = BoxProps{ .id = "x" };
    try std.testing.expect(p.direction == .column);
    try std.testing.expect(p.w == .fit);
    try std.testing.expect(p.h == .fit);
    try std.testing.expectEqual(@as(f32, 0), p.min_w);
    try std.testing.expectEqual(@as(f32, 0), p.min_h);
    try std.testing.expectEqual(@as(f32, 0), p.max_w);
    try std.testing.expectEqual(@as(f32, 0), p.max_h);
    try std.testing.expect(p.bg == null);
    try std.testing.expectEqual(@as(u16, 0), p.pad);
    try std.testing.expectEqual(@as(u16, 0), p.gap);
    try std.testing.expectEqual(@as(u32, 0), p.radius);
    try std.testing.expectEqual(@as(u16, 0), p.border_width);
    try std.testing.expectEqual(@as(u32, 0x000000), p.border_color);
    try std.testing.expect(!p.disabled);
    try std.testing.expect(p.child_align.x == .left);
    try std.testing.expect(p.child_align.y == .top);
    try std.testing.expect(p.on_click == null);
    try std.testing.expect(p.ctx == null);
}

// ---- on_click/ctx field presence ----

const ClickCtx = struct {
    calls: usize = 0,
};

fn testOnClick(ctx: ?*anyopaque) void {
    const c: *ClickCtx = @ptrCast(@alignCast(ctx.?));
    c.calls += 1;
}

test "BoxProps stores on_click/ctx; direct invocation fires" {
    var c = ClickCtx{};
    const p = BoxProps{ .id = "x", .on_click = testOnClick, .ctx = &c };
    try std.testing.expect(p.on_click != null);
    try std.testing.expect(p.ctx != null);
    p.on_click.?(p.ctx);
    try std.testing.expectEqual(@as(usize, 1), c.calls);
}

// ---- Non-obvious mappings for sidebar/content adoption ----

fn declareFracBox() void {
    box(.{ .id = "test-frac", .w = .{ .fixed = 50 }, .h = .{ .fixed = 22.4 } }, {}, emptyChildren);
}

test "fixed size keeps fractional pixels (sidebar gap parity)" {
    const cmds = try layoutCommands(declareFracBox);
    _ = cmds;
    const bb = cl.getElementData(cl.getElementId("test-frac")).bounding_box;
    try std.testing.expectApproxEqAbs(@as(f32, 50), bb.width, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 22.4), bb.height, 0.001);
}

fn alignCenterChild(_: void) void {
    box(.{ .id = "test-align-inner", .w = .{ .fixed = 20 }, .h = .{ .fixed = 10 }, .bg = 0x1e1e1e }, {}, emptyChildren);
}

fn declareAlignCenter() void {
    box(.{ .id = "test-align-center", .direction = .row, .w = .{ .fixed = 100 }, .h = .{ .fixed = 40 }, .child_align = .{ .x = .left, .y = .center } }, {}, alignCenterChild);
}

fn alignTopChild(_: void) void {
    box(.{ .id = "test-align-top-inner", .w = .{ .fixed = 20 }, .h = .{ .fixed = 10 }, .bg = 0x1e1e1e }, {}, emptyChildren);
}

fn declareAlignTop() void {
    box(.{ .id = "test-align-top", .direction = .row, .w = .{ .fixed = 100 }, .h = .{ .fixed = 40 } }, {}, alignTopChild);
}

test "align y=center vertically centers child (header parity)" {
    const cmds_c = try layoutCommands(declareAlignCenter);
    _ = cmds_c;
    const parent_c = cl.getElementData(cl.getElementId("test-align-center")).bounding_box;
    const inner_c = cl.getElementData(cl.getElementId("test-align-inner")).bounding_box;
    // (40 - 10) / 2 = 15 offset from parent top.
    try std.testing.expectApproxEqAbs(@as(f32, 15), inner_c.y - parent_c.y, 0.001);

    const cmds_t = try layoutCommands(declareAlignTop);
    _ = cmds_t;
    const parent_t = cl.getElementData(cl.getElementId("test-align-top")).bounding_box;
    const inner_t = cl.getElementData(cl.getElementId("test-align-top-inner")).bounding_box;
    try std.testing.expectApproxEqAbs(@as(f32, 0), inner_t.y - parent_t.y, 0.001);
}

// ---- Arrange helpers: row / column / spacer ----

fn helperRowChildren(_: void) void {
    box(.{ .id = "test-helper-row-a", .w = .{ .fixed = 20 }, .h = .{ .fixed = 10 }, .bg = 0x1e1e1e }, {}, emptyChildren);
    box(.{ .id = "test-helper-row-b", .w = .{ .fixed = 20 }, .h = .{ .fixed = 10 }, .bg = 0x1e1e1e }, {}, emptyChildren);
}

fn declareHelperRow() void {
    // direction passed as .column on purpose: row() must force .row.
    row(.{ .id = "test-helper-row", .direction = .column }, {}, helperRowChildren);
}

test "row() forces horizontal layout even when props says column" {
    const cmds = try layoutCommands(declareHelperRow);
    _ = cmds;
    const a = cl.getElementData(cl.getElementId("test-helper-row-a")).bounding_box;
    const b = cl.getElementData(cl.getElementId("test-helper-row-b")).bounding_box;
    try std.testing.expect(b.x > a.x);
    try std.testing.expectEqual(a.y, b.y);
}

fn helperColChildren(_: void) void {
    box(.{ .id = "test-helper-col-a", .w = .{ .fixed = 20 }, .h = .{ .fixed = 10 }, .bg = 0x1e1e1e }, {}, emptyChildren);
    box(.{ .id = "test-helper-col-b", .w = .{ .fixed = 20 }, .h = .{ .fixed = 10 }, .bg = 0x1e1e1e }, {}, emptyChildren);
}

fn declareHelperCol() void {
    // direction passed as .row on purpose: column() must force .column.
    column(.{ .id = "test-helper-col", .direction = .row }, {}, helperColChildren);
}

test "column() forces vertical layout even when props says row" {
    const cmds = try layoutCommands(declareHelperCol);
    _ = cmds;
    const a = cl.getElementData(cl.getElementId("test-helper-col-a")).bounding_box;
    const b = cl.getElementData(cl.getElementId("test-helper-col-b")).bounding_box;
    try std.testing.expect(b.y > a.y);
    try std.testing.expectEqual(a.x, b.x);
}

fn declareHelperSpacer() void {
    spacer("test-helper-spacer");
}

test "spacer() emits no rectangle (layout-only grow box)" {
    var rects: usize = 0;
    var texts: usize = 0;
    try countCommands(declareHelperSpacer, &rects, &texts);
    try std.testing.expectEqual(@as(usize, 0), rects);
    try std.testing.expectEqual(@as(usize, 0), texts);
}

fn spacerPushChildren(_: void) void {
    box(.{ .id = "test-push-a", .w = .{ .fixed = 20 }, .h = .{ .fixed = 10 }, .bg = 0x1e1e1e }, {}, emptyChildren);
    spacer("test-push-spacer");
    box(.{ .id = "test-push-b", .w = .{ .fixed = 20 }, .h = .{ .fixed = 10 }, .bg = 0x1e1e1e }, {}, emptyChildren);
}

fn declareSpacerPush() void {
    row(.{ .id = "test-push-row", .w = .{ .fixed = 200 }, .h = .{ .fixed = 10 } }, {}, spacerPushChildren);
}

test "spacer() in a fixed row pushes siblings apart (b at far edge)" {
    const cmds = try layoutCommands(declareSpacerPush);
    _ = cmds;
    const parent = cl.getElementData(cl.getElementId("test-push-row")).bounding_box;
    const b = cl.getElementData(cl.getElementId("test-push-b")).bounding_box;
    // b's right edge meets the parent's right edge: 20px box in 200px row.
    try std.testing.expectApproxEqAbs(parent.x + parent.width, b.x + b.width, 0.5);
}

fn declareBorderBox() void {
    box(.{ .id = "test-border-box", .bg = 0x1e1e1e, .border_width = 2, .border_color = 0xff0000 }, {}, emptyChildren);
}

test "box border emits a border command alongside the rect" {
    const cmds = try layoutCommands(declareBorderBox);
    var rects: usize = 0;
    var borders: usize = 0;
    for (cmds) |c| switch (c.command_type) {
        .rectangle => rects += 1,
        .border => borders += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), rects);
    try std.testing.expectEqual(@as(usize, 1), borders);
}

fn declareMinBox() void {
    box(.{ .id = "test-min-box", .w = .grow, .min_w = 120, .h = .{ .fixed = 10 }, .bg = 0x1e1e1e }, {}, emptyChildren);
}

test "box min_w clamps a grow box" {
    const cmds = try layoutCommands(declareMinBox);
    _ = cmds;
    const bb = cl.getElementData(cl.getElementId("test-min-box")).bounding_box;
    try std.testing.expect(bb.width >= 119.5);
}

fn declarePercentBox() void {
    box(.{ .id = "test-pct-outer", .w = .{ .fixed = 200 }, .h = .{ .fixed = 20 } }, {}, percentChild);
}

fn percentChild(_: void) void {
    box(.{ .id = "test-pct-inner", .w = .{ .percent = 0.5 }, .h = .{ .fixed = 10 }, .bg = 0x1e1e1e }, {}, emptyChildren);
}

test "box percent sizes relative to parent" {
    const cmds = try layoutCommands(declarePercentBox);
    _ = cmds;
    const bb = cl.getElementData(cl.getElementId("test-pct-inner")).bounding_box;
    try std.testing.expectApproxEqAbs(@as(f32, 100), bb.width, 0.5);
}
