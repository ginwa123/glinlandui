// Agnostic reusable Clay scroll container (toolkit-style, library only).
const std = @import("std");
const cl = @import("zclay");
const prop = @import("../props.zig");
const Color = @import("../color.zig").Color;
const box_mod = @import("box.zig");
const click_registry = @import("click_registry.zig");
const semantics = @import("../semantics.zig");
const frame_mod = @import("../frame.zig");

/// Scroll axes: vertical (column content, clips top-to-bottom), horizontal (row content, clips left-to-right), or both.
pub const Direction = enum {
    vertical,
    horizontal,
    both,
};

/// Reserved Clay IDI offsets under .ID(props.id) for the floating thumbs.
pub const vthumb_index: u32 = 1;
pub const hthumb_index: u32 = 2;

/// Toolkit-style scroll props.
pub const ScrollProps = struct {
    id: prop.Id,
    direction: Direction = .vertical,
    w: box_mod.Size = .grow,
    h: box_mod.Size = .grow,
    min_w: f32 = 0,
    min_h: f32 = 0,
    max_w: f32 = 0,
    max_h: f32 = 0,
    bg: ?Color = null,
    pad: u16 = 0,
    gap: u16 = 0,
    radius: u32 = 0,
    border_width: u16 = 0,
    border_color: Color = Color.rgb(0x00, 0x00, 0x00),
    disabled: bool = false,
    show_scrollbar: bool = true,
    scrollbar_width: u16 = 8,
    scrollbar_margin: f32 = 4,
    track_bg: ?Color = null,
    thumb_bg: Color = Color.rgb(0x5a, 0x5a, 0x5a),
    thumb_hover_bg: Color = Color.rgb(0x7a, 0x7a, 0x7a),
    thumb_radius: u32 = 4,
    min_thumb: f32 = 24,
    z_index: i16 = 10,
};

/// Pure: Clay clip flags for a scroll direction.
pub fn clipAxes(direction: Direction) struct { h: bool, v: bool } {
    return switch (direction) {
        .vertical => .{ .h = false, .v = true },
        .horizontal => .{ .h = true, .v = false },
        .both => .{ .h = true, .v = true },
    };
}

/// Pure: true when content overflows the viewport on an axis (a scrollbar is needed).
pub fn needsScrollbar(viewport: f32, content: f32) bool {
    return content > viewport + 0.5;
}

/// Pure: thumb length for a track of `track_len` px.
pub fn thumbLen(viewport: f32, content: f32, track_len: f32, min_thumb: f32) f32 {
    if (!needsScrollbar(viewport, content)) return 0;
    if (content <= 0 or track_len <= 0) return 0;
    const proportional = track_len * viewport / content;
    return @min(track_len, @max(min_thumb, proportional));
}

/// Pure: thumb offset from the track start for a Clay scroll position.
pub fn thumbOffset(scroll_pos: f32, viewport: f32, content: f32, track_len: f32, thumb_len: f32) f32 {
    const max_scroll = content - viewport;
    if (max_scroll <= 0) return 0;
    const travel = track_len - thumb_len;
    if (travel <= 0) return 0;
    const t = -scroll_pos / max_scroll;
    return @min(travel, @max(0, t * travel));
}

/// Forward a wheel delta to Clay's scroll containers.
pub fn updateScroll(dx: f32, dy: f32, dt: f32) void {
    // Clay multiplies a wheel delta by 10 internally, so a trackpad would move the list ten times further than the finger. Divide it out.
    cl.updateScrollContainers(false, .{ .x = dx / frame_mod.wheel_factor, .y = dy / frame_mod.wheel_factor }, dt);
}

/// What a scroll container is showing this frame, in logical units.
pub const View = struct {
    found: bool = false,
    /// Scroll offset, positive going right.
    x: f32 = 0,
    /// Scroll offset, positive going down.
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
    content_width: f32 = 0,
    content_height: f32 = 0,
};

