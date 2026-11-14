// Agnostic reusable Clay button (toolkit-style, library only).
const std = @import("std");
const cl = @import("zclay");
const Color = @import("../color.zig").Color;
const prop = @import("../props.zig");
const registry = @import("click_registry.zig");
const semantics = @import("../semantics.zig");

/// Click callback: plain fn pointer + opaque ctx (no closures).
pub const ClickFn = ?*const fn (?*anyopaque) void;

/// Toolkit-style button props: a label that carries its own type, a size per axis, padding, a border, a radius, and the tones a pointer can put it in.
pub const ButtonProps = struct {
    id: prop.Id,
    label: prop.Label = .{},
    bg: Color = Color.rgb(0x1e, 0x1e, 0x1e),
    fg: Color = Color.rgb(0xe8, 0xe8, 0xe8),
    hover_bg: Color = Color.rgb(0x2d, 0x2d, 0x2d),
    disabled: bool = false,
    disabled_bg: Color = Color.rgb(0x1a, 0x1a, 0x1a),
    disabled_fg: Color = Color.rgb(0x77, 0x77, 0x77),
    w: prop.Size = .fit,
    h: prop.Size = .fit,
    pad: prop.Pad = prop.Pad.axes(6, 12),
    border: prop.Border = .{},
    radius: prop.Radius = prop.Radius.all(6),
    on_click: prop.Click = .{},
};

