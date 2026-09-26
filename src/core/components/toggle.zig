// Agnostic reusable Clay toggle switch (toolkit-style, library only).
// Imports: std + zclay + core/render_common + sibling components ONLY.
// Never: app/theme/layout/views/content/sidebar.
const std = @import("std");
const cl = @import("zclay");
const render = @import("../render_common.zig");
const registry = @import("click_registry.zig");

/// Click callback: plain fn pointer + opaque ctx (no closures).
/// Same shape as button.ClickFn. Stored in ToggleProps (declare-only toggle
/// never fires it); the owner reads the built props back and fires
/// `props.on_click(props.ctx)` on pointer dispatch.
pub const ClickFn = ?*const fn (?*anyopaque) void;

/// Toolkit-style toggle switch props. All styling via props with neutral
/// defaults — no theme/app imports. `id` becomes the Clay element ID
/// (stable across frames for hover/selection queries).
/// `on` selects `on_bg` vs `off_bg` and parks the knob right vs left
/// (via the outer pill's child_alignment x).
/// `w`/`h` fix the pill to an exact pixel size. `radius` rounds the pill
/// (default 12 = half of h 24, i.e. a capsule). The knob is a circle of
/// diameter `h - 4` (2px inset padding) painted `knob_color`.
/// `hover_bg` (null = no hover tint) overrides the pill bg while hovered.
/// `disabled` paints `disabled_bg`, suppresses hover chrome and skips click
/// registration (declare never fires; owner dispatch via stored props must
/// also check `disabled`).
/// `on_click`/`ctx` are stored verbatim for owner-side dispatch; the
/// toggle declaration itself is unchanged (hover chrome only).
pub const ToggleProps = struct {
    id: []const u8,
    on: bool = false,
    w: u32 = 44,
    h: u32 = 24,
    radius: u32 = 12,
    on_bg: u32 = 0x4caf50,
    off_bg: u32 = 0x3a3a3a,
    knob_color: u32 = 0xffffff,
    hover_bg: ?u32 = null,
    disabled: bool = false,
    disabled_bg: u32 = 0x2a2a2a,
    on_click: ClickFn = null,
    ctx: ?*anyopaque = null,
};

/// Declare a toggle switch: outer pill (fixed w/h, on/off bg) + inner
/// knob circle parked left (off) or right (on).
/// Hover: uses `cl.hovered()` (Clay_Hovered — true when the pointer is
/// over the currently open element) to switch the pill bg to `hover_bg`
/// when set. Callers must feed pointer state via `cl.setPointerState()`
/// each frame (same as Shell.frame); without it the toggle renders the
/// resting bg.
/// Selection/click handling stays caller-side (like the button hitTest
/// pattern): after layout, query
/// `cl.pointerOver(cl.getElementId(props.id))`.
pub fn toggle(props: ToggleProps) void {
    // NOTE: cl.hovered() must be evaluated INSIDE the UI() config literal
    // (after Clay__OpenElement runs, while this element is open) so it
    // queries this toggle — calling it here beforehand would query the
    // parent/root instead and hover_bg would never (or spuriously) trigger.
    // Disabled toggles never take hover chrome and never register clicks.
    const knob_d: u32 = props.h -| 4;
    cl.UI()(.{
        .id = .ID(props.id),
        .layout = .{
            .direction = .left_to_right,
            .sizing = .{
                .w = .fixed(@floatFromInt(props.w)),
                .h = .fixed(@floatFromInt(props.h)),
            },
            .padding = .all(2),
            .child_alignment = .{ .x = if (props.on) .right else .left, .y = .center },
        },
        .background_color = render.u32ToClayColor(if (props.disabled) props.disabled_bg else if (cl.hovered()) (props.hover_bg orelse (if (props.on) props.on_bg else props.off_bg)) else (if (props.on) props.on_bg else props.off_bg)),
        .corner_radius = .all(@floatFromInt(props.radius)),
    })({
        cl.UI()(.{
            .layout = .{
                .sizing = .{
                    .w = .fixed(@floatFromInt(knob_d)),
                    .h = .fixed(@floatFromInt(knob_d)),
                },
            },
            .background_color = render.u32ToClayColor(props.knob_color),
            .corner_radius = .all(@floatFromInt(knob_d / 2)),
        })({});
    });
    if (!props.disabled) {
        if (props.on_click) |cb| {
            // Pointer cursor: clickable toggle. Disabled skips
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

fn declareToggle() void {
    toggle(.{ .id = "test-toggle" });
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

test "toggle emits pill + knob rectangles and no text" {
    var rects: usize = 0;
    var texts: usize = 0;
    try countCommands(declareToggle, &rects, &texts);
    try std.testing.expectEqual(@as(usize, 2), rects);
    try std.testing.expectEqual(@as(usize, 0), texts);
}

test "ToggleProps carries neutral defaults" {
    const p = ToggleProps{ .id = "x" };
    try std.testing.expect(!p.on);
    try std.testing.expectEqual(@as(u32, 44), p.w);
    try std.testing.expectEqual(@as(u32, 24), p.h);
    try std.testing.expectEqual(@as(u32, 12), p.radius);
    try std.testing.expectEqual(@as(u32, 0x4caf50), p.on_bg);
    try std.testing.expectEqual(@as(u32, 0x3a3a3a), p.off_bg);
    try std.testing.expectEqual(@as(u32, 0xffffff), p.knob_color);
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

fn pillColor(on: bool) !cl.Color {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    toggle(.{ .id = "test-toggle-bg", .on = on });
    const cmds = cl.endLayout();
    const bg = rectColorForId(cmds, cl.getElementId("test-toggle-bg").id);
    try std.testing.expect(bg != null);
    return bg.?;
}

test "toggle on/off bg colors differ" {
    const off_c = try pillColor(false);
    const on_c = try pillColor(true);
    try std.testing.expectEqual(render.u32ToClayColor(0x3a3a3a), off_c);
    try std.testing.expectEqual(render.u32ToClayColor(0x4caf50), on_c);
    try std.testing.expect(!std.meta.eql(off_c, on_c));
}

const ClickCtx = struct {
    calls: usize = 0,
};

fn testOnClick(ctx: ?*anyopaque) void {
    const c: *ClickCtx = @ptrCast(@alignCast(ctx.?));
    c.calls += 1;
}

var click_rec = ClickCtx{};

fn declareClickToggle() void {
    toggle(.{ .id = "test-click-toggle", .on_click = testOnClick, .ctx = &click_rec });
}

test "toggle self-registers on_click; dispatchClick at center fires once" {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
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
    toggle(.{ .id = "test-disabled-toggle", .disabled = true, .on_click = testOnClick, .ctx = &click_rec });
}

test "disabled toggle uses disabled_bg and registers no click" {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    click_rec = .{};
    registry.beginFrame();
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declareDisabledToggle();
    const cmds = cl.endLayout();
    const eid = cl.getElementId("test-disabled-toggle");
    const bg = rectColorForId(cmds, eid.id);
    try std.testing.expect(bg != null);
    try std.testing.expectEqual(render.u32ToClayColor(0x2a2a2a), bg.?);
    const bb = cl.getElementData(eid).bounding_box;
    try std.testing.expect(!registry.dispatchClick(bb.x + bb.width * 0.5, bb.y + bb.height * 0.5));
    try std.testing.expectEqual(@as(usize, 0), click_rec.calls);
}