/// Read a container's offset, viewport and content, so a virtualised list never touches Clay's own struct.
pub fn view(id: []const u8) View {
    const data = cl.getScrollContainerData(cl.getElementId(id));
    if (!data.found) return .{};
    return .{
        .found = true,
        .x = @max(-data.scroll_position.x, 0),
        .y = @max(-data.scroll_position.y, 0),
        .width = data.scroll_container_dimensions.w,
        .height = data.scroll_container_dimensions.h,
        .content_width = data.content_dimensions.w,
        .content_height = data.content_dimensions.h,
    };
}

/// Programmatic scroll: nudge the container's scroll position directly (positive dy scrolls down, matching Wayland axis coords — negated internally for.
pub fn scrollBy(id: []const u8, dx: f32, dy: f32) void {
    nudgeClamped(id, .both, dx, dy);
}

/// Clamped 1:1 nudge of one container along its axes (slider units, NOT Clay's x10 wheel factor).
fn nudgeClamped(id: []const u8, dir: Direction, dx: f32, dy: f32) void {
    const data = cl.getScrollContainerData(cl.getElementId(id));
    if (!data.found) return;
    const axes = clipAxes(dir);
    if (axes.h) {
        const max_x = @max(0, data.content_dimensions.w - data.scroll_container_dimensions.w);
        data.scroll_position.x = @min(0, @max(-max_x, data.scroll_position.x - dx));
    }
    if (axes.v) {
        const max_y = @max(0, data.content_dimensions.h - data.scroll_container_dimensions.h);
        data.scroll_position.y = @min(0, @max(-max_y, data.scroll_position.y - dy));
    }
}

// ---- Per-frame scroll-container registry (for drag hit-testing) ---- scroll() registers its id + direction every declare; the owner resets per frame.

const ScrollReg = struct {
    id: []const u8,
    dir: Direction,
};

var scroll_regs: [8]ScrollReg = undefined;
var scroll_reg_n: usize = 0;

/// Reset the per-frame scroll registry. Call once per frame before declare.
pub fn beginScrollFrame() void {
    scroll_reg_n = 0;
}

fn registerScroll(id: []const u8, dir: Direction) void {
    for (scroll_regs[0..scroll_reg_n]) |r| {
        if (std.mem.eql(u8, r.id, id)) return;
    }
    if (scroll_reg_n >= scroll_regs.len) return;
    scroll_regs[scroll_reg_n] = .{ .id = id, .dir = dir };
    scroll_reg_n += 1;
}

/// Slider-style drag scroll: nudge the topmost registered scroll container under (x, y), 1:1 clamped.
pub fn dragScroll(x: f32, y: f32, dx: f32, dy: f32) void {
    var i = scroll_reg_n;
    while (i > 0) {
        i -= 1;
        const r = scroll_regs[i];
        const el = cl.getElementData(cl.getElementId(r.id));
        if (!el.found) continue;
        const bb = el.bounding_box;
        if (x < bb.x or x >= bb.x + bb.width or y < bb.y or y >= bb.y + bb.height) continue;
        nudgeClamped(r.id, r.dir, dx, dy);
        return;
    }
}

fn toSizingAxis(s: box_mod.Size, min: f32, max: f32) cl.SizingAxis {
    const constrained = min > 0 or max > 0;
    return switch (s) {
        .fit => if (constrained) .fitMinMax(.{ .min = min, .max = max }) else .fit,
        .grow => if (constrained) .growMinMax(.{ .min = min, .max = max }) else .grow,
        .fixed => |v| .fixed(v),
        .percent => |v| .percent(v),
        .clamp => |c| if (c.grow) .growMinMax(.{ .min = c.min, .max = c.max }) else .fitMinMax(.{ .min = c.min, .max = c.max }),
    };
}

