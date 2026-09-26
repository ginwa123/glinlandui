// Agnostic reusable Clay slider (toolkit-style, library only).
// Imports: std + zclay + core/render_common + sibling components ONLY.
// Never: app/theme/layout/views/content/sidebar.
const std = @import("std");
const cl = @import("zclay");
const render = @import("../render_common.zig");
const registry = @import("click_registry.zig");
const semantics = @import("../semantics.zig");

/// Click callback: plain fn pointer + opaque ctx (no closures).
/// Same shape as toggle.ClickFn / button.ClickFn. Stored in SliderProps
/// (declare-only slider never fires it); the owner reads the built props
/// back and fires `props.on_change(props.ctx)` on pointer dispatch.
pub const ClickFn = ?*const fn (?*anyopaque) void;

/// Reserved Clay IDI offsets under .ID(props.id) for inner parts.
/// The outer itself is .ID(props.id) == IDI(props.id, 0), so 1/2/3 never
/// collide with it (same +1 scheme as scroll thumbs / list rows).
pub const track_index: u32 = 1;
pub const fill_index: u32 = 2;
pub const thumb_index: u32 = 3;

/// Toolkit-style slider props. All styling via props with neutral dark
/// defaults — no theme/app imports. `id` becomes the Clay element ID
/// (stable across frames for hover/selection queries).
/// `value` is clamped to [min, max]; fraction = (value-min)/(max-min or 1).
/// `w`/`h` fix the outer hit area to an exact pixel size. `track_h` is the
/// bar thickness, `radius` rounds track + fill. `track_bg` paints the empty
/// bar, `fill_bg` the filled portion, `thumb_color` the knob circle
/// (`thumb_size` square, radius = size/2).
/// `hover_fill` (null = no hover tint) overrides the fill bg while hovered.
/// `disabled` paints track + fill with `disabled_bg`, suppresses hover chrome
/// and skips click registration (declare never fires; owner dispatch via
/// stored props must also check `disabled`).
/// `on_change`/`ctx` are stored verbatim for owner-side dispatch; the
/// slider declaration itself is unchanged (hover chrome only).
pub const SliderProps = struct {
    id: []const u8,
    value: f32 = 0.5,
    min: f32 = 0,
    max: f32 = 1,
    w: u32 = 200,
    h: u32 = 24,
    track_h: u32 = 4,
    radius: u32 = 2,
    track_bg: u32 = 0x3a3a3a,
    fill_bg: u32 = 0x4caf50,
    thumb_size: u32 = 16,
    thumb_color: u32 = 0xffffff,
    hover_fill: ?u32 = null,
    disabled: bool = false,
    disabled_bg: u32 = 0x2a2a2a,
    on_change: ClickFn = null,
    ctx: ?*anyopaque = null,
};

/// Pure: clamped 0..1 fraction for value in [min, max].
/// Guards max <= min with denom 1 (avoids div-by-zero; yields 0 at min).
pub fn fracOf(value: f32, min: f32, max: f32) f32 {
    const lo = @min(min, max);
    const hi = @max(min, max);
    const clamped = @min(@max(value, lo), hi);
    const denom = hi - lo;
    const d: f32 = if (denom <= 0) 1 else denom;
    // NOTE: when min > max the range is inverted; anchor to lo so the
    // fraction still runs 0 (at lo) .. 1 (at hi).
    const frac = (clamped - lo) / d;
    return @min(1, @max(0, frac));
}

