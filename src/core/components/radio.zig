// Agnostic reusable Clay radio button (toolkit-style, library only).
// Imports: std + zclay + core/render_common + sibling components ONLY.
// Never: app/theme/layout/views/content/sidebar.
const std = @import("std");
const cl = @import("zclay");
const render = @import("../render_common.zig");
const registry = @import("click_registry.zig");
const semantics = @import("../semantics.zig");

/// Click callback: plain fn pointer + opaque ctx (no closures).
/// Same shape as button.ClickFn. Stored in RadioProps (declare-only radio
/// never fires it); the owner reads the built props back and fires
/// `props.on_click(props.ctx)` on pointer dispatch.
pub const ClickFn = ?*const fn (?*anyopaque) void;

/// Toolkit-style radio button props. All styling via props with neutral
/// defaults — no theme/app imports. `id` becomes the Clay element ID
/// (stable across frames for hover/selection queries).
/// `selected` selects `selected_border` vs `border_color` for the outer
/// ring and draws the inner dot when true.
/// `size` fixes the outer circle to an exact pixel size (w == h == size,
/// radius = size / 2). The inner dot is a circle of diameter `size / 2`
/// (radius = size / 4) painted `dot_color`.
/// `hover_bg` (null = no hover tint) overrides the outer bg while hovered.
/// `disabled` paints `disabled_bg`, suppresses hover chrome and skips click
/// registration (declare never fires; owner dispatch via stored props must
/// also check `disabled`).
/// `on_click`/`ctx` are stored verbatim for owner-side dispatch; the
/// radio declaration itself is unchanged (hover chrome only).
pub const RadioProps = struct {
    id: []const u8,
    selected: bool = false,
    size: u32 = 20,
    outer_bg: u32 = 0x1e1e1e,
    selected_border: u32 = 0x4caf50,
    border_color: u32 = 0x555555,
    dot_color: u32 = 0x4caf50,
    border_width: u16 = 2,
    hover_bg: ?u32 = null,
    disabled: bool = false,
    disabled_bg: u32 = 0x2a2a2a,
    on_click: ClickFn = null,
    ctx: ?*anyopaque = null,
};

