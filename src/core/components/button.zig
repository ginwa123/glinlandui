// Agnostic reusable Clay button (toolkit-style, library only).
// Imports: std + zclay + core/color + core/render_common + sibling components ONLY.
// Never: app/theme/layout/views/content/sidebar.
const std = @import("std");
const cl = @import("zclay");
const Color = @import("../color.zig").Color;
const registry = @import("click_registry.zig");
const semantics = @import("../semantics.zig");

/// Click callback: plain fn pointer + opaque ctx (no closures).
/// Stored in ButtonProps (declare-only button never fires it); the owner
/// (views/host) reads the built props back and fires
/// `props.on_click(props.ctx)` on pointer dispatch (e.g. close box).
pub const ClickFn = ?*const fn (?*anyopaque) void;

/// Toolkit-style button props. All styling via props with neutral dark
/// defaults — no theme/app imports. `id` becomes the Clay element ID
/// (stable across frames for hover/selection queries).
/// `w`/`h`, when set, fix that axis to an exact pixel size (null keeps
/// the label-fitting behavior); `pad_tb`/`pad_lr` are the top-bottom /
/// left-right padding preserved from the original axes(8, 16).
/// `min_w`/`min_h`/`max_w`/`max_h` clamp the fit axes (null = no
/// constraint; forwarded to Clay fitMinMax). Fixed `w`/`h` ignore min/max.
/// `radius` rounds the rect (a.k.a. `rounded`). `border_width` (uniform,
/// 0 = none) + `border_color` emit a Clay BORDER command.
/// `disabled` dims to `disabled_bg`/`disabled_fg`, suppresses hover chrome
/// and skips click registration (declare never fires; owner dispatch via
/// stored props must also check `disabled`).
/// `on_click`/`ctx` are stored verbatim for owner-side dispatch; the
/// button declaration itself is unchanged (hover chrome only).
pub const ButtonProps = struct {
    id: []const u8,
    label: []const u8,
    font_size: u16 = 14,
    bg: Color = Color.rgb(0x1e, 0x1e, 0x1e),
    fg: Color = Color.rgb(0xe8, 0xe8, 0xe8),
    hover_bg: Color = Color.rgb(0x2d, 0x2d, 0x2d),
    radius: u32 = 8,
    w: ?u32 = null,
    h: ?u32 = null,
    min_w: ?u32 = null,
    min_h: ?u32 = null,
    max_w: ?u32 = null,
    max_h: ?u32 = null,
    border_width: u16 = 0,
    border_color: Color = Color.rgb(0x00, 0x00, 0x00),
    disabled: bool = false,
    disabled_bg: Color = Color.rgb(0x1a, 0x1a, 0x1a),
    disabled_fg: Color = Color.rgb(0x77, 0x77, 0x77),
    pad_tb: u16 = 8,
    pad_lr: u16 = 16,
    on_click: ClickFn = null,
    ctx: ?*anyopaque = null,
};

fn sizingAxisFixedOrFit(fixed: ?u32, min: ?u32, max: ?u32) cl.SizingAxis {
    if (fixed) |v| return .fixed(@floatFromInt(v));
    const has_minmax = min != null or max != null;
    if (!has_minmax) return .fit;
    return .fitMinMax(.{
        .min = if (min) |v| @floatFromInt(v) else 0,
        .max = if (max) |v| @floatFromInt(v) else 0,
    });
}

