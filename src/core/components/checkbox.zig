// Agnostic reusable Clay checkbox (toolkit-style, library only).
// Imports: std + zclay + core/render_common + sibling components ONLY.
// Never: app/theme/layout/views/content/sidebar.
const std = @import("std");
const cl = @import("zclay");
const render = @import("../render_common.zig");
const registry = @import("click_registry.zig");

/// Click callback: plain fn pointer + opaque ctx (no closures).
/// Same shape as button.ClickFn. Stored in CheckboxProps (declare-only
/// checkbox never fires it); the owner reads the built props back and fires
/// `props.on_click(props.ctx)` on pointer dispatch.
pub const ClickFn = ?*const fn (?*anyopaque) void;

/// Toolkit-style checkbox props. All styling via props with neutral
/// defaults — no theme/app imports. `id` becomes the Clay element ID
/// (stable across frames for hover/selection queries).
/// `checked` selects `checked_bg` vs `box_bg` and draws the inner check
/// mark (a 60% inner box painted `check_color`) when true.
/// `size` fixes the box to an exact pixel square. `radius` rounds the box.
/// `border_width` (uniform, 0 = none) + `border_color` emit a Clay BORDER
/// command.
/// `hover_bg` (null = no hover tint) overrides the box bg while hovered.
/// `disabled` paints `disabled_bg`, suppresses hover chrome and skips click
/// registration (declare never fires; owner dispatch via stored props must
/// also check `disabled`).
/// `on_click`/`ctx` are stored verbatim for owner-side dispatch; the
/// checkbox declaration itself is unchanged (hover chrome only).
pub const CheckboxProps = struct {
    id: []const u8,
    checked: bool = false,
    size: u32 = 20,
    radius: u32 = 4,
    box_bg: u32 = 0x1e1e1e,
    checked_bg: u32 = 0x4caf50,
    check_color: u32 = 0xffffff,
    border_width: u16 = 1,
    border_color: u32 = 0x555555,
    hover_bg: ?u32 = null,
    disabled: bool = false,
    disabled_bg: u32 = 0x2a2a2a,
    on_click: ClickFn = null,
    ctx: ?*anyopaque = null,
};

/// Declare a checkbox: outer fixed square (unchecked/checked bg) + inner
/// check box (60% size, `check_color`) when `checked`.
/// Hover: uses `cl.hovered()` (Clay_Hovered — true when the pointer is
/// over the currently open element) to switch the box bg to `hover_bg`
/// when set. Callers must feed pointer state via `cl.setPointerState()`
/// each frame (same as Shell.frame); without it the checkbox renders the
/// resting bg.
/// Selection/click handling stays caller-side (like the button hitTest
/// pattern): after layout, query
/// `cl.pointerOver(cl.getElementId(props.id))`.
pub fn checkbox(props: CheckboxProps) void {
    // NOTE: cl.hovered() must be evaluated INSIDE the UI() config literal
    // (after Clay__OpenElement runs, while this element is open) so it
    // queries this checkbox — calling it here beforehand would query the
    // parent/root instead and hover_bg would never (or spuriously) trigger.
    // Disabled checkboxes never take hover chrome and never register clicks.
    const box_f: f32 = @floatFromInt(props.size);
    const inner_f: f32 = box_f * 0.6;
    cl.UI()(.{
        .id = .ID(props.id),
        .layout = .{
            .sizing = .{
                .w = .fixed(box_f),
                .h = .fixed(box_f),
            },
            .child_alignment = .center,
        },
        .background_color = render.u32ToClayColor(if (props.disabled) props.disabled_bg else if (cl.hovered()) (props.hover_bg orelse (if (props.checked) props.checked_bg else props.box_bg)) else (if (props.checked) props.checked_bg else props.box_bg)),
        .corner_radius = .all(@floatFromInt(props.radius)),
        .border = if (props.border_width > 0) .{
            .color = render.u32ToClayColor(props.border_color),
            .width = .outside(props.border_width),
        } else .{},
    })({
        if (props.checked) {
            cl.UI()(.{
                .layout = .{
                    .sizing = .{
                        .w = .fixed(inner_f),
                        .h = .fixed(inner_f),
                    },
                },
                .background_color = render.u32ToClayColor(props.check_color),
                .corner_radius = .all(2),
            })({});
        }
    });
    if (!props.disabled) {
        if (props.on_click) |cb| {
            // Pointer cursor: clickable checkbox. Disabled skips
            // registration so hover stays .default.
            registry.registerClickCursor(cl.getElementId(props.id), cb, props.ctx, .pointer);
        }
    }
}

// Stub text estimator for headless tests (no font backend needed).
fn stubMeasure(s: []const u8, cfg: *cl.TextElementConfig, _: void) cl.Dimensions {
    return .{
        .w = @as(f32, @floatFromInt(s.len)) * @as(f32, @floatFromInt(cfg.font_size)) * 0.6,
        .h = @as(f32, @floatFromInt(cfg.font_size)),
    };
}