/// Declare a scroll container: Clay clip element (.ID(props.id)) with the mapped sizing/padding/gap/radius, `children(ctx)` invoked inside for.
pub fn scroll(props: ScrollProps, ctx: anytype, comptime children: fn (@TypeOf(ctx)) void) void {
    registerScroll(props.id.str(), props.direction);
    const axes = clipAxes(props.direction);
    // Content flows along the scroll axis: rows overflow horizontally, columns overflow vertically (both => column; wrap rows in a row box for horizontal.
    const dir: cl.LayoutDirection = switch (props.direction) {
        .horizontal => .left_to_right,
        .vertical, .both => .top_to_bottom,
    };
    // The thumb floats OVER the viewport, so an overflowing container insets its content by the gutter the thumb occupies.
    const pad = cl.Padding{
        .left = props.pad,
        .right = props.pad + scrollbarGutter(props, axes.v, true),
        .top = props.pad,
        .bottom = props.pad + scrollbarGutter(props, axes.h, false),
    };
    cl.UI()(.{
        .id = props.id.clay(),
        .layout = .{
            .direction = dir,
            .sizing = .{
                .w = toSizingAxis(props.w, props.min_w, props.max_w),
                .h = toSizingAxis(props.h, props.min_h, props.max_h),
            },
            .padding = pad,
            .child_gap = props.gap,
        },
        // By ID, not Clay_GetScrollOffset(): that matches the open element by a stale pointer and drops the offset when an earlier element blinks.
        .clip = .{ .horizontal = axes.h, .vertical = axes.v, .child_offset = cl.getScrollOffsetById(props.id.clay()) },
        .background_color = if (props.bg) |b| b.toClay() else .{ 0, 0, 0, 0 },
        .corner_radius = .all(@floatFromInt(props.radius)),
        .border = if (props.border_width > 0) .{
            .color = props.border_color.toClay(),
            .width = .outside(props.border_width),
        } else .{},
    })({
        // Clip ancestry for the semantics layer: every node registered inside this container records it, so resolve() can compute what is actually visible and.
        semantics.pushAncestor(props.id.clay(), true);
        // A target inside a scroll container answers only inside it: a row scrolled under the footer must not swallow the footer's click.
        const viewport = cl.getElementData(props.id.clay());
        click_registry.pushClip(if (viewport.found) .{
            .x = viewport.bounding_box.x,
            .y = viewport.bounding_box.y,
            .w = viewport.bounding_box.width,
            .h = viewport.bounding_box.height,
        } else null);
        children(ctx);
        click_registry.popClip();
        semantics.popAncestor();
    });
    // The container's own node is registered AFTER the pop, so it does not list itself as an ancestor.
    semantics.register(.{
        .id = props.id.clay(),
        .tag = props.id.str(),
        .role = .scroll,
        .actions = .{ .scroll = true },
        .flags = .{ .enabled = !props.disabled },
    });
    if (!props.show_scrollbar or props.disabled) return;
    declareScrollbars(props);
}

// Width a scrollbar takes out of the content on its axis: the thumb plus the margin it floats by, or zero when nothing overflows.
fn scrollbarGutter(props: ScrollProps, axis: bool, vertical: bool) u16 {
    if (!axis or !props.show_scrollbar or props.disabled) return 0;
    const data = cl.getScrollContainerData(props.id.clay());
    if (!data.found) return 0;
    const viewport = if (vertical) data.scroll_container_dimensions.h else data.scroll_container_dimensions.w;
    const content = if (vertical) data.content_dimensions.h else data.content_dimensions.w;
    if (!needsScrollbar(viewport, content)) return 0;
    return props.scrollbar_width + @as(u16, @intFromFloat(props.scrollbar_margin));
}