/// Declare a slider: outer hit area (fixed w/h, transparent) + track bar
/// (fixed w x track_h) + fill bar (w*frac x track_h, left-aligned) + thumb
/// circle (thumb_size, parked at the fill end via the fill's right+center
/// child_alignment — the child_alignment trick).
/// Hover: uses `cl.hovered()` (Clay_Hovered — true when the pointer is over
/// the currently open element) to switch the fill bg to `hover_fill` when
/// set. Callers must feed pointer state via `cl.setPointerState()` each
/// frame (same as Shell.frame); without it the slider renders the resting bg.
/// Selection/click handling stays caller-side (like the button hitTest
/// pattern): after layout, query
/// `cl.pointerOver(cl.getElementId(props.id))`.
///
/// No drag yet: the engine has no per-component drag (click_registry is
/// click-only). scroll.zig / host.zig carry slider-style press-drag for
/// scroll containers (pointer down = scroll down, 1:1 clamped) — a future
/// slider-drag would follow that pattern (press latch + motion nudge +
/// value remap) but is out of scope here; this component is click-only.
pub fn slider(props: SliderProps) void {
    // NOTE: cl.hovered() must be evaluated INSIDE the UI() config literal
    // (after Clay__OpenElement runs, while this element is open) so it
    // queries this slider part — calling it here beforehand would query the
    // parent/root instead and hover_fill would never (or spuriously) trigger.
    // Disabled sliders never take hover chrome and never register clicks.
    const frac = fracOf(props.value, props.min, props.max);
    const w_f: f32 = @floatFromInt(props.w);
    const h_f: f32 = @floatFromInt(props.h);
    const track_h_f: f32 = @floatFromInt(props.track_h);
    const fill_w: f32 = w_f * frac;
    const thumb_f: f32 = @floatFromInt(props.thumb_size);
    cl.UI()(.{
        .id = .ID(props.id),
        .layout = .{
            .direction = .left_to_right,
            .sizing = .{
                .w = .fixed(w_f),
                .h = .fixed(h_f),
            },
            .child_alignment = .center,
        },
        .background_color = .{ 0, 0, 0, 0 },
    })({
        cl.UI()(.{
            .id = .IDI(props.id, track_index),
            .layout = .{
                .direction = .left_to_right,
                .sizing = .{
                    .w = .fixed(w_f),
                    .h = .fixed(track_h_f),
                },
                .child_alignment = .{ .x = .left, .y = .center },
            },
            .background_color = render.u32ToClayColor(if (props.disabled) props.disabled_bg else props.track_bg),
            .corner_radius = .all(@floatFromInt(props.radius)),
        })({
            cl.UI()(.{
                .id = .IDI(props.id, fill_index),
                .layout = .{
                    .direction = .left_to_right,
                    .sizing = .{
                        .w = .fixed(fill_w),
                        .h = .fixed(track_h_f),
                    },
                    .child_alignment = .{ .x = .right, .y = .center },
                },
                // NOTE: cl.hovered() stays INSIDE this UI() literal (while
                // the fill is open) — hoisting it above would query the
                // track/outer instead.
                .background_color = render.u32ToClayColor(if (props.disabled) props.disabled_bg else if (cl.hovered()) (props.hover_fill orelse props.fill_bg) else props.fill_bg),
                .corner_radius = .all(@floatFromInt(props.radius)),
            })({
                cl.UI()(.{
                    .id = .IDI(props.id, thumb_index),
                    .layout = .{
                        .sizing = .{
                            .w = .fixed(thumb_f),
                            .h = .fixed(thumb_f),
                        },
                    },
                    .background_color = render.u32ToClayColor(props.thumb_color),
                    .corner_radius = .all(thumb_f / 2.0),
                })({});
            });
        });
    });
    // Semantics: a slider is draggable, so it reports `drag` rather than a
    // plain click. The numeric value is not mirrored into `value` (a []const u8
    // would need a per-frame buffer); assert on it through the app's own state.
    semantics.register(.{
        .id = cl.getElementId(props.id),
        .tag = props.id,
        .role = .slider,
        .flags = .{ .enabled = !props.disabled },
        .actions = .{ .drag = true },
    });
    if (!props.disabled) {
        if (props.on_change) |cb| {
            // Horizontal-resize cursor: draggable slider track.
            // Disabled skips registration so hover stays .default.
            registry.registerClickCursor(cl.getElementId(props.id), cb, props.ctx, .ew_resize);
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

fn declareSlider() void {
    slider(.{ .id = "test-slider" });
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

test "slider emits outer + track + fill + thumb rectangles and no text" {
    var rects: usize = 0;
    var texts: usize = 0;
    try countCommands(declareSlider, &rects, &texts);
    // Outer (transparent) + track + fill + thumb = 4; allow 3 if the
    // backend culls the transparent outer or a zero-size fill.
    try std.testing.expect(rects >= 3 and rects <= 4);
    try std.testing.expectEqual(@as(usize, 0), texts);
}

test "SliderProps carries neutral defaults" {
    const p = SliderProps{ .id = "x" };
    try std.testing.expectEqual(@as(f32, 0.5), p.value);
    try std.testing.expectEqual(@as(f32, 0), p.min);
    try std.testing.expectEqual(@as(f32, 1), p.max);
    try std.testing.expectEqual(@as(u32, 200), p.w);
    try std.testing.expectEqual(@as(u32, 24), p.h);
    try std.testing.expectEqual(@as(u32, 4), p.track_h);
    try std.testing.expectEqual(@as(u32, 2), p.radius);
    try std.testing.expectEqual(@as(u32, 0x3a3a3a), p.track_bg);
    try std.testing.expectEqual(@as(u32, 0x4caf50), p.fill_bg);
    try std.testing.expectEqual(@as(u32, 16), p.thumb_size);
    try std.testing.expectEqual(@as(u32, 0xffffff), p.thumb_color);
    try std.testing.expect(p.hover_fill == null);
    try std.testing.expect(!p.disabled);
    try std.testing.expectEqual(@as(u32, 0x2a2a2a), p.disabled_bg);
    try std.testing.expect(p.on_change == null);
    try std.testing.expect(p.ctx == null);
}

test "fracOf clamps below min and above max, guards zero range" {
    try std.testing.expectEqual(@as(f32, 0), fracOf(-1, 0, 1));
    try std.testing.expectEqual(@as(f32, 0), fracOf(0, 0, 1));
    try std.testing.expectEqual(@as(f32, 0.5), fracOf(0.5, 0, 1));
    try std.testing.expectEqual(@as(f32, 1), fracOf(1, 0, 1));
    try std.testing.expectEqual(@as(f32, 1), fracOf(2, 0, 1));
    try std.testing.expectEqual(@as(f32, 0), fracOf(5, 5, 5));
}

fn rectColorForId(cmds: []cl.RenderCommand, id: u32) ?cl.Color {
    for (cmds) |c| {
        if (c.command_type == .rectangle and c.id == id) return c.render_data.rectangle.background_color;
    }
    return null;
}

fn layoutSlider(props: SliderProps) ![]cl.RenderCommand {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    slider(props);
    return cl.endLayout();
}

test "slider track/fill/thumb colors match props" {
    const cmds = try layoutSlider(.{ .id = "test-slider-color" });
    const track_id = cl.getElementId("test-slider-color").id;
    _ = track_id;
    const track_c = rectColorForId(cmds, cl.ElementId.IDI("test-slider-color", track_index).id);
    const fill_c = rectColorForId(cmds, cl.ElementId.IDI("test-slider-color", fill_index).id);
    const thumb_c = rectColorForId(cmds, cl.ElementId.IDI("test-slider-color", thumb_index).id);
    try std.testing.expect(track_c != null);
    try std.testing.expect(fill_c != null);
    try std.testing.expect(thumb_c != null);
    try std.testing.expectEqual(render.u32ToClayColor(0x3a3a3a), track_c.?);
    try std.testing.expectEqual(render.u32ToClayColor(0x4caf50), fill_c.?);
    try std.testing.expectEqual(render.u32ToClayColor(0xffffff), thumb_c.?);
}

fn declareClampedSlider() void {
    slider(.{ .id = "test-slider-clamp", .value = 2.0, .min = 0, .max = 1 });
}

test "slider value above max clamps fill to full width" {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declareClampedSlider();
    _ = cl.endLayout();
    const fill_bb = cl.getElementData(cl.ElementId.IDI("test-slider-clamp", fill_index)).bounding_box;
    try std.testing.expectEqual(@as(f32, 200), fill_bb.width);
}

const ClickCtx = struct {
    calls: usize = 0,
};

fn testOnChange(ctx: ?*anyopaque) void {
    const c: *ClickCtx = @ptrCast(@alignCast(ctx.?));
    c.calls += 1;
}

var click_rec = ClickCtx{};

fn declareClickSlider() void {
    slider(.{ .id = "test-click-slider", .on_change = testOnChange, .ctx = &click_rec });
}

fn declareNoClickSlider() void {
    slider(.{ .id = "test-noclick-slider" });
}

test "slider without on_change registers nothing; dispatchClick returns false" {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    registry.beginFrame();
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declareNoClickSlider();
    _ = cl.endLayout();
    const bb = cl.getElementData(cl.getElementId("test-noclick-slider")).bounding_box;
    try std.testing.expect(!registry.dispatchClick(bb.x + bb.width * 0.5, bb.y + bb.height * 0.5));
}

test "slider self-registers on_change; dispatchClick at center fires once" {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    click_rec = .{};
    registry.beginFrame();
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declareClickSlider();
    _ = cl.endLayout();
    const bb = cl.getElementData(cl.getElementId("test-click-slider")).bounding_box;
    try std.testing.expect(registry.dispatchClick(bb.x + bb.width * 0.5, bb.y + bb.height * 0.5));
    try std.testing.expectEqual(@as(usize, 1), click_rec.calls);
    try std.testing.expect(!registry.dispatchClick(700, 460));
    try std.testing.expectEqual(@as(usize, 1), click_rec.calls);
}

fn declareDisabledSlider() void {
    slider(.{ .id = "test-disabled-slider", .disabled = true, .on_change = testOnChange, .ctx = &click_rec });
}

test "disabled slider uses disabled_bg and registers no click" {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    click_rec = .{};
    registry.beginFrame();
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declareDisabledSlider();
    const cmds = cl.endLayout();
    const track_bg = rectColorForId(cmds, cl.ElementId.IDI("test-disabled-slider", track_index).id);
    try std.testing.expect(track_bg != null);
    try std.testing.expectEqual(render.u32ToClayColor(0x2a2a2a), track_bg.?);
    const bb = cl.getElementData(cl.getElementId("test-disabled-slider")).bounding_box;
    try std.testing.expect(!registry.dispatchClick(bb.x + bb.width * 0.5, bb.y + bb.height * 0.5));
    try std.testing.expectEqual(@as(usize, 0), click_rec.calls);
}