fn declareCheckbox() void {
    checkbox(.{ .id = "test-checkbox" });
}

fn declareCheckedCheckbox() void {
    checkbox(.{ .id = "test-checkbox-checked", .checked = true });
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

test "checkbox emits box rectangle and no text; checked adds inner check" {
    var rects: usize = 0;
    var texts: usize = 0;
    try countCommands(declareCheckbox, &rects, &texts);
    try std.testing.expectEqual(@as(usize, 1), rects);
    try std.testing.expectEqual(@as(usize, 0), texts);
    try countCommands(declareCheckedCheckbox, &rects, &texts);
    try std.testing.expectEqual(@as(usize, 2), rects);
    try std.testing.expectEqual(@as(usize, 0), texts);
}

test "CheckboxProps carries neutral defaults" {
    const p = CheckboxProps{ .id = "x" };
    try std.testing.expect(!p.checked);
    try std.testing.expectEqual(@as(u32, 20), p.size);
    try std.testing.expectEqual(@as(u32, 4), p.radius);
    try std.testing.expectEqual(@as(u32, 0x1e1e1e), p.box_bg);
    try std.testing.expectEqual(@as(u32, 0x4caf50), p.checked_bg);
    try std.testing.expectEqual(@as(u32, 0xffffff), p.check_color);
    try std.testing.expectEqual(@as(u16, 1), p.border_width);
    try std.testing.expectEqual(@as(u32, 0x555555), p.border_color);
    try std.testing.expect(p.hover_bg == null);
    try std.testing.expect(!p.disabled);
    try std.testing.expectEqual(@as(u32, 0x2a2a2a), p.disabled_bg);
    try std.testing.expect(p.on_click == null);
    try std.testing.expect(p.ctx == null);
}

fn rectColorForId(cmds: []cl.RenderCommand, id: u32) ?cl.Color {
    for (cmds) |c| {
        if (c.command_type == .rectangle and c.id == id) return c.render_data.rectangle.background_color;
    }
    return null;
}

fn boxColor(checked: bool) !cl.Color {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    checkbox(.{ .id = "test-checkbox-bg", .checked = checked });
    const cmds = cl.endLayout();
    const bg = rectColorForId(cmds, cl.getElementId("test-checkbox-bg").id);
    try std.testing.expect(bg != null);
    return bg.?;
}

test "checkbox checked/unchecked bg colors differ" {
    const unchecked_c = try boxColor(false);
    const checked_c = try boxColor(true);
    try std.testing.expectEqual(render.u32ToClayColor(0x1e1e1e), unchecked_c);
    try std.testing.expectEqual(render.u32ToClayColor(0x4caf50), checked_c);
    try std.testing.expect(!std.meta.eql(unchecked_c, checked_c));
}

const ClickCtx = struct {
    calls: usize = 0,
};

fn testOnClick(ctx: ?*anyopaque) void {
    const c: *ClickCtx = @ptrCast(@alignCast(ctx.?));
    c.calls += 1;
}

var click_rec = ClickCtx{};

fn declareClickCheckbox() void {
    checkbox(.{ .id = "test-click-checkbox", .on_click = testOnClick, .ctx = &click_rec });
}

test "checkbox self-registers on_click; dispatchClick at center fires once" {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    click_rec = .{};
    registry.beginFrame();
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declareClickCheckbox();
    _ = cl.endLayout();
    const bb = cl.getElementData(cl.getElementId("test-click-checkbox")).bounding_box;
    try std.testing.expect(registry.dispatchClick(bb.x + bb.width * 0.5, bb.y + bb.height * 0.5));
    try std.testing.expectEqual(@as(usize, 1), click_rec.calls);
    try std.testing.expect(!registry.dispatchClick(700, 460));
    try std.testing.expectEqual(@as(usize, 1), click_rec.calls);
}

fn declareDisabledCheckbox() void {
    checkbox(.{ .id = "test-disabled-checkbox", .disabled = true, .on_click = testOnClick, .ctx = &click_rec });
}

test "disabled checkbox uses disabled_bg and registers no click" {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    click_rec = .{};
    registry.beginFrame();
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declareDisabledCheckbox();
    const cmds = cl.endLayout();
    const eid = cl.getElementId("test-disabled-checkbox");
    const bg = rectColorForId(cmds, eid.id);
    try std.testing.expect(bg != null);
    try std.testing.expectEqual(render.u32ToClayColor(0x2a2a2a), bg.?);
    const bb = cl.getElementData(eid).bounding_box;
    try std.testing.expect(!registry.dispatchClick(bb.x + bb.width * 0.5, bb.y + bb.height * 0.5));
    try std.testing.expectEqual(@as(usize, 0), click_rec.calls);
}