/// Floating scrollbar thumbs for every overflowing scroll axis, attached to the viewport (previous-frame scroll data; first frame declares nothing —.
fn declareScrollbars(props: ScrollProps) void {
    const data = cl.getScrollContainerData(props.id.clay());
    if (!data.found) return;
    const parent_id = props.id.clay().id;
    const axes = clipAxes(props.direction);
    if (axes.v) {
        const viewport = data.scroll_container_dimensions.h;
        const content = data.content_dimensions.h;
        if (needsScrollbar(viewport, content)) {
            const track = @max(0, viewport - props.scrollbar_margin * 2);
            const len = thumbLen(viewport, content, track, props.min_thumb);
            if (len > 0) {
                const off = thumbOffset(data.scroll_position.y, viewport, content, track, len);
                const w: f32 = @floatFromInt(props.scrollbar_width);
                if (props.track_bg) |tb| {
                    cl.UI()(.{
                        .floating = .{
                            .attach_to = .to_element_with_id,
                            .parentId = parent_id,
                            .attach_points = .{ .element = .right_top, .parent = .right_top },
                            .offset = .{ .x = -props.scrollbar_margin, .y = props.scrollbar_margin },
                            .z_index = props.z_index,
                            .pointer_capture_mode = .passthrough,
                        },
                        .layout = .{ .sizing = .{ .w = .fixed(w), .h = .fixed(track) } },
                        .background_color = tb.toClay(),
                        .corner_radius = .all(@floatFromInt(props.thumb_radius)),
                    })({});
                }
                // The attach point is the edge the bar sits against, so the margin is the whole offset: subtracting the width pushed it 8 px in.
                cl.UI()(.{
                    .id = .IDI(props.id.str(), vthumb_index),
                    .floating = .{
                        .attach_to = .to_element_with_id,
                        .parentId = parent_id,
                        .attach_points = .{ .element = .right_top, .parent = .right_top },
                        .offset = .{ .x = -props.scrollbar_margin, .y = props.scrollbar_margin + off },
                        .z_index = props.z_index + 1,
                        .pointer_capture_mode = .passthrough,
                    },
                    .layout = .{ .sizing = .{ .w = .fixed(w), .h = .fixed(len) } },
                    .background_color = (if (cl.hovered()) props.thumb_hover_bg else props.thumb_bg).toClay(),
                    .corner_radius = .all(@floatFromInt(props.thumb_radius)),
                })({});
            }
        }
    }
    if (axes.h) {
        const viewport = data.scroll_container_dimensions.w;
        const content = data.content_dimensions.w;
        if (needsScrollbar(viewport, content)) {
            const track = @max(0, viewport - props.scrollbar_margin * 2);
            const len = thumbLen(viewport, content, track, props.min_thumb);
            if (len > 0) {
                const off = thumbOffset(data.scroll_position.x, viewport, content, track, len);
                const w: f32 = @floatFromInt(props.scrollbar_width);
                if (props.track_bg) |tb| {
                    cl.UI()(.{
                        .floating = .{
                            .attach_to = .to_element_with_id,
                            .parentId = parent_id,
                            .attach_points = .{ .element = .left_bottom, .parent = .left_bottom },
                            .offset = .{ .x = props.scrollbar_margin, .y = -props.scrollbar_margin },
                            .z_index = props.z_index,
                            .pointer_capture_mode = .passthrough,
                        },
                        .layout = .{ .sizing = .{ .w = .fixed(track), .h = .fixed(w) } },
                        .background_color = tb.toClay(),
                        .corner_radius = .all(@floatFromInt(props.thumb_radius)),
                    })({});
                }
                cl.UI()(.{
                    .id = .IDI(props.id.str(), hthumb_index),
                    .floating = .{
                        .attach_to = .to_element_with_id,
                        .parentId = parent_id,
                        .attach_points = .{ .element = .left_bottom, .parent = .left_bottom },
                        .offset = .{ .x = props.scrollbar_margin + off, .y = -props.scrollbar_margin },
                        .z_index = props.z_index + 1,
                        .pointer_capture_mode = .passthrough,
                    },
                    .layout = .{ .sizing = .{ .w = .fixed(len), .h = .fixed(w) } },
                    .background_color = (if (cl.hovered()) props.thumb_hover_bg else props.thumb_bg).toClay(),
                    .corner_radius = .all(@floatFromInt(props.thumb_radius)),
                })({});
            }
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

fn emptyChildren(_: void) void {}

fn declareEmptyScroll() void {
    scroll(.{ .id = .{ .text = "test-empty-scroll" }, .h = .{ .fixed = 100 } }, {}, emptyChildren);
}

/// Run one headless Clay frame around `declare_fn`, returning the render commands (valid until the next beginLayout).
fn layoutCommands(declare_fn: *const fn () void) ![]cl.RenderCommand {
    const mem_size = cl.minMemorySize();
    // NOTE: intentionally leaked (page_allocator, never freed).
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declare_fn();
    return cl.endLayout();
}

fn countScissors(cmds: []cl.RenderCommand) usize {
    var n: usize = 0;
    for (cmds) |c| switch (c.command_type) {
        .scissor_start => n += 1,
        else => {},
    };
    return n;
}

test "ScrollProps carries neutral defaults (scrollbar on)" {
    const p = ScrollProps{ .id = .{ .text = "x" } };
    try std.testing.expect(p.direction == .vertical);
    try std.testing.expect(p.w == .grow);
    try std.testing.expect(p.h == .grow);
    try std.testing.expect(p.bg == null);
    try std.testing.expectEqual(@as(u16, 0), p.pad);
    try std.testing.expectEqual(@as(u16, 0), p.gap);
    try std.testing.expectEqual(@as(u32, 0), p.radius);
    try std.testing.expectEqual(@as(u16, 0), p.border_width);
    try std.testing.expect(!p.disabled);
    try std.testing.expect(p.show_scrollbar);
    try std.testing.expectEqual(@as(u16, 8), p.scrollbar_width);
    try std.testing.expect(p.track_bg == null);
    try std.testing.expectEqual(Color.rgb(0x5a, 0x5a, 0x5a), p.thumb_bg);
    try std.testing.expectEqual(Color.rgb(0x7a, 0x7a, 0x7a), p.thumb_hover_bg);
    try std.testing.expectEqual(@as(f32, 24), p.min_thumb);
}

test "clipAxes maps direction to Clay clip flags" {
    try std.testing.expect(!clipAxes(.vertical).h and clipAxes(.vertical).v);
    try std.testing.expect(clipAxes(.horizontal).h and !clipAxes(.horizontal).v);
    try std.testing.expect(clipAxes(.both).h and clipAxes(.both).v);
}

test "needsScrollbar only when content overflows the viewport" {
    try std.testing.expect(!needsScrollbar(100, 100));
    try std.testing.expect(!needsScrollbar(100, 50));
    try std.testing.expect(!needsScrollbar(100, 100.4));
    try std.testing.expect(needsScrollbar(100, 101));
    try std.testing.expect(needsScrollbar(100, 400));
}

test "thumbLen is proportional, clamped to min and track" {
    // Half visible => half the track.
    try std.testing.expectApproxEqAbs(@as(f32, 50), thumbLen(100, 200, 100, 24), 0.001);
    // Tiny visible fraction => min clamp wins over a sliver.
    try std.testing.expectApproxEqAbs(@as(f32, 24), thumbLen(10, 200, 100, 24), 0.001);
    // Oversized min_thumb never escapes the track.
    try std.testing.expectApproxEqAbs(@as(f32, 100), thumbLen(10, 20, 100, 200), 0.001);
    // Fitting content => no thumb.
    try std.testing.expectEqual(@as(f32, 0), thumbLen(100, 100, 100, 24));
    try std.testing.expectEqual(@as(f32, 0), thumbLen(100, 50, 100, 24));
}

test "thumbOffset maps the scroll range onto the thumb travel" {
    // viewport 100, content 400 => max_scroll 300, travel 100 - 25 = 75.
    const track: f32 = 100;
    const len: f32 = 25;
    try std.testing.expectApproxEqAbs(@as(f32, 0), thumbOffset(0, 100, 400, track, len), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 37.5), thumbOffset(-150, 100, 400, track, len), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 75), thumbOffset(-300, 100, 400, track, len), 0.001);
    // Overscroll clamps to the travel ends.
    try std.testing.expectApproxEqAbs(@as(f32, 0), thumbOffset(50, 100, 400, track, len), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 75), thumbOffset(-9999, 100, 400, track, len), 0.001);
    // Fitting content => no travel.
    try std.testing.expectEqual(@as(f32, 0), thumbOffset(0, 100, 100, track, len));
}

