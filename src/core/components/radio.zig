// Agnostic reusable Clay radio button (toolkit-style, library only).
const std = @import("std");
const cl = @import("zclay");
const headless = @import("../testing/headless.zig");
const prop = @import("../props.zig");
const Color = @import("../color.zig").Color;
const registry = @import("click_registry.zig");
const semantics = @import("../semantics.zig");
const erased = @import("../erased.zig");
const Ctx = erased.Ctx;

/// Click callback: plain fn pointer + opaque ctx (no closures).
pub const ClickFn = ?*const fn (Ctx) void;

/// Toolkit-style radio button props.
pub const RadioProps = struct {
    id: prop.Id,
    // Where the app declared this widget: `@src()` at the call site, which the devtool then shows as the declaration.
    src: ?std.builtin.SourceLocation = null,
    selected: bool = false,
    size: prop.Len = .{ .px = 16 },
    outer_bg: Color = Color.rgb(0x1e, 0x1e, 0x1e),
    selected_border: Color = Color.rgb(0x4c, 0xaf, 0x50),
    border_color: Color = Color.rgb(0x55, 0x55, 0x55),
    dot_color: Color = Color.rgb(0x4c, 0xaf, 0x50),
    border_width: prop.Len = .{ .px = 2 },
    hover_bg: ?Color = null,
    disabled: bool = false,
    disabled_bg: Color = Color.rgb(0x2a, 0x2a, 0x2a),
    on_click: prop.Click = .{},
};

/// Declare a radio button: outer circle (fixed size x size) + optional inner dot circle when `selected`.
pub fn radio(props: RadioProps) void {
    // NOTE: cl.hovered() must be evaluated INSIDE the UI() config literal (after Clay__OpenElement runs, while this element is open) so it queries this.
    const size: f32 = props.size.pts();
    cl.UI()(.{
        .id = props.id.clay(),
        .layout = .{
            .sizing = .{
                .w = .fixed(size),
                .h = .fixed(size),
            },
            .child_alignment = .center,
        },
        .background_color = (if (props.disabled) props.disabled_bg else if (cl.hovered()) (props.hover_bg orelse props.outer_bg) else props.outer_bg).toClay(),
        .corner_radius = .all(size / 2.0),
        .border = if (!props.border_width.isNone()) .{
            .color = (if (props.selected) props.selected_border else props.border_color).toClay(),
            .width = .outside(props.border_width.whole()),
        } else .{},
    })({
        if (props.selected) {
            cl.UI()(.{
                .layout = .{
                    .sizing = .{
                        .w = .fixed(size / 2.0),
                        .h = .fixed(size / 2.0),
                    },
                },
                .background_color = props.dot_color.toClay(),
                .corner_radius = .all(size / 4.0),
            })({});
        }
    });
    // Semantics: radios report SELECTED, not checked.
    semantics.registerAt(@src(), .{
        .declared = semantics.declaredAt(props.src),
        .id = props.id.clay(),
        .tag = props.id.str(),
        .role = .radio,
        .flags = .{ .enabled = !props.disabled, .selected = props.selected },
    });
    if (!props.disabled) {
        if (props.on_click.f) |cb| {
            // Pointer cursor: clickable radio.
            registry.registerClickCursor(props.id.clay(), cb, props.on_click.ctx, .pointer);
        }
    }
}

fn declareRadio() void {
    radio(.{ .id = .{ .text = "test-radio" } });
}

fn declareSelectedRadio() void {
    radio(.{ .id = .{ .text = "test-radio-sel" }, .selected = true });
}

test "radio emits outer circle only, plus dot when selected, and no text" {
    var rects: usize = 0;
    var texts: usize = 0;
    try headless.countCommands(declareRadio, &rects, &texts);
    try std.testing.expectEqual(@as(usize, 1), rects);
    try std.testing.expectEqual(@as(usize, 0), texts);
    try headless.countCommands(declareSelectedRadio, &rects, &texts);
    try std.testing.expectEqual(@as(usize, 2), rects);
    try std.testing.expectEqual(@as(usize, 0), texts);
}

test "RadioProps carries neutral defaults" {
    const p = RadioProps{ .id = .{ .text = "x" } };
    try std.testing.expect(!p.selected);
    try std.testing.expectEqual(@as(f32, 16), p.size.pts());
    try std.testing.expectEqual(Color.rgb(0x1e, 0x1e, 0x1e), p.outer_bg);
    try std.testing.expectEqual(Color.rgb(0x4c, 0xaf, 0x50), p.selected_border);
    try std.testing.expectEqual(Color.rgb(0x55, 0x55, 0x55), p.border_color);
    try std.testing.expectEqual(Color.rgb(0x4c, 0xaf, 0x50), p.dot_color);
    try std.testing.expectEqual(@as(u16, 2), p.border_width.whole());
    try std.testing.expect(p.hover_bg == null);
    try std.testing.expect(!p.disabled);
    try std.testing.expectEqual(Color.rgb(0x2a, 0x2a, 0x2a), p.disabled_bg);
    try std.testing.expect(p.on_click.f == null);
    try std.testing.expect(p.on_click.ctx.isNone());
}

fn borderColorForSelected(selected: bool) !cl.Color {
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    radio(.{ .id = .{ .text = "test-radio-border" }, .selected = selected });
    const cmds = cl.endLayout();
    // NOTE: Clay tags border commands with a derived id (not the element id), so match the first border command by type, not by id.
    for (cmds) |c| {
        if (c.command_type == .border) return c.render_data.border.color;
    }
    return error.MissingBorder;
}

test "radio selected/unselected border colors differ" {
    const unselected_c = try borderColorForSelected(false);
    const selected_c = try borderColorForSelected(true);
    try std.testing.expectEqual(Color.rgb(0x55, 0x55, 0x55).toClay(), unselected_c);
    try std.testing.expectEqual(Color.rgb(0x4c, 0xaf, 0x50).toClay(), selected_c);
    try std.testing.expect(!std.meta.eql(unselected_c, selected_c));
}

const ClickCtx = struct {
    calls: usize = 0,
};

fn testOnClick(ctx: Ctx) void {
    const c = ctx.get(ClickCtx);
    c.calls += 1;
}

var click_rec = ClickCtx{};

fn declareClickRadio() void {
    radio(.{ .id = .{ .text = "test-click-radio" }, .on_click = .{ .f = testOnClick, .ctx = Ctx.from(&click_rec) } });
}

test "radio self-registers on_click; dispatchClick at center fires once" {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, headless.stubMeasure);
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
    radio(.{ .id = .{ .text = "test-disabled-radio" }, .disabled = true, .on_click = .{ .f = testOnClick, .ctx = Ctx.from(&click_rec) } });
}

test "disabled radio uses disabled_bg and registers no click" {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, headless.stubMeasure);
    click_rec = .{};
    registry.beginFrame();
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declareDisabledRadio();
    const cmds = cl.endLayout();
    const eid = cl.getElementId("test-disabled-radio");
    const bg = rectColorForId(cmds, eid.id);
    try std.testing.expect(bg != null);
    try std.testing.expectEqual(Color.rgb(0x2a, 0x2a, 0x2a).toClay(), bg.?);
    const bb = cl.getElementData(eid).bounding_box;
    try std.testing.expect(!registry.dispatchClick(bb.x + bb.width * 0.5, bb.y + bb.height * 0.5));
    try std.testing.expectEqual(@as(usize, 0), click_rec.calls);
}
