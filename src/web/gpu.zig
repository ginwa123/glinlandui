//! Browser GPU renderer — the geometry half: the vertex and segment buffers a page uploads, and the glyph atlas it samples.
const std = @import("std");
const builtin = @import("builtin");
const cl = @import("zclay");
const soft = @import("../core/render_software.zig");
const glyphs = @import("../core/glyphs.zig");
const text_face = @import("../core/text_face.zig");
const scale_mod = @import("../core/scale.zig");
const common = @import("../core/render_common.zig");
const image_store = @import("../core/image_store.zig");

/// One vertex, 17 tightly packed floats (68 bytes): the same layout src/linux/vk.h and src/mac/metal.h declare.
pub const Vertex = extern struct {
    pos: [2]f32,
    local: [2]f32,
    size: [2]f32,
    radius: [4]f32,
    color: [4]f32,
    mode: f32,
    border: f32,
    kind: f32,
};

/// A run of vertices sharing one scissor and one texture, 36 bytes: kind 0 = rect, 1 = text (the atlas), 2 = image.
pub const Segment = extern struct {
    start: i32,
    count: i32,
    has_scissor: i32,
    sx: i32,
    sy: i32,
    sw: i32,
    sh: i32,
    texture_id: u32,
    kind: i32,
};

/// Which GPU API the page created. 0 is not a failure: it is the CPU rasterizer, which is what a browser without either API gets.
pub const Kind = enum(u32) { none = 0, webgpu = 1, webgl2 = 2 };

/// The glyph atlas dimensions. 1024 is a multiple of 256, which is what WebGPU's `writeTexture` needs for `bytesPerRow`.
pub const atlas_w: u32 = 1024;
pub const atlas_h: u32 = 1024;

const GlyphKey = struct { cp: u21, size: u16 };
const Slot = struct { x: u32, y: u32, w: u32, h: u32, xoff: f32, yoff: f32 };

// A wasm module allocates from its own linear memory; the other arm exists so this file type-checks in the parity suite on Linux and macOS.
fn gpa() std.mem.Allocator {
    if (comptime builtin.cpu.arch.isWasm()) return std.heap.wasm_allocator;
    return std.heap.page_allocator;
}

var kind: u32 = 0;
var verts: std.ArrayList(Vertex) = .empty;
var segs: std.ArrayList(Segment) = .empty;
var atlas: []u8 = &.{};
var atlas_version: u32 = 0;
var atlas_dirty: bool = false;
var slots: std.AutoHashMapUnmanaged(GlyphKey, Slot) = .empty;
var shelf_x: u32 = 0;
var shelf_y: u32 = 0;
var shelf_h: u32 = 0;
var frame_w: u32 = 0;
var frame_h: u32 = 0;
var clear: [4]f32 = .{ 0, 0, 0, 1 };
var seg_start: usize = 0;
var seg_open_scissor: ?[4]i32 = null;
var scissor_stack: [soft.max_clip_depth]?[4]i32 = @splat(null);
var scissor_depth: usize = 0;
var seg_kind: i32 = 0;
var seg_texture: u32 = 0;
var images: std.ArrayList(ImageTexture) = .empty;
var next_image_id: u32 = 1;

/// One decoded image, as the page needs it: an id to bind, a size, the RGBA8 bytes and a version that changes when a wrapped id is reused.
pub const ImageTexture = struct {
    id: u32,
    key: u64,
    width: u32,
    height: u32,
    version: u32,
    pixels: []const u8,
};

/// How many image textures the frame's segments can name.
pub const max_images: u32 = 255;

pub fn imageCount() u32 {
    return @intCast(images.items.len);
}

pub fn imageAt(index: u32) ?ImageTexture {
    if (index >= images.items.len) return null;
    return images.items[index];
}

/// Which backend the page says it created; 0 while the page has not asked, so a module with no page stays on the CPU path.
pub fn backendKind() u32 {
    return kind;
}

/// The page's answer. Anything above 2 is treated as 0 rather than trusted, so a page cannot switch the renderer to a pipeline that does not exist.
pub fn setBackendKind(k: u32) void {
    kind = if (k <= 2) k else 0;
    verts.clearRetainingCapacity();
    segs.clearRetainingCapacity();
}

/// True when the last frame was built for a GPU, so the window must not offer a stale CPU surface for the page to blit.
pub fn active() bool {
    return kind != 0;
}