test "scroll declares the clip container id" {
    _ = try layoutCommands(declareEmptyScroll);
    try std.testing.expect(cl.getElementData(cl.getElementId("test-empty-scroll")).found);
}

test "scroll emits scissor commands (clip container)" {
    const cmds = try layoutCommands(declareEmptyScroll);
    try std.testing.expect(countScissors(cmds) >= 1);
}

fn hChildren(_: void) void {
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        cl.UI()(.{
            .layout = .{ .sizing = .{ .w = .fixed(80), .h = .fixed(40) } },
            .background_color = .{ 100, 100, 100, 255 },
        })({});
    }
}

fn declareHScroll() void {
    scroll(.{ .id = .{ .text = "test-h-scroll" }, .direction = .horizontal, .w = .{ .fixed = 200 }, .h = .{ .fixed = 60 } }, {}, hChildren);
}

test "horizontal scroll lays content out in a row (x grows)" {
    _ = try layoutCommands(declareHScroll);
    const box = cl.getElementData(cl.getElementId("test-h-scroll")).bounding_box;
    // 6 x 80px cells overflow the 200px viewport => clipped, not grown.
    try std.testing.expectApproxEqAbs(@as(f32, 200), box.width, 0.5);
    try std.testing.expect(countScissors(try layoutCommands(declareEmptyScroll)) >= 1);
}