/// Declare a button: rounded rect sized to its label + centered text.
/// Hover: uses `cl.hovered()` (Clay_Hovered — true when the pointer is
/// over the currently open element) to switch the rect bg to `hover_bg`.
/// Callers must feed pointer state via `cl.setPointerState()` each frame
/// (same as Shell.frame); without it the button renders the resting `bg`.
/// Selection/click handling stays caller-side (like the current hitTest
/// pattern): after layout, query
/// `cl.pointerOver(cl.getElementId(props.id))`.
pub fn button(props: ButtonProps) void {
    // NOTE: cl.hovered() must be evaluated INSIDE the UI() config literal
    // (after Clay__OpenElement runs, while this element is open) so it
    // queries this button — calling it here beforehand would query the
    // parent/root instead and hover_bg would never (or spuriously) trigger.
    // Disabled buttons never take hover chrome and never register clicks.
    // NOTE: cl.hovered() stays INSIDE the UI() literal below (while this
    // element is open) — hoisting it here would query the parent/root.
    const fg: Color = if (props.disabled) props.disabled_fg else props.fg;
    cl.UI()(.{
        .id = .ID(props.id),
        .layout = .{
            .sizing = .{
                .w = sizingAxisFixedOrFit(props.w, props.min_w, props.max_w),
                .h = sizingAxisFixedOrFit(props.h, props.min_h, props.max_h),
            },
            .padding = .axes(props.pad_tb, props.pad_lr),
            .child_alignment = .center,
        },
        .background_color = (if (props.disabled) props.disabled_bg else if (cl.hovered()) props.hover_bg else props.bg).toClay(),
        .corner_radius = .all(@floatFromInt(props.radius)),
        .border = if (props.border_width > 0) .{
            .color = props.border_color.toClay(),
            .width = .outside(props.border_width),
        } else .{},
    })({
        cl.text(props.label, .{
            .font_size = props.font_size,
            .color = fg.toClay(),
        });
    });
    // Semantics: registered for EVERY button, not only the ones with a click
    // callback. The calculator example passes `on_click = null` and registers
    // its 20 keys externally with `registerZCursor`, so keying off `on_click`
    // would make every keypad key invisible to `onNodeWithText("7")`.
    //
    // `actions.click` is deliberately NOT set here: `semantics.resolve` folds
    // it in from click_registry, the one authoritative record of what dispatch
    // will actually fire. That is what lets an externally-registered button
    // report `hasClickAction` correctly.
    semantics.register(.{
        .id = cl.getElementId(props.id),
        .tag = props.id,
        .role = .button,
        .label = props.label,
        .flags = .{ .enabled = !props.disabled },
    });
    if (!props.disabled) {
        if (props.on_click) |cb| {
            // Pointer cursor: clickable button. Disabled skips
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

fn declareButton() void {
    button(.{ .id = "test-button", .label = "OK" });
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

test "button emits rectangle + text render commands" {
    var rects: usize = 0;
    var texts: usize = 0;
    try countCommands(declareButton, &rects, &texts);
    try std.testing.expect(rects >= 1);
    try std.testing.expectEqual(@as(usize, 1), texts);
}

test "ButtonProps carries neutral dark defaults" {
    const p = ButtonProps{ .id = "x", .label = "y" };
    try std.testing.expectEqual(@as(u16, 14), p.font_size);
    try std.testing.expectEqual(Color.rgb(0x1e, 0x1e, 0x1e), p.bg);
    try std.testing.expectEqual(Color.rgb(0xe8, 0xe8, 0xe8), p.fg);
    try std.testing.expectEqual(Color.rgb(0x2d, 0x2d, 0x2d), p.hover_bg);
    try std.testing.expectEqual(@as(u32, 8), p.radius);
    try std.testing.expect(p.w == null);
    try std.testing.expect(p.h == null);
    try std.testing.expect(p.min_w == null);
    try std.testing.expect(p.min_h == null);
    try std.testing.expect(p.max_w == null);
    try std.testing.expect(p.max_h == null);
    try std.testing.expectEqual(@as(u16, 0), p.border_width);
    try std.testing.expectEqual(Color.rgb(0x00, 0x00, 0x00), p.border_color);
    try std.testing.expect(!p.disabled);
    try std.testing.expectEqual(Color.rgb(0x1a, 0x1a, 0x1a), p.disabled_bg);
    try std.testing.expectEqual(Color.rgb(0x77, 0x77, 0x77), p.disabled_fg);
    try std.testing.expectEqual(@as(u16, 8), p.pad_tb);
    try std.testing.expectEqual(@as(u16, 16), p.pad_lr);
    try std.testing.expect(p.on_click == null);
    try std.testing.expect(p.ctx == null);
}

const ClickCtx = struct {
    calls: usize = 0,
};

fn testOnClick(ctx: ?*anyopaque) void {
    const c: *ClickCtx = @ptrCast(@alignCast(ctx.?));
    c.calls += 1;
}

test "ButtonProps stores on_click/ctx; direct invocation fires" {
    var c = ClickCtx{};
    const p = ButtonProps{ .id = "x", .label = "y", .on_click = testOnClick, .ctx = &c };
    try std.testing.expect(p.on_click != null);
    try std.testing.expect(p.ctx != null);
    p.on_click.?(p.ctx);
    try std.testing.expectEqual(@as(usize, 1), c.calls);
}

fn rectColorForId(cmds: []cl.RenderCommand, id: u32) ?cl.Color {
    for (cmds) |c| {
        if (c.command_type == .rectangle and c.id == id) return c.render_data.rectangle.background_color;
    }
    return null;
}

test "button hover switches bg to hover_bg when pointer is over" {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);

    const props = ButtonProps{ .id = "test-button-hover", .label = "OK" };
    const rest_c = props.bg.toClay();
    const hover_c = props.hover_bg.toClay();
    const eid = cl.getElementId(props.id);

    // Frame 1: pointer parked offscreen — resting bg, not hovered.
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    button(props);
    const cmds1 = cl.endLayout();
    try std.testing.expect(!cl.pointerOver(cl.getElementId(props.id)));
    const bg1 = rectColorForId(cmds1, eid.id);
    try std.testing.expect(bg1 != null);
    try std.testing.expectEqual(rest_c, bg1.?);

    // Frame 2: pointer over the button center (frame-1 box) — hover bg.
    // setPointerState hit-tests against frame-1 boxes, so pointerOverIds
    // is populated before beginLayout; hovered() inside the UI() literal
    // then observes the open button element.
    const box = cl.getElementData(cl.getElementId(props.id)).bounding_box;
    cl.setPointerState(.{ .x = box.x + box.width * 0.5, .y = box.y + box.height * 0.5 }, false);
    cl.beginLayout();
    button(props);
    const cmds2 = cl.endLayout();
    try std.testing.expect(cl.pointerOver(cl.getElementId(props.id)));
    const bg2 = rectColorForId(cmds2, eid.id);
    try std.testing.expect(bg2 != null);
    try std.testing.expectEqual(hover_c, bg2.?);

    // Frame 3: pointer inside the window but OFF the button — resting bg.
    // (Catches the ordering bug from the other side: hovered() evaluated
    // before UI() queries the parent/root, whose box contains the point,
    // so buggy code paints hover_bg even though the button isn't hovered.)
    try std.testing.expect(box.x + box.width < 700 or box.y + box.height < 460);
    cl.setPointerState(.{ .x = 700, .y = 460 }, false);
    cl.beginLayout();
    button(props);
    const cmds3 = cl.endLayout();
    try std.testing.expect(!cl.pointerOver(cl.getElementId(props.id)));
    const bg3 = rectColorForId(cmds3, eid.id);
    try std.testing.expect(bg3 != null);
    try std.testing.expectEqual(rest_c, bg3.?);
}

// ---- Agnostic extensions for app wiring (close-box parity) ----

fn declareFixedButton() void {
    button(.{
        .id = "test-fixed-button",
        .label = "X",
        .font_size = 12,
        .w = 16,
        .h = 16,
        .pad_tb = 0,
        .pad_lr = 0,
    });
}

test "button fixed size honors w/h props with zero padding" {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declareFixedButton();
    _ = cl.endLayout();
    const box = cl.getElementData(cl.getElementId("test-fixed-button")).bounding_box;
    try std.testing.expectEqual(@as(f32, 16), box.width);
    try std.testing.expectEqual(@as(f32, 16), box.height);
}

fn declarePaddedButton() void {
    button(.{ .id = "test-padded-button", .label = "OK" });
}

fn declareUnpaddedButton() void {
    button(.{ .id = "test-unpadded-button", .label = "OK", .pad_tb = 0, .pad_lr = 0 });
}

fn fitWidth(declare_fn: *const fn () void, id: []const u8) !f32 {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declare_fn();
    _ = cl.endLayout();
    return cl.getElementData(cl.getElementId(id)).bounding_box.width;
}

test "button padding props grow the fit box" {
    // "OK" at 14px: stub text w = 2*14*0.6 = 16.8. Default padding
    // axes(tb 8, lr 16) adds 32 horizontally; zero padding adds none.
    const wide = try fitWidth(declarePaddedButton, "test-padded-button");
    const narrow = try fitWidth(declareUnpaddedButton, "test-unpadded-button");
    try std.testing.expectEqual(@as(f32, 32), wide - narrow);
}

fn declareClickButton() void {
    button(.{ .id = "test-click-button", .label = "OK", .on_click = testOnClick, .ctx = &click_rec });
}

var click_rec = ClickCtx{};

fn declareNoClickButton() void {
    button(.{ .id = "test-noclick-button", .label = "OK" });
}

test "button without on_click registers nothing; dispatchClick returns false" {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    registry.beginFrame();
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declareNoClickButton();
    _ = cl.endLayout();
    const bb = cl.getElementData(cl.getElementId("test-noclick-button")).bounding_box;
    try std.testing.expect(!registry.dispatchClick(bb.x + bb.width * 0.5, bb.y + bb.height * 0.5));
}

test "button self-registers on_click; dispatchClick at center fires once" {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    click_rec = .{};
    registry.beginFrame();
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declareClickButton();
    _ = cl.endLayout();
    const bb = cl.getElementData(cl.getElementId("test-click-button")).bounding_box;
    try std.testing.expect(registry.dispatchClick(bb.x + bb.width * 0.5, bb.y + bb.height * 0.5));
    try std.testing.expectEqual(@as(usize, 1), click_rec.calls);
    try std.testing.expect(!registry.dispatchClick(700, 460));
    try std.testing.expectEqual(@as(usize, 1), click_rec.calls);
}

fn declareDisabledButton() void {
    button(.{ .id = "test-disabled-button", .label = "OK", .disabled = true, .on_click = testOnClick, .ctx = &click_rec });
}

test "disabled button uses disabled_bg and registers no click" {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    click_rec = .{};
    registry.beginFrame();
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declareDisabledButton();
    const cmds = cl.endLayout();
    const eid = cl.getElementId("test-disabled-button");
    const bg = rectColorForId(cmds, eid.id);
    try std.testing.expect(bg != null);
    try std.testing.expectEqual(Color.rgb(0x1a, 0x1a, 0x1a).toClay(), bg.?);
    const bb = cl.getElementData(eid).bounding_box;
    try std.testing.expect(!registry.dispatchClick(bb.x + bb.width * 0.5, bb.y + bb.height * 0.5));
    try std.testing.expectEqual(@as(usize, 0), click_rec.calls);
}

fn declareMinButton() void {
    button(.{ .id = "test-min-button", .label = "OK", .min_w = 200 });
}

test "button min_w clamps the fit width" {
    const w = try fitWidth(declareMinButton, "test-min-button");
    try std.testing.expect(w >= 199.5);
}