/// Declare a radio button: outer circle (fixed size x size) + optional
/// inner dot circle when `selected`.
/// Hover: uses `cl.hovered()` (Clay_Hovered — true when the pointer is
/// over the currently open element) to switch the outer bg to `hover_bg`
/// when set. Callers must feed pointer state via `cl.setPointerState()`
/// each frame (same as Shell.frame); without it the radio renders the
/// resting bg.
/// Selection/click handling stays caller-side (like the button hitTest
/// pattern): after layout, query
/// `cl.pointerOver(cl.getElementId(props.id))`.
pub fn radio(props: RadioProps) void {
    // NOTE: cl.hovered() must be evaluated INSIDE the UI() config literal
    // (after Clay__OpenElement runs, while this element is open) so it
    // queries this radio — calling it here beforehand would query the
    // parent/root instead and hover_bg would never (or spuriously) trigger.
    // Disabled radios never take hover chrome and never register clicks.
    cl.UI()(.{
        .id = .ID(props.id),
        .layout = .{
            .sizing = .{
                .w = .fixed(@floatFromInt(props.size)),
                .h = .fixed(@floatFromInt(props.size)),
            },
            .child_alignment = .center,
        },
        .background_color = render.u32ToClayColor(if (props.disabled) props.disabled_bg else if (cl.hovered()) (props.hover_bg orelse props.outer_bg) else props.outer_bg),
        .corner_radius = .all(@as(f32, @floatFromInt(props.size)) / 2.0),
        .border = if (props.border_width > 0) .{
            .color = render.u32ToClayColor(if (props.selected) props.selected_border else props.border_color),
            .width = .outside(props.border_width),
        } else .{},
    })({
        if (props.selected) {
            cl.UI()(.{
                .layout = .{
                    .sizing = .{
                        .w = .fixed(@as(f32, @floatFromInt(props.size)) / 2.0),
                        .h = .fixed(@as(f32, @floatFromInt(props.size)) / 2.0),
                    },
                },
                .background_color = render.u32ToClayColor(props.dot_color),
                .corner_radius = .all(@as(f32, @floatFromInt(props.size)) / 4.0),
            })({});
        }
    });
    // Semantics: radios report SELECTED, not checked.
    semantics.register(.{
        .id = cl.getElementId(props.id),
        .tag = props.id,
        .role = .radio,
        .flags = .{ .enabled = !props.disabled, .selected = props.selected },
    });
    if (!props.disabled) {
        if (props.on_click) |cb| {
            // Pointer cursor: clickable radio. Disabled skips
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

fn declareRadio() void {
    radio(.{ .id = "test-radio" });
}

fn declareSelectedRadio() void {
    radio(.{ .id = "test-radio-sel", .selected = true });
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

test "radio emits outer circle only, plus dot when selected, and no text" {
    var rects: usize = 0;
    var texts: usize = 0;
    try countCommands(declareRadio, &rects, &texts);
    try std.testing.expectEqual(@as(usize, 1), rects);
    try std.testing.expectEqual(@as(usize, 0), texts);
    try countCommands(declareSelectedRadio, &rects, &texts);
    try std.testing.expectEqual(@as(usize, 2), rects);
    try std.testing.expectEqual(@as(usize, 0), texts);
}

test "RadioProps carries neutral defaults" {
    const p = RadioProps{ .id = "x" };
    try std.testing.expect(!p.selected);
    try std.testing.expectEqual(@as(u32, 20), p.size);
    try std.testing.expectEqual(@as(u32, 0x1e1e1e), p.outer_bg);
    try std.testing.expectEqual(@as(u32, 0x4caf50), p.selected_border);
    try std.testing.expectEqual(@as(u32, 0x555555), p.border_color);
    try std.testing.expectEqual(@as(u32, 0x4caf50), p.dot_color);
    try std.testing.expectEqual(@as(u16, 2), p.border_width);
    try std.testing.expect(p.hover_bg == null);
    try std.testing.expect(!p.disabled);
    try std.testing.expectEqual(@as(u32, 0x2a2a2a), p.disabled_bg);
    try std.testing.expect(p.on_click == null);
    try std.testing.expect(p.ctx == null);
}

fn borderColorForSelected(selected: bool) !cl.Color {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    radio(.{ .id = "test-radio-border", .selected = selected });
    const cmds = cl.endLayout();
    // NOTE: Clay tags border commands with a derived id (not the element
    // id), so match the first border command by type, not by id.
    for (cmds) |c| {
        if (c.command_type == .border) return c.render_data.border.color;
    }
    return error.MissingBorder;
}

test "radio selected/unselected border colors differ" {
    const unselected_c = try borderColorForSelected(false);
    const selected_c = try borderColorForSelected(true);
    try std.testing.expectEqual(render.u32ToClayColor(0x555555), unselected_c);
    try std.testing.expectEqual(render.u32ToClayColor(0x4caf50), selected_c);
    try std.testing.expect(!std.meta.eql(unselected_c, selected_c));
}

const ClickCtx = struct {
    calls: usize = 0,
};

fn testOnClick(ctx: ?*anyopaque) void {
    const c: *ClickCtx = @ptrCast(@alignCast(ctx.?));
    c.calls += 1;
}

var click_rec = ClickCtx{};

fn declareClickRadio() void {
    radio(.{ .id = "test-click-radio", .on_click = testOnClick, .ctx = &click_rec });
}

test "radio self-registers on_click; dispatchClick at center fires once" {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    click_rec = .{};
    registry.beginFrame();
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declareClickRadio();
    _ = cl.endLayout();
    const bb = cl.getElementData(cl.getElementId("test-click-radio")).bounding_box;
    try std.testing.expect(registry.dispatchClick(bb.x + bb.width * 0.5, bb.y + bb.height * 0.5));
    try std.testing.expectEqual(@as(usize, 1), click_rec.calls);
    try std.testing.expect(!registry.dispatchClick(700, 460));
    try std.testing.expectEqual(@as(usize, 1), click_rec.calls);
}

fn rectColorForId(cmds: []cl.RenderCommand, id: u32) ?cl.Color {
    for (cmds) |c| {
        if (c.command_type == .rectangle and c.id == id) return c.render_data.rectangle.background_color;
    }
    return null;
}

fn declareDisabledRadio() void {
    radio(.{ .id = "test-disabled-radio", .disabled = true, .on_click = testOnClick, .ctx = &click_rec });
}

test "disabled radio uses disabled_bg and registers no click" {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    click_rec = .{};
    registry.beginFrame();
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declareDisabledRadio();
    const cmds = cl.endLayout();
    const eid = cl.getElementId("test-disabled-radio");
    const bg = rectColorForId(cmds, eid.id);
    try std.testing.expect(bg != null);
    try std.testing.expectEqual(render.u32ToClayColor(0x2a2a2a), bg.?);
    const bb = cl.getElementData(eid).bounding_box;
    try std.testing.expect(!registry.dispatchClick(bb.x + bb.width * 0.5, bb.y + bb.height * 0.5));
    try std.testing.expectEqual(@as(usize, 0), click_rec.calls);
}
