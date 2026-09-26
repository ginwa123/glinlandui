// Agnostic reusable Clay image widget (toolkit-style, library only).
// Declares a fixed-size Clay IMAGE element whose image_data points at a
// per-frame static ImageRef slot (path + fit + max_dim, synchronous
// lifetime like all declare props). The GLES3 renderer decodes (stb),
// caches, and draws it, falling back to a placeholder rect while
// loading. Headless tests observe the IMAGE command (no GL).
// Imports: std + zclay + core/render_common + click_registry ONLY.
// Never: app/theme/layout/views/content/sidebar.
const std = @import("std");
const cl = @import("zclay");
const render = @import("../render_common.zig");
const registry = @import("click_registry.zig");

/// Image fit re-export (renderer owns the enum + math).
pub const Fit = render.ImageFit;

/// Click callback: plain fn pointer + opaque ctx (no closures), same
/// shape as button.ClickFn. Stored + self-registered like button().
pub const ClickFn = ?*const fn (?*anyopaque) void;

/// Toolkit-style image props. All styling via props with neutral
/// defaults — no theme/app imports. `id` becomes the Clay element ID
/// (stable across frames for hit-testing). `path` is read
/// synchronously during declare (the renderer hashes + decodes during
/// the same frame's drawCommands) — the slice must outlive the frame,
/// which AppState-owned file paths do.
/// `w`/`h` fix the box in px (this Clay version has no
/// source-dimensions, so images never auto-size). `max_dim` caps the
/// decode (thumbnails small, preview larger). `radius` rounds the box
/// corners (passed through to the IMAGE command). `on_click`/`ctx`
/// self-register a click target like button() (null = display-only).
pub const ImageProps = struct {
    id: []const u8,
    path: []const u8,
    w: u32,
    h: u32,
    fit: Fit = .cover,
    max_dim: u16 = 256,
    radius: u32 = 0,
    on_click: ClickFn = null,
    ctx: ?*anyopaque = null,
};

/// Per-frame ImageRef slots (synchronous-declare lifetime, mirroring
/// the builders' scratch buffers). Reset by beginFrame() every frame
/// from the host declare thunk (next to registry.beginFrame()).
/// 64 slots cover full unpaged galleries (registry cap scales with it).
pub const slot_cap: usize = 64;
var ref_slots: [slot_cap]render.ImageRef = undefined;
var slot_next: usize = 0;

/// Reset the slot cursor for a new frame. Called by the host declare
/// thunk; tests call it directly before declaring.
pub fn beginFrame() void {
    slot_next = 0;
}

const empty_path: [1]u8 = .{0};

/// Declare an image element. Declare-only leaf besides the optional
/// click registration (same contract as button()).
pub fn image(props: ImageProps) void {
    // Cap guard: with more images than slots in one frame, the last
    // slot is reused (same image drawn twice beats an OOB write).
    const idx = if (slot_next < slot_cap) slot_next else slot_cap - 1;
    slot_next += 1;
    const slot = &ref_slots[idx];
    slot.* = .{
        .path_ptr = if (props.path.len > 0) props.path.ptr else &empty_path,
        .path_len = props.path.len,
        .fit = props.fit,
        .max_dim = props.max_dim,
    };
    cl.UI()(.{
        .id = .ID(props.id),
        .layout = .{
            .sizing = .{
                .w = .fixed(@floatFromInt(props.w)),
                .h = .fixed(@floatFromInt(props.h)),
            },
        },
        .corner_radius = .all(@floatFromInt(props.radius)),
        .image = .{ .image_data = slot },
    })({});
    if (props.on_click) |cb| {
        // Pointer cursor: clickable image. Display-only images (null
        // on_click) register nothing so hover stays .default.
        registry.registerClickCursor(cl.getElementId(props.id), cb, props.ctx, .pointer);
    }
}

// Stub text estimator for headless tests (no font backend needed).
fn stubMeasure(s: []const u8, cfg: *cl.TextElementConfig, _: void) cl.Dimensions {
    return .{
        .w = @as(f32, @floatFromInt(s.len)) * @as(f32, @floatFromInt(cfg.font_size)) * 0.6,
        .h = @as(f32, @floatFromInt(cfg.font_size)),
    };
}

fn declareImage() void {
    beginFrame();
    image(.{ .id = "test-image", .path = "/p/a.jpg", .w = 150, .h = 84 });
}