/// The frame size in DEVICE pixels, from the logical size the frame path passed and the display scale.
pub fn width() u32 {
    return frame_w;
}

pub fn height() u32 {
    return frame_h;
}

/// The frame's clear colour, normalized to 0..1 for a shader.
pub fn clearColor() [4]f32 {
    return clear;
}

/// Bytes per vertex and per segment, so the page never hardcodes what this file declares.
pub fn vertexStride() u32 {
    return @sizeOf(Vertex);
}

pub fn segmentStride() u32 {
    return @sizeOf(Segment);
}

pub fn vertices() []const u8 {
    return std.mem.sliceAsBytes(verts.items);
}

pub fn segments() []const u8 {
    return std.mem.sliceAsBytes(segs.items);
}

pub fn segmentCount() u32 {
    return @intCast(segs.items.len);
}

/// The glyph atlas as 8-bit coverage, and the version the page compares to decide whether to re-upload it.
pub fn atlasBytes() []const u8 {
    return atlas;
}

pub fn atlasVersion() u32 {
    return atlas_version;
}

pub fn deinit() void {
    verts.deinit(gpa());
    verts = .empty;
    segs.deinit(gpa());
    segs = .empty;
    slots.deinit(gpa());
    slots = .empty;
    if (atlas.len > 0) gpa().free(atlas);
    atlas = &.{};
    for (images.items) |img| gpa().free(img.pixels);
    images.deinit(gpa());
    images = .empty;
    next_image_id = 1;
    atlas_version = 0;
    atlas_dirty = false;
}

/// Build one frame's geometry. Every decision — culling, clipping, the baseline, the atlas slot — is here, exactly as it is in `src/mac/renderer.zig`.
pub fn build(commands: []const cl.RenderCommand, win_w: i32, win_h: i32) void {
    if (win_w <= 0 or win_h <= 0) return;
    const px = scale_mod.pixelSize(@intCast(win_w), @intCast(win_h), soft.renderScale());
    frame_w = px.w;
    frame_h = px.h;
    clear = soft.currentClearColor();

    verts.clearRetainingCapacity();
    segs.clearRetainingCapacity();
    seg_start = 0;
    seg_open_scissor = null;
    scissor_depth = 0;
    seg_kind = 0;
    seg_texture = 0;

    const k = soft.renderScale();
    for (commands) |*cmd| {
        const bb = cmd.bounding_box;
        switch (cmd.command_type) {
            .rectangle => {
                const r = cmd.render_data.rectangle;
                if (r.background_color[3] <= 0) continue;
                const cr = soft.cornerRadiusVec4(r.corner_radius);
                pushRect(bb.x * k, bb.y * k, bb.width * k, bb.height * k, .{
                    cr[0] * k,
                    cr[1] * k,
                    cr[2] * k,
                    cr[3] * k,
                }, 0, 0, r.background_color);
            },
            .border => pushBorder(cmd.render_data.border, bb, k),
            .text => {
                const td = cmd.render_data.text;
                const bytes = td.string_contents.chars[0..@intCast(td.string_contents.length)];
                pushText(bb.x * k, bb.y * k, bb.height * k, bytes, @intFromFloat(@round(@as(f32, @floatFromInt(td.font_size)) * k)), td.text_color);
            },
            .scissor_start => pushScissor(bb.x * k, bb.y * k, bb.width * k, bb.height * k),
            .scissor_end => popScissor(),
            .image => {
                const im = cmd.render_data.image;
                if (im.image_data) |ptr| {
                    const ref: *const common.ImageRef = @ptrCast(@alignCast(ptr));
                    pushImage(bb.x * k, bb.y * k, bb.width * k, bb.height * k, ref);
                }
            },
            else => {},
        }
    }
    closeSegment();

    if (atlas_dirty and atlas.len > 0) {
        atlas_version +%= 1;
        atlas_dirty = false;
    }
}

// ---- segments ----

fn setRun(k: i32, tex: u32) void {
    if (seg_kind == k and seg_texture == tex) return;
    closeSegment();
    seg_kind = k;
    seg_texture = tex;
}