/// Declare a button: a rounded rect sized to its label, with the label centred.
pub fn button(p: ButtonProps) void {
    // NOTE: cl.hovered() must be evaluated INSIDE the UI() config literal (after Clay__OpenElement runs, while this element is open) so it queries this.
    const fg: Color = if (p.disabled) p.disabled_fg else p.fg;
    cl.UI()(.{
        .id = p.id.clay(),
        .layout = .{
            .sizing = .{ .w = p.w.clay(), .h = p.h.clay() },
            .padding = p.pad.clay(),
            .child_alignment = .center,
        },
        .background_color = (if (p.disabled) p.disabled_bg else if (cl.hovered()) p.hover_bg else p.bg).toClay(),
        .corner_radius = p.radius.clay(),
        .border = p.border.clay(),
    })({
        cl.text(p.label.text, .{
            .font_size = p.label.size,
            .color = fg.toClay(),
        });
    });
    // Semantics: registered for EVERY button, not only the ones with a click callback.
    semantics.register(.{
        .id = p.id.clay(),
        .tag = p.id.str(),
        .role = .button,
        .label = p.label.text,
        .flags = .{ .enabled = !p.disabled },
    });
    if (!p.disabled) {
        if (p.on_click.f) |cb| {
            // Pointer cursor: clickable button.
            registry.registerClickCursor(p.id.clay(), cb, p.on_click.ctx, .pointer);
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

fn frameCommands(declare_fn: *const fn () void) ![]cl.RenderCommand {
    const mem_size = cl.minMemorySize();
    // NOTE: intentionally leaked (page_allocator, never freed).
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    // Park the pointer far outside the layout so hovered() is false and the test observes the resting bg path.
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declare_fn();
    return cl.endLayout();
}

fn rectColorForId(cmds: []cl.RenderCommand, id: u32) ?cl.Color {
    for (cmds) |c| {
        if (c.command_type == .rectangle and c.id == id) return c.render_data.rectangle.background_color;
    }
    return null;
}

const ClickCtx = struct {
    calls: usize = 0,
};

fn testOnClick(ctx: ?*anyopaque) void {
    const c: *ClickCtx = @ptrCast(@alignCast(ctx.?));
    c.calls += 1;
}

var click_rec = ClickCtx{};

fn declareButton() void {
    button(.{ .id = .{ .text = "test-button" }, .label = .{ .text = "OK" } });
}

fn declareClickButton() void {
    button(.{ .id = .{ .text = "test-click-button" }, .label = .{ .text = "OK" }, .on_click = .{ .f = testOnClick, .ctx = &click_rec } });
}

fn declareNoClickButton() void {
    button(.{ .id = .{ .text = "test-noclick-button" }, .label = .{ .text = "OK" } });
}

fn declareDisabledButton() void {
    button(.{ .id = .{ .text = "test-disabled-button" }, .label = .{ .text = "OK" }, .disabled = true, .on_click = .{ .f = testOnClick, .ctx = &click_rec } });
}

fn declareFixedButton() void {
    button(.{
        .id = .{ .text = "test-fixed-button" },
        .label = .{ .text = "X", .size = 12 },
        .w = .{ .fixed = 16 },
        .h = .{ .fixed = 16 },
        .pad = .{},
    });
}

fn declarePaddedButton() void {
    button(.{ .id = .{ .text = "test-padded-button" }, .label = .{ .text = "OK" } });
}

fn declareUnpaddedButton() void {
    button(.{ .id = .{ .text = "test-unpadded-button" }, .label = .{ .text = "OK" }, .pad = .{} });
}

fn declareMinButton() void {
    button(.{ .id = .{ .text = "test-min-button" }, .label = .{ .text = "OK" }, .w = .between(200, 0) });
}

fn fitWidth(declare_fn: *const fn () void, id: []const u8) !f32 {
    _ = try frameCommands(declare_fn);
    return cl.getElementData(cl.getElementId(id)).bounding_box.width;
}

test "button emits rectangle + text render commands" {
    const cmds = try frameCommands(declareButton);
    var rects: usize = 0;
    var texts: usize = 0;
    for (cmds) |c| switch (c.command_type) {
        .rectangle => rects += 1,
        .text => texts += 1,
        else => {},
    };
    try std.testing.expect(rects >= 1);
    try std.testing.expectEqual(@as(usize, 1), texts);
}

test "ButtonProps carries neutral dark defaults, and needs only an id" {
    const p = ButtonProps{ .id = .{ .text = "x" } };
    try std.testing.expectEqual(@as(u16, 14), p.label.size);
    try std.testing.expectEqual(Color.rgb(0x1e, 0x1e, 0x1e), p.bg);
    try std.testing.expectEqual(Color.rgb(0xe8, 0xe8, 0xe8), p.fg);
    try std.testing.expectEqual(Color.rgb(0x2d, 0x2d, 0x2d), p.hover_bg);
    try std.testing.expectEqual(@as(u16, 6), p.radius.top_left);
    try std.testing.expect(std.meta.activeTag(p.w) == .fit);
    try std.testing.expect(std.meta.activeTag(p.h) == .fit);
    try std.testing.expectEqual(@as(u16, 0), p.border.width);
    try std.testing.expect(!p.disabled);
    try std.testing.expectEqual(Color.rgb(0x1a, 0x1a, 0x1a), p.disabled_bg);
    try std.testing.expectEqual(Color.rgb(0x77, 0x77, 0x77), p.disabled_fg);
    try std.testing.expectEqual(@as(u16, 6), p.pad.top);
    try std.testing.expectEqual(@as(u16, 12), p.pad.left);
    try std.testing.expect(p.on_click.f == null);
    try std.testing.expect(p.on_click.ctx == null);
}

test "ButtonProps stores on_click/ctx; direct invocation fires" {
    var c = ClickCtx{};
    const p = ButtonProps{ .id = .{ .text = "x" }, .label = .{ .text = "y" }, .on_click = .{ .f = testOnClick, .ctx = &c } };
    try std.testing.expect(p.on_click.f != null);
    try std.testing.expect(p.on_click.ctx != null);
    p.on_click.f.?(p.on_click.ctx);
    try std.testing.expectEqual(@as(usize, 1), c.calls);
}

fn declareHoverButton() void {
    button(.{ .id = .{ .text = "test-button-hover" }, .label = .{ .text = "OK" } });
}

test "button hover switches bg to hover_bg when pointer is over" {
    const p = ButtonProps{ .id = .{ .text = "test-button-hover" }, .label = .{ .text = "OK" } };
    const eid = p.id.clay();
    _ = try frameCommands(declareHoverButton);

    // Frame 2: pointer over the button centre (frame-1 box) — hover bg.
    const bb = cl.getElementData(eid).bounding_box;
    cl.setPointerState(.{ .x = bb.x + bb.width * 0.5, .y = bb.y + bb.height * 0.5 }, false);
    cl.beginLayout();
    button(p);
    const cmds = cl.endLayout();
    try std.testing.expect(cl.pointerOver(eid));
    const bg = rectColorForId(cmds, eid.id);
    try std.testing.expect(bg != null);
    try std.testing.expectEqual(p.hover_bg.toClay(), bg.?);

    // Frame 3: pointer inside the window but OFF the button — resting bg.
    cl.setPointerState(.{ .x = 700, .y = 460 }, false);
    cl.beginLayout();
    button(p);
    const cmds3 = cl.endLayout();
    try std.testing.expect(!cl.pointerOver(eid));
    const bg3 = rectColorForId(cmds3, eid.id);
    try std.testing.expect(bg3 != null);
    try std.testing.expectEqual(p.bg.toClay(), bg3.?);
}

test "button fixed size honours w/h props with zero padding" {
    _ = try frameCommands(declareFixedButton);
    const bb = cl.getElementData(cl.getElementId("test-fixed-button")).bounding_box;
    try std.testing.expectEqual(@as(f32, 16), bb.width);
    try std.testing.expectEqual(@as(f32, 16), bb.height);
}

test "button padding props grow the fit box" {
    // "OK" at 14px: stub text w = 2*14*0.6 = 16.8; the default pad is 12 a side.
    const wide = try fitWidth(declarePaddedButton, "test-padded-button");
    const narrow = try fitWidth(declareUnpaddedButton, "test-unpadded-button");
    try std.testing.expectApproxEqAbs(@as(f32, 24), wide - narrow, 0.01);
}

test "button without on_click registers nothing; dispatchClick returns false" {
    registry.beginFrame();
    _ = try frameCommands(declareNoClickButton);
    const bb = cl.getElementData(cl.getElementId("test-noclick-button")).bounding_box;
    try std.testing.expect(!registry.dispatchClick(bb.x + bb.width * 0.5, bb.y + bb.height * 0.5));
}

test "button self-registers on_click; dispatchClick at center fires once" {
    click_rec = .{};
    registry.beginFrame();
    _ = try frameCommands(declareClickButton);
    const bb = cl.getElementData(cl.getElementId("test-click-button")).bounding_box;
    try std.testing.expect(registry.dispatchClick(bb.x + bb.width * 0.5, bb.y + bb.height * 0.5));
    try std.testing.expectEqual(@as(usize, 1), click_rec.calls);
    try std.testing.expect(!registry.dispatchClick(700, 460));
    try std.testing.expectEqual(@as(usize, 1), click_rec.calls);
}

test "disabled button uses disabled_bg and registers no click" {
    click_rec = .{};
    registry.beginFrame();
    const cmds = try frameCommands(declareDisabledButton);
    const eid = cl.getElementId("test-disabled-button");
    const bg = rectColorForId(cmds, eid.id);
    try std.testing.expect(bg != null);
    try std.testing.expectEqual(Color.rgb(0x1a, 0x1a, 0x1a).toClay(), bg.?);
    const bb = cl.getElementData(eid).bounding_box;
    try std.testing.expect(!registry.dispatchClick(bb.x + bb.width * 0.5, bb.y + bb.height * 0.5));
    try std.testing.expectEqual(@as(usize, 0), click_rec.calls);
}

test "button min_w clamps the fit width" {
    const w = try fitWidth(declareMinButton, "test-min-button");
    try std.testing.expect(w >= 199.5);
}