// ---- Two-frame scrollbar tests: the thumb reads previous-frame scroll data (same one-frame lag as the official Clay scrollbar example), so frame 1.

fn overflowChildren(_: void) void {
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        cl.UI()(.{
            .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(40) } },
            .background_color = .{ 100, 100, 100, 255 },
        })({});
    }
}

fn declareOverflowScroll() void {
    scroll(.{ .id = .{ .text = "test-scroll" }, .h = .{ .fixed = 100 }, .w = .{ .fixed = 200 } }, {}, overflowChildren);
}

fn declareOverflowNoBar() void {
    scroll(.{ .id = .{ .text = "test-scroll-nobar" }, .h = .{ .fixed = 100 }, .w = .{ .fixed = 200 }, .show_scrollbar = false }, {}, overflowChildren);
}

fn declareFitScroll() void {
    scroll(.{ .id = .{ .text = "test-scroll-fit" }, .h = .{ .fixed = 400 }, .w = .{ .fixed = 200 } }, {}, overflowChildren);
}

/// Run TWO headless frames around `declare_fn` in one Clay context and return the second frame's commands (scroll data is previous-frame).
fn layoutCommandsSecondFrame(declare_fn: *const fn () void) ![]cl.RenderCommand {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declare_fn();
    _ = cl.endLayout();
    cl.beginLayout();
    declare_fn();
    return cl.endLayout();
}

test "overflowing vertical scroll shows a thumb on the second frame" {
    _ = try layoutCommandsSecondFrame(declareOverflowScroll);
    try std.testing.expect(cl.getElementData(cl.ElementId.IDI("test-scroll", vthumb_index)).found);
}

test "show_scrollbar=false declares no thumb even when overflowing" {
    _ = try layoutCommandsSecondFrame(declareOverflowNoBar);
    try std.testing.expect(!cl.getElementData(cl.ElementId.IDI("test-scroll-nobar", vthumb_index)).found);
}

test "fitting content declares no thumb (nothing to scroll)" {
    _ = try layoutCommandsSecondFrame(declareFitScroll);
    try std.testing.expect(!cl.getElementData(cl.ElementId.IDI("test-scroll-fit", vthumb_index)).found);
}

fn declareOverflowHScroll() void {
    scroll(.{ .id = .{ .text = "test-scroll-h" }, .direction = .horizontal, .w = .{ .fixed = 200 }, .h = .{ .fixed = 60 } }, {}, hChildren);
}

test "overflowing horizontal scroll shows a bottom thumb on the second frame" {
    _ = try layoutCommandsSecondFrame(declareOverflowHScroll);
    try std.testing.expect(cl.getElementData(cl.ElementId.IDI("test-scroll-h", hthumb_index)).found);
    // No vertical thumb for a horizontal-only scroll.
    try std.testing.expect(!cl.getElementData(cl.ElementId.IDI("test-scroll-h", vthumb_index)).found);
}

// ---- Scroll-delta regression tests: a wheel delta must move CONTENT, not just the thumb.

fn scrollProbeChildren(_: void) void {
    cl.UI()(.{
        .id = .ID("scroll-probe"),
        .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(40) } },
        .background_color = .{ 200, 50, 50, 255 },
    })({});
    var i: usize = 0;
    while (i < 9) : (i += 1) {
        cl.UI()(.{
            .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(40) } },
            .background_color = .{ 100, 100, 100, 255 },
        })({});
    }
}