fn closeSegment() void {
    const end = verts.items.len;
    if (end > seg_start) {
        const sc = seg_open_scissor;
        if (sc) |v| {
            if (v[2] <= 0 or v[3] <= 0) {
                seg_start = end;
                return;
            }
        }
        segs.append(gpa(), .{
            .start = @intCast(seg_start),
            .count = @intCast(end - seg_start),
            .has_scissor = if (sc != null) 1 else 0,
            .sx = if (sc) |v| v[0] else 0,
            .sy = if (sc) |v| v[1] else 0,
            .sw = if (sc) |v| v[2] else 0,
            .sh = if (sc) |v| v[3] else 0,
            .texture_id = seg_texture,
            .kind = seg_kind,
        }) catch {};
    }
    seg_start = end;
}

// A clip INTERSECTS the one in force, so an inner clip never widens the scroll box around it.
fn pushScissor(x: f32, y: f32, w: f32, h: f32) void {
    closeSegment();
    const next: [4]i32 = .{
        @intFromFloat(@max(x, 0)),
        @intFromFloat(@max(y, 0)),
        @intFromFloat(@max(w, 0)),
        @intFromFloat(@max(h, 0)),
    };
    if (scissor_depth < scissor_stack.len) {
        scissor_stack[scissor_depth] = seg_open_scissor;
        scissor_depth += 1;
    }
    seg_open_scissor = intersectScissor(seg_open_scissor, next);
}

fn popScissor() void {
    closeSegment();
    if (scissor_depth == 0) {
        seg_open_scissor = null;
        return;
    }
    scissor_depth -= 1;
    seg_open_scissor = scissor_stack[scissor_depth];
}

// The overlap of two clips, or a zero-size rect when they do not touch: a scissor of nothing clips everything.
fn intersectScissor(cur: ?[4]i32, next: [4]i32) [4]i32 {
    const prev = cur orelse return next;
    const x0 = @max(prev[0], next[0]);
    const y0 = @max(prev[1], next[1]);
    const x1 = @min(prev[0] + prev[2], next[0] + next[2]);
    const y1 = @min(prev[1] + prev[3], next[1] + next[3]);
    return .{ x0, y0, @max(x1 - x0, 0), @max(y1 - y0, 0) };
}

// ---- geometry ----

fn pushQuadLocal(x: f32, y: f32, w: f32, h: f32, v: Vertex) void {
    var a = v;
    var b = v;
    var c = v;
    var d = v;
    a.pos = .{ x, y };
    a.local = .{ 0, 0 };
    b.pos = .{ x + w, y };
    b.local = .{ w, 0 };
    c.pos = .{ x + w, y + h };
    c.local = .{ w, h };
    d.pos = .{ x, y + h };
    d.local = .{ 0, h };
    verts.appendSlice(gpa(), &.{ a, b, c, a, c, d }) catch {};
}

fn pushRect(x: f32, y: f32, w: f32, h: f32, radius: [4]f32, mode: f32, border: f32, color: [4]f32) void {
    if (w <= 0 or h <= 0) return;
    setRun(0, 0);
    const v = Vertex{
        .pos = .{ 0, 0 },
        .local = .{ 0, 0 },
        .size = .{ w, h },
        .radius = radius,
        .color = soft.normalizeColorPublic(color),
        .mode = mode,
        .border = border,
        .kind = 0,
    };
    pushQuadLocal(x, y, w, h, v);
}

// A border is four sides in Clay's model; the shader takes one width, so unequal sides become four rects.
fn pushBorder(bd: cl.BorderRenderData, bb: cl.BoundingBox, k: f32) void {
    const top: f32 = @floatFromInt(bd.width.top);
    const bottom: f32 = @floatFromInt(bd.width.bottom);
    const left: f32 = @floatFromInt(bd.width.left);
    const right: f32 = @floatFromInt(bd.width.right);
    if (top == bottom and top == left and top == right) {
        if (top <= 0) return;
        pushRect(bb.x * k, bb.y * k, bb.width * k, bb.height * k, .{ 0, 0, 0, 0 }, 1, top * k, bd.color);
        return;
    }
    if (top > 0 and bb.width > 0) pushRect(bb.x * k, bb.y * k, bb.width * k, @min(top, bb.height) * k, .{ 0, 0, 0, 0 }, 0, 0, bd.color);
    if (bottom > 0 and bb.width > 0) {
        const bh = @min(bottom, bb.height);
        pushRect(bb.x * k, (bb.y + bb.height - bh) * k, bb.width * k, bh * k, .{ 0, 0, 0, 0 }, 0, 0, bd.color);
    }
    const inner_h = bb.height - @min(top, bb.height) - @min(bottom, bb.height);
    if (inner_h > 0) {
        if (left > 0) pushRect(bb.x * k, (bb.y + @min(top, bb.height)) * k, @min(left, bb.width) * k, inner_h * k, .{ 0, 0, 0, 0 }, 0, 0, bd.color);
        if (right > 0) {
            const rw = @min(right, bb.width);
            pushRect((bb.x + bb.width - rw) * k, (bb.y + @min(top, bb.height)) * k, rw * k, inner_h * k, .{ 0, 0, 0, 0 }, 0, 0, bd.color);
        }
    }
}