fn countImageCommands(declare_fn: *const fn () void, images: *usize, rects: *usize) !void {
    const mem_size = cl.minMemorySize();
    // NOTE: intentionally leaked (page_allocator, never freed). Clay keeps
    // a global currentContext pointer inside this arena, so freeing it
    // would dangle the *next* test's minMemorySize/initialize (segfault).
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declare_fn();
    const cmds = cl.endLayout();
    var im: usize = 0;
    var r: usize = 0;
    for (cmds) |c| switch (c.command_type) {
        .image => im += 1,
        .rectangle => r += 1,
        else => {},
    };
    images.* = im;
    rects.* = r;
}

test "image emits exactly one image command, no rectangles" {
    var images: usize = 0;
    var rects: usize = 0;
    try countImageCommands(declareImage, &images, &rects);
    try std.testing.expectEqual(@as(usize, 1), images);
    try std.testing.expectEqual(@as(usize, 0), rects);
}

test "ImageProps carries neutral defaults" {
    const p = ImageProps{ .id = "x", .path = "/p/a.jpg", .w = 150, .h = 84 };
    try std.testing.expectEqual(render.ImageFit.cover, p.fit);
    try std.testing.expectEqual(@as(u16, 256), p.max_dim);
    try std.testing.expectEqual(@as(u32, 0), p.radius);
    try std.testing.expect(p.on_click == null);
    try std.testing.expect(p.ctx == null);
}

test "image_data round-trips path, fit, and max_dim" {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    beginFrame();
    cl.beginLayout();
    image(.{ .id = "test-image-ref", .path = "/p/b.png", .w = 150, .h = 84, .fit = .contain, .max_dim = 512 });
    const cmds = cl.endLayout();
    var found = false;
    for (cmds) |c| {
        if (c.command_type != .image) continue;
        const ptr = c.render_data.image.image_data orelse continue;
        const ref: *const render.ImageRef = @ptrCast(@alignCast(ptr));
        try std.testing.expectEqualStrings("/p/b.png", ref.path_ptr[0..ref.path_len]);
        try std.testing.expectEqual(render.ImageFit.contain, ref.fit);
        try std.testing.expectEqual(@as(u16, 512), ref.max_dim);
        found = true;
    }
    try std.testing.expect(found);
}

test "image honors fixed w/h geometry" {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    beginFrame();
    cl.beginLayout();
    image(.{ .id = "test-image-geo", .path = "/p/a.jpg", .w = 150, .h = 84 });
    _ = cl.endLayout();
    const bb = cl.getElementData(cl.getElementId("test-image-geo")).bounding_box;
    try std.testing.expectEqual(@as(f32, 150), bb.width);
    try std.testing.expectEqual(@as(f32, 84), bb.height);
}

const ClickCtx = struct {
    calls: usize = 0,
};

fn testOnClick(ctx: ?*anyopaque) void {
    const c: *ClickCtx = @ptrCast(@alignCast(ctx.?));
    c.calls += 1;
}

var click_rec = ClickCtx{};

fn declareClickImage() void {
    beginFrame();
    image(.{ .id = "test-click-image", .path = "/p/a.jpg", .w = 150, .h = 84, .on_click = testOnClick, .ctx = &click_rec });
}

fn declareNoClickImage() void {
    beginFrame();
    image(.{ .id = "test-noclick-image", .path = "/p/a.jpg", .w = 150, .h = 84 });
}

test "image self-registers on_click; dispatchClick at center fires once" {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    click_rec = .{};
    registry.beginFrame();
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declareClickImage();
    _ = cl.endLayout();
    const bb = cl.getElementData(cl.getElementId("test-click-image")).bounding_box;
    try std.testing.expect(registry.dispatchClick(bb.x + bb.width * 0.5, bb.y + bb.height * 0.5));
    try std.testing.expectEqual(@as(usize, 1), click_rec.calls);
    try std.testing.expect(!registry.dispatchClick(700, 460));
    try std.testing.expectEqual(@as(usize, 1), click_rec.calls);
}

test "image without on_click registers nothing; dispatchClick returns false" {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    registry.beginFrame();
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declareNoClickImage();
    _ = cl.endLayout();
    const bb = cl.getElementData(cl.getElementId("test-noclick-image")).bounding_box;
    try std.testing.expect(!registry.dispatchClick(bb.x + bb.width * 0.5, bb.y + bb.height * 0.5));
}