fn declareProbeScroll() void {
    scroll(.{ .id = .{ .text = "test-scroll-probe" }, .h = .{ .fixed = 100 }, .w = .{ .fixed = 200 } }, {}, scrollProbeChildren);
}

/// Two frames in one context with pointer + wheel control.
fn layoutScrollFrames(dx: f32, dy: f32) ![2]f32 {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    // Frame 1: parked pointer, plain declare.
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declareProbeScroll();
    _ = cl.endLayout();
    const y0 = cl.getElementData(cl.getElementId("scroll-probe")).bounding_box.y;
    // Frame 2: hover the container, wheel, re-declare.
    const box = cl.getElementData(cl.getElementId("test-scroll-probe")).bounding_box;
    cl.setPointerState(.{ .x = box.x + box.width * 0.5, .y = box.y + box.height * 0.5 }, false);
    updateScroll(dx, dy, 1.0 / 60.0);
    cl.beginLayout();
    declareProbeScroll();
    _ = cl.endLayout();
    const y1 = cl.getElementData(cl.getElementId("scroll-probe")).bounding_box.y;
    return .{ y0, y1 };
}

test "wheel delta moves scroll content (not just the thumb)" {
    // Clay coords: negative dy scrolls down (content moves up). Five points of gesture move five pixels, not fifty.
    const ys = try layoutScrollFrames(0, -5);
    try std.testing.expectApproxEqAbs(ys[0] - 5, ys[1], 0.5);
}

test "wheel delta updates scrollPosition consistently with content" {
    _ = try layoutScrollFrames(0, -5);
    const data = cl.getScrollContainerData(cl.getElementId("test-scroll-probe"));
    try std.testing.expect(data.found);
    try std.testing.expectApproxEqAbs(@as(f32, -5), data.scroll_position.y, 0.5);
}

// Boxes declared BEFORE the scroll container: one element appearing earlier shifts the container's index in Clay's element array.
var filler_boxes: usize = 0;

fn declareWithFiller() void {
    var i: usize = 0;
    while (i < filler_boxes) : (i += 1) {
        cl.UI()(.{ .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(1) } } })({});
    }
    declareProbeScroll();
}

test "the scroll offset survives an element declared before the container" {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);

    filler_boxes = 0;
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declareWithFiller();
    _ = cl.endLayout();
    const box = cl.getElementData(cl.getElementId("test-scroll-probe")).bounding_box;
    const off0 = cl.getElementData(cl.getElementId("scroll-probe")).bounding_box.y - box.y;

    // Wheel down 40 with the pointer over the container: the content moves up 40.
    cl.setPointerState(.{ .x = box.x + 1, .y = box.y + 1 }, false);
    updateScroll(0, -40, 1.0 / 60.0);
    cl.beginLayout();
    declareWithFiller();
    _ = cl.endLayout();
    const off1 = cl.getElementData(cl.getElementId("scroll-probe")).bounding_box.y - cl.getElementData(cl.getElementId("test-scroll-probe")).bounding_box.y;
    try std.testing.expectApproxEqAbs(off0 - 40, off1, 0.5);

    // One extra element before the container, exactly like a caret blinking into the frame: the offset must not move.
    filler_boxes = 1;
    cl.beginLayout();
    declareWithFiller();
    _ = cl.endLayout();
    const off2 = cl.getElementData(cl.getElementId("scroll-probe")).bounding_box.y - cl.getElementData(cl.getElementId("test-scroll-probe")).bounding_box.y;
    try std.testing.expectApproxEqAbs(off1, off2, 0.5);
}

test "an overflowing container insets its content by the scrollbar gutter" {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);

    // Frame 1 knows nothing about the content yet, so there is no thumb and no gutter.
    cl.beginLayout();
    declareProbeScroll();
    _ = cl.endLayout();
    const w1 = cl.getElementData(cl.getElementId("scroll-probe")).bounding_box.width;

    // Frame 2 sees 400 px of content in a 100 px viewport: the thumb appears and the content stops short of it.
    cl.beginLayout();
    declareProbeScroll();
    _ = cl.endLayout();
    const w2 = cl.getElementData(cl.getElementId("scroll-probe")).bounding_box.width;

    try std.testing.expectApproxEqAbs(@as(f32, 200), w1, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 200 - 8 - 4), w2, 0.5);
}