fn pushText(bbox_x: f32, bbox_y: f32, bbox_h: f32, bytes: []const u8, fs: u16, color: [4]f32) void {
    if (bytes.len == 0) return;
    const face = text_face.font() orelse return;
    const size: u16 = if (fs == 0) 16 else fs;
    const m = glyphs.measure(face, bytes, size);
    if (m.width <= 0) return;
    const n = soft.normalizeColorPublic(color);
    // Same rule as the CPU path and every other backend: the CAP BOX is centred in the box, not the font's line box.
    const baseline = if (glyphs.capBox(face, size)) |cap|
        bbox_y + (if (bbox_h > 0) (bbox_h - cap.height) * 0.5 else 0) - cap.top
    else
        bbox_y + (if (bbox_h > 0) bbox_h - face.lineHeight(size) else 0) * 0.5 + m.ascent;

    setRun(1, 0);
    var pen = bbox_x;
    var i: usize = 0;
    while (i < bytes.len) {
        const cp = glyphs.nextCodepoint(bytes, &i);
        const gm = face.glyphMetrics(cp, size);
        if (glyphSlot(face, cp, size)) |slot| {
            const gx = @floor(pen + slot.xoff);
            const gy = @floor(baseline + slot.yoff);
            const gw: f32 = @floatFromInt(slot.w);
            const gh: f32 = @floatFromInt(slot.h);
            if (gw > 0 and gh > 0) {
                const tu0 = @as(f32, @floatFromInt(slot.x)) / @as(f32, @floatFromInt(atlas_w));
                const tv0 = @as(f32, @floatFromInt(slot.y)) / @as(f32, @floatFromInt(atlas_h));
                const tu1 = @as(f32, @floatFromInt(slot.x + slot.w)) / @as(f32, @floatFromInt(atlas_w));
                const tv1 = @as(f32, @floatFromInt(slot.y + slot.h)) / @as(f32, @floatFromInt(atlas_h));
                const a = Vertex{ .pos = .{ gx, gy }, .local = .{ tu0, tv0 }, .size = .{ 0, 0 }, .radius = .{ 0, 0, 0, 0 }, .color = n, .mode = 0, .border = 0, .kind = 1 };
                var b = a;
                var c = a;
                var d = a;
                b.pos = .{ gx + gw, gy };
                b.local = .{ tu1, tv0 };
                c.pos = .{ gx + gw, gy + gh };
                c.local = .{ tu1, tv1 };
                d.pos = .{ gx, gy + gh };
                d.local = .{ tu0, tv1 };
                verts.appendSlice(gpa(), &.{ a, b, c, a, c, d }) catch {};
            }
        }
        pen += gm.advance;
    }
}

// Decode once per (path, max_dim) and keep the texture: the CPU surface keys its cache exactly this way.
fn imageTexture(path: []const u8, max_dim: u16) ?ImageTexture {
    if (path.len == 0) return null;
    const key = common.hashImageKey(path, max_dim);
    for (images.items) |t| {
        if (t.key == key) return t;
    }
    // A page has no filesystem, so the bytes come from the store `build.zig`'s `asset_data` fills; a build that carried none draws the placeholder instead.
    const bytes = image_store.find(path) orelse return null;
    const img = soft.decodeImageBytes(gpa(), bytes, max_dim) orelse return null;
    const id = next_image_id;
    // Wrap rather than grow without bound: the page keeps one texture per id, and 255 is more images than a UI has.
    next_image_id = if (next_image_id >= max_images) 1 else next_image_id + 1;
    images.append(gpa(), .{
        .id = id,
        .key = key,
        .width = img.width,
        .height = img.height,
        .version = 1,
        .pixels = img.pixels,
    }) catch {
        gpa().free(@constCast(img.pixels));
        return null;
    };
    return images.items[images.items.len - 1];
}

