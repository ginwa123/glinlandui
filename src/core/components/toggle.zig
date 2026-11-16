// Agnostic reusable Clay toggle switch (toolkit-style, library only).
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

/// Toolkit-style toggle switch props.
pub const ToggleProps = struct {
    id: prop.Id,
    // Where the app declared this widget: `@src()` at the call site, which the devtool then shows as the declaration.
    src: ?std.builtin.SourceLocation = null,
    on: bool = false,
    w: prop.Len = .{ .px = 32 },
    h: prop.Len = .{ .px = 18 },
    radius: prop.Len = .{ .px = 9 },
    on_bg: Color = Color.rgb(0x4c, 0xaf, 0x50),
    off_bg: Color = Color.rgb(0x3a, 0x3a, 0x3a),
    knob_color: Color = Color.rgb(0xff, 0xff, 0xff),
    hover_bg: ?Color = null,
    disabled: bool = false,
    disabled_bg: Color = Color.rgb(0x2a, 0x2a, 0x2a),
    on_click: prop.Click = .{},
};

/// Declare a toggle switch: outer pill (fixed w/h, on/off bg) + inner knob circle parked left (off) or right (on).
pub fn toggle(props: ToggleProps) void {
    // NOTE: cl.hovered() must be evaluated INSIDE the UI() config literal (after Clay__OpenElement runs, while this element is open) so it queries this.
    const knob: f32 = @max(props.h.pts() - 4, 0);
    cl.UI()(.{
        .id = props.id.clay(),
        .layout = .{
            .direction = .left_to_right,
            .sizing = .{
                .w = .fixed(props.w.pts()),
                .h = .fixed(props.h.pts()),
            },
            .padding = .all(2),
            .child_alignment = .{ .x = if (props.on) .right else .left, .y = .center },
        },
        .background_color = (if (props.disabled) props.disabled_bg else if (cl.hovered()) (props.hover_bg orelse (if (props.on) props.on_bg else props.off_bg)) else (if (props.on) props.on_bg else props.off_bg)).toClay(),
        .corner_radius = .all(props.radius.pts()),
    })({
        cl.UI()(.{
            .layout = .{
                .sizing = .{
                    .w = .fixed(knob),
                    .h = .fixed(knob),
                },
            },
            .background_color = props.knob_color.toClay(),
            .corner_radius = .all(knob / 2),
        })({});
    });
    // Semantics: `.on` is the toggle's checked state.
    semantics.registerAt(@src(), .{
        .declared = semantics.declaredAt(props.src),
        .id = props.id.clay(),
        .tag = props.id.str(),
        .role = .toggle,
        .flags = .{ .enabled = !props.disabled, .checked = props.on },
    });
    if (!props.disabled) {
        if (props.on_click.f) |cb| {
            // Pointer cursor: clickable toggle.
            registry.registerClickCursor(props.id.clay(), cb, props.on_click.ctx, .pointer);
        }
    }
}

fn declareToggle() void {
    toggle(.{ .id = .{ .text = "test-toggle" } });
}

test "toggle emits pill + knob rectangles and no text" {
    var rects: usize = 0;
    var texts: usize = 0;
    try headless.countCommands(declareToggle, &rects, &texts);
    try std.testing.expectEqual(@as(usize, 2), rects);
    try std.testing.expectEqual(@as(usize, 0), texts);
}

test "ToggleProps carries neutral defaults" {
    const p = ToggleProps{ .id = .{ .text = "x" } };
    try std.testing.expect(!p.on);
    try std.testing.expectEqual(@as(f32, 32), p.w.pts());
    try std.testing.expectEqual(@as(f32, 18), p.h.pts());
    try std.testing.expectEqual(@as(f32, 9), p.radius.pts());
    try std.testing.expectEqual(Color.rgb(0x4c, 0xaf, 0x50), p.on_bg);
    try std.testing.expectEqual(Color.rgb(0x3a, 0x3a, 0x3a), p.off_bg);
    try std.testing.expectEqual(Color.rgb(0xff, 0xff, 0xff), p.knob_color);
    try std.testing.expect(p.hover_bg == null);
    try std.testing.expect(!p.disabled);
    try std.testing.expectEqual(Color.rgb(0x2a, 0x2a, 0x2a), p.disabled_bg);
    try std.testing.expect(p.on_click.f == null);
    try std.testing.expect(p.on_click.ctx.isNone());
}

fn rectColorForId(cmds: []cl.RenderCommand, id: u32) ?cl.Color {
    for (cmds) |c| {
        if (c.command_type == .rectangle and c.id == id) return c.render_data.rectangle.background_color;
    }
    return null;
}

fn pillColor(on: bool) !cl.Color {
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    toggle(.{ .id = .{ .text = "test-toggle-bg" }, .on = on });
    const cmds = cl.endLayout();
    const bg = rectColorForId(cmds, cl.getElementId("test-toggle-bg").id);
    try std.testing.expect(bg != null);
    return bg.?;
}

test "toggle on/off bg colors differ" {
    const off_c = try pillColor(false);
    const on_c = try pillColor(true);
    try std.testing.expectEqual(Color.rgb(0x3a, 0x3a, 0x3a).toClay(), off_c);
    try std.testing.expectEqual(Color.rgb(0x4c, 0xaf, 0x50).toClay(), on_c);
    try std.testing.expect(!std.meta.eql(off_c, on_c));
}

const ClickCtx = struct {
    calls: usize = 0,
};

fn testOnClick(ctx: Ctx) void {
    const c = ctx.get(ClickCtx);
    c.calls += 1;
}

var click_rec = ClickCtx{};

fn declareClickToggle() void {
    toggle(.{ .id = .{ .text = "test-click-toggle" }, .on_click = .{ .f = testOnClick, .ctx = Ctx.from(&click_rec) } });
}

test "toggle self-registers on_click; dispatchClick at center fires once" {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, headless.stubMeasure);
    click_rec = .{};
    registry.beginFrame();
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declareClickToggle();
    _ = cl.endLayout();
    const bb = cl.getElementData(cl.getElementId("test-click-toggle")).bounding_box;
    try std.testing.expect(registry.dispatchClick(bb.x + bb.width * 0.5, bb.y + bb.height * 0.5));
    try std.testing.expectEqual(@as(usize, 1), click_rec.calls);
    try std.testing.expect(!registry.dispatchClick(700, 460));
    try std.testing.expectEqual(@as(usize, 1), click_rec.calls);
}

fn declareDisabledToggle() void {
    toggle(.{ .id = .{ .text = "test-disabled-toggle" }, .disabled = true, .on_click = .{ .f = testOnClick, .ctx = Ctx.from(&click_rec) } });
}

test "disabled toggle uses disabled_bg and registers no click" {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, headless.stubMeasure);
    click_rec = .{};
    registry.beginFrame();
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declareDisabledToggle();
    const cmds = cl.endLayout();
    const eid = cl.getElementId("test-disabled-toggle");
    const bg = rectColorForId(cmds, eid.id);
    try std.testing.expect(bg != null);
    try std.testing.expectEqual(Color.rgb(0x2a, 0x2a, 0x2a).toClay(), bg.?);
    const bb = cl.getElementData(eid).bounding_box;
    try std.testing.expect(!registry.dispatchClick(bb.x + bb.width * 0.5, bb.y + bb.height * 0.5));
    try std.testing.expectEqual(@as(usize, 0), click_rec.calls);
}