// ---- Slider-style drag tests: pointer down = scroll down (content up), 1:1 clamped — the scrollbar-slider convention (Clay's built-in drag is.

const dispatch = @import("dispatch.zig");

/// Drag harness: fresh context + parked frame-1 declare (registers the container id); returns container center + probe y at scroll 0.
fn dragSetup(s: *dispatch.PtrState) !struct { cx: f32, cy: f32, y0: f32 } {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    beginScrollFrame();
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declareProbeScroll();
    _ = cl.endLayout();
    s.* = .{};
    const box = cl.getElementData(cl.getElementId("test-scroll-probe")).bounding_box;
    const y0 = cl.getElementData(cl.getElementId("scroll-probe")).bounding_box.y;
    return .{ .cx = box.x + box.width * 0.5, .cy = box.y + box.height * 0.5, .y0 = y0 };
}

/// Re-declare one frame (picks up scroll_position mutations).
fn dragFrame() void {
    beginScrollFrame();
    cl.beginLayout();
    declareProbeScroll();
    _ = cl.endLayout();
}

test "drag down scrolls down 1:1 (slider-style)" {
    var s = dispatch.PtrState{};
    const h = try dragSetup(&s);
    dispatch.pointerEvent(&s, h.cx, h.cy, true, 272, 720, 480);
    dispatch.pointerEvent(&s, h.cx, h.cy + 40, false, 0, 720, 480);
    try std.testing.expect(s.dragging);
    // Slider-style: pointer down 40 = content up 40.
    dragScroll(h.cx, h.cy + 40, 0, 40);
    dragFrame();
    const y1 = cl.getElementData(cl.getElementId("scroll-probe")).bounding_box.y;
    try std.testing.expectApproxEqAbs(h.y0 - 40, y1, 0.5);
}

test "drag up scrolls up (slider-style)" {
    var s = dispatch.PtrState{};
    const h = try dragSetup(&s);
    // Wheel down first (60 points of gesture = 60 px), so a 30 px drag up has room.
    cl.setPointerState(.{ .x = h.cx, .y = h.cy }, false);
    updateScroll(0, -60, 1.0 / 60.0);
    dragFrame();
    const ym = cl.getElementData(cl.getElementId("scroll-probe")).bounding_box.y;
    try std.testing.expectApproxEqAbs(h.y0 - 60, ym, 0.5);
    dispatch.pointerEvent(&s, h.cx, h.cy, true, 272, 720, 480);
    dispatch.pointerEvent(&s, h.cx, h.cy - 30, false, 0, 720, 480);
    try std.testing.expect(s.dragging);
    dragScroll(h.cx, h.cy - 30, 0, -30);
    dragFrame();
    const y1 = cl.getElementData(cl.getElementId("scroll-probe")).bounding_box.y;
    try std.testing.expectApproxEqAbs(ym + 30, y1, 0.5);
}

test "drag clamps at the content end" {
    var s = dispatch.PtrState{};
    const h = try dragSetup(&s);
    dispatch.pointerEvent(&s, h.cx, h.cy, true, 272, 720, 480);
    dispatch.pointerEvent(&s, h.cx, h.cy + 40, false, 0, 720, 480);
    // Content is 400px in a 100px viewport: max scroll is 300.
    dragScroll(h.cx, h.cy + 40, 0, 5000);
    dragFrame();
    const y1 = cl.getElementData(cl.getElementId("scroll-probe")).bounding_box.y;
    try std.testing.expectApproxEqAbs(h.y0 - 300, y1, 0.5);
}

test "drag outside any container scrolls nothing" {
    var s = dispatch.PtrState{};
    const h = try dragSetup(&s);
    dispatch.pointerEvent(&s, 500, 400, true, 272, 720, 480);
    dispatch.pointerEvent(&s, 500, 450, false, 0, 720, 480);
    dragScroll(500, 450, 0, 50);
    dragFrame();
    const y1 = cl.getElementData(cl.getElementId("scroll-probe")).bounding_box.y;
    try std.testing.expectApproxEqAbs(h.y0, y1, 0.5);
}