fn pushImage(x: f32, y: f32, w: f32, h: f32, ref: *const common.ImageRef) void {
    if (w <= 0 or h <= 0) return;
    const path = ref.path_ptr[0..ref.path_len];
    const max_dim: u16 = if (ref.max_dim == 0) 256 else ref.max_dim;
    const placeholder = soft.img_placeholder.toClay();
    const tex = imageTexture(path, max_dim) orelse {
        pushRect(x, y, w, h, .{ 0, 0, 0, 0 }, 0, 0, placeholder);
        return;
    };
    const iw: f32 = @floatFromInt(tex.width);
    const ih: f32 = @floatFromInt(tex.height);
    var qx = x;
    var qy = y;
    var qw = w;
    var qh = h;
    var uv = [4]f32{ 0, 0, 1, 1 };
    switch (ref.fit) {
        .cover => uv = common.coverUv(iw, ih, w, h),
        .contain => {
            pushRect(x, y, w, h, .{ 0, 0, 0, 0 }, 0, 0, placeholder);
            const b = common.containBox(iw, ih, w, h);
            qx = x + b[0];
            qy = y + b[1];
            qw = b[2];
            qh = b[3];
        },
        .stretch => {},
    }
    if (qw <= 0 or qh <= 0) return;

    // Its own run, because the texture changes: the page binds one texture per segment.
    setRun(2, tex.id);
    const white = [4]f32{ 1, 1, 1, 1 };
    const a = Vertex{ .pos = .{ qx, qy }, .local = .{ uv[0], uv[1] }, .size = .{ 0, 0 }, .radius = .{ 0, 0, 0, 0 }, .color = white, .mode = 0, .border = 0, .kind = 2 };
    var b2 = a;
    var c2 = a;
    var d2 = a;
    b2.pos = .{ qx + qw, qy };
    b2.local = .{ uv[2], uv[1] };
    c2.pos = .{ qx + qw, qy + qh };
    c2.local = .{ uv[2], uv[3] };
    d2.pos = .{ qx, qy + qh };
    d2.local = .{ uv[0], uv[3] };
    verts.appendSlice(gpa(), &.{ a, b2, c2, a, c2, d2 }) catch {};
}

fn glyphSlot(face: *const glyphs.Font, cp: u21, fs: u16) ?Slot {
    const key = GlyphKey{ .cp = cp, .size = fs };
    if (slots.get(key)) |s| {
        const mask = glyphs.cachedGlyph(face, cp, fs) orelse return null;
        return .{ .x = s.x, .y = s.y, .w = s.w, .h = s.h, .xoff = mask.xoff, .yoff = mask.yoff };
    }
    const mask = glyphs.cachedGlyph(face, cp, fs) orelse return null;
    if (mask.w == 0 or mask.h == 0) return null;

    if (atlas.len == 0) {
        atlas = gpa().alloc(u8, @as(usize, atlas_w) * atlas_h) catch return null;
        @memset(atlas, 0);
        atlas_dirty = true;
    }
    // Shelf packing: rows fill left to right, then a new shelf starts below the tallest glyph on the previous one.
    if (shelf_x + mask.w > atlas_w) {
        shelf_x = 0;
        shelf_y += shelf_h;
        shelf_h = 0;
    }
    if (shelf_y + mask.h > atlas_h) return null;

    const slot = Slot{ .x = shelf_x, .y = shelf_y, .w = @intCast(mask.w), .h = @intCast(mask.h), .xoff = mask.xoff, .yoff = mask.yoff };
    var row: usize = 0;
    while (row < mask.h) : (row += 1) {
        const dst = @as(usize, slot.y + @as(u32, @intCast(row))) * atlas_w + slot.x;
        @memcpy(atlas[dst .. dst + mask.w], mask.data[row * mask.w .. row * mask.w + mask.w]);
    }
    shelf_x += @intCast(mask.w);
    shelf_h = @max(shelf_h, @as(u32, @intCast(mask.h)));
    atlas_dirty = true;
    slots.put(gpa(), key, slot) catch {};
    return slot;
}
