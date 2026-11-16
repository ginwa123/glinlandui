//! macOS renderer — Metal. The CPU surface stays exported for the contract test, the frame-diff tooling and `renderHeadless`.
const std = @import("std");
const builtin = @import("builtin");
const cl = @import("zclay");
const soft = @import("../core/render_software.zig");
const glyphs = @import("../core/glyphs.zig");
const text_face = @import("../core/text_face.zig");
const scale_mod = @import("../core/scale.zig");
const common = @import("../core/render_common.zig");
const stbi = @cImport({
    @cInclude("stb/stb_image.h");
    @cInclude("stb/stb_image_resize2.h");
});

/// The CPU surface type the software renderer draws into; still the reference the golden gate compares against.
pub const Surface = soft.Surface;

pub const c = @cImport({
    @cInclude("metal.h");
});

/// One vertex. Must stay in step with `GlinVertex` in src/mac/metal.m — a mismatch is a silent mis-draw.
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

const atlas_w: u32 = 1024;
const atlas_h: u32 = 1024;

// The window hands its view over before the first frame; the renderer is built lazily by the frame path, so it picks this up on first draw.
var pending_view: ?*anyopaque = null;
// True only after `glin_metal_create` succeeded, so the window keeps blitting the CPU surface if Metal is unavailable.
var metal_live: bool = false;

/// The view the renderer should attach its Metal layer to. Called by the window before `run()`.
pub fn attachView(nsview: ?*anyopaque) void {
    pending_view = nsview;
}

/// True once the GPU is actually drawing, so the window can stop the CoreGraphics blit.
pub fn isActive() bool {
    return metal_live;
}

const GlyphKey = struct { cp: u21, size: u16 };
const GlyphSlot = struct { x: u32, y: u32, w: u32, h: u32 };

pub const Renderer = struct {
    alloc: std.mem.Allocator,
    handle: ?*c.GlinMetal = null,
    created: bool = false,

    // The CPU path, used when the machine has no Metal device or GLIN_NO_METAL is set.
    cpu: ?soft.Renderer = null,

    verts: std.ArrayList(Vertex) = .empty,
    segs: std.ArrayList(c.GlinSegment) = .empty,
    seg_start: usize = 0,
    seg_scissor: ?[4]i32 = null,
    // The clip in force for the vertices being accumulated: already intersected with every scissor opened above it.
    seg_open_scissor: ?[4]i32 = null,
    // The clips each `scissor_start` interrupted, so `scissor_end` restores its parent instead of clearing the clip.
    scissor_stack: [soft.max_clip_depth]?[4]i32 = @splat(null),
    scissor_depth: usize = 0,
    seg_texture: u32 = 0,

    atlas: []u8 = &.{},
    atlas_dirty: bool = true,
    glyphs_map: std.AutoHashMapUnmanaged(GlyphKey, GlyphSlot) = .empty,
    // Decoded images, keyed exactly as the CPU surface keys its cache.
    images: std.AutoHashMapUnmanaged(u64, ImageTex) = .empty,
    next_image_id: u32 = 1,
    shelf_x: u32 = 0,
    shelf_y: u32 = 0,
    shelf_h: u32 = 0,

    // Frame-time accumulator for GLIN_FPS: the number the window's smoothness actually follows.
    fps_frames: u32 = 0,
    fps_ns: i96 = 0,
    /// True once the first Metal frame has been described, so the log line appears exactly once.
    reported_first_frame: bool = false,

    pub fn init(alloc: std.mem.Allocator) !Renderer {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Renderer) void {
        if (self.handle) |h| c.glin_metal_destroy(h);
        self.handle = null;
        if (self.cpu) |*r| r.deinit();
        self.cpu = null;
        self.verts.deinit(self.alloc);
        self.segs.deinit(self.alloc);
        self.glyphs_map.deinit(self.alloc);
        self.images.deinit(self.alloc);
        if (self.atlas.len > 0) self.alloc.free(self.atlas);
        self.atlas = &.{};
    }

    /// Attach the renderer to a window's view. Called by the window before the first frame; without it every draw is a no-op.
    pub fn attach(self: *Renderer, nsview: ?*anyopaque) void {
        // The GPU path is the default; GLIN_NO_METAL forces the CPU renderer for an A/B on the same window.
        if (std.c.getenv("GLIN_NO_METAL") != null) return;
        if (self.handle != null or nsview == null) return;
        self.handle = c.glin_metal_create(nsview);
        self.created = true;
        metal_live = self.handle != null;
    }

    /// True when Metal is actually driving the screen, so the window can skip the CoreGraphics blit.
    pub fn active(self: *const Renderer) bool {
        return self.handle != null;
    }

    pub fn drawCommands(self: *Renderer, commands: []cl.RenderCommand, win_w: i32, win_h: i32) void {
        if (self.handle == null and pending_view != null) self.attach(pending_view);
        if (self.handle) |h| {
            self.drawMetal(h, commands, win_w, win_h);
            return;
        }
        // No GPU: fall back to the CPU surface, which the window blits through CoreGraphics.
        if (self.cpu == null) self.cpu = soft.Renderer.init(self.alloc) catch return;
        const t0: i96 = if (std.c.getenv("GLIN_FPS") != null) fpsNowNs() else 0;
        self.cpu.?.drawCommands(commands, win_w, win_h);
        if (t0 != 0) self.recordFrame(fpsNowNs() - t0);
    }

    fn drawMetal(self: *Renderer, h: *c.GlinMetal, commands: []cl.RenderCommand, win_w: i32, win_h: i32) void {
        if (win_w <= 0 or win_h <= 0) return;
        // The drawable is DEVICE pixels: the vertex buffer is built at logical x render_scale, so a 2x display needs 2x the drawable.
        const px = scale_mod.pixelSize(@intCast(win_w), @intCast(win_h), soft.renderScale());
        _ = c.glin_metal_resize(h, @intCast(px.w), @intCast(px.h));

        self.verts.clearRetainingCapacity();
        self.segs.clearRetainingCapacity();
        self.seg_start = 0;
        self.seg_open_scissor = null;
        self.scissor_depth = 0;

        // The frame's clear colour comes from the same place the CPU path reads it, so a themed background is identical.
        const clear = soft.currentClearColor();
        const k = soft.renderScale();

        for (commands) |*cmd| {
            const bb = cmd.bounding_box;
            switch (cmd.command_type) {
                .rectangle => {
                    const r = cmd.render_data.rectangle;
                    if (r.background_color[3] <= 0) continue;
                    const cr = soft.cornerRadiusVec4(r.corner_radius);
                    self.pushRect(bb.x * k, bb.y * k, bb.width * k, bb.height * k, .{
                        cr[0] * k, cr[1] * k, cr[2] * k, cr[3] * k,
                    }, 0, 0, r.background_color);
                },
                .border => {
                    const bd = cmd.render_data.border;
                    self.pushRect(bb.x * k, bb.y * k, bb.width * k, bb.height * k, .{ 0, 0, 0, 0 }, 1, @floatFromInt(borderWidth(bd.width)), bd.color);
                },
                .text => {
                    const td = cmd.render_data.text;
                    const bytes = td.string_contents.chars[0..@intCast(td.string_contents.length)];
                    self.pushText(bb.x * k, bb.y * k, bb.height * k, bytes, @intFromFloat(@round(@as(f32, @floatFromInt(td.font_size)) * k)), td.text_color);
                },
                .scissor_start => self.pushScissor(bb.x * k, bb.y * k, bb.width * k, bb.height * k),
                .scissor_end => self.popScissor(),
                .image => {
                    const im = cmd.render_data.image;
                    if (im.image_data) |ptr| {
                        const ref: *const common.ImageRef = @ptrCast(@alignCast(ptr));
                        self.pushImage(bb.x * k, bb.y * k, bb.width * k, bb.height * k, ref);
                    }
                },
                else => {},
            }
        }
        self.closeSegment();

        if (self.atlas_dirty and self.atlas.len > 0) {
            c.glin_metal_set_atlas(h, self.atlas.ptr, @intCast(atlas_w), @intCast(atlas_h));
            self.atlas_dirty = false;
        }
        const t0: i96 = if (std.c.getenv("GLIN_FPS") != null) fpsNowNs() else 0;
        const presented = c.glin_metal_draw(h, self.verts.items.ptr, self.segs.items.ptr, @intCast(self.segs.items.len), clear[0], clear[1], clear[2], clear[3]) != 0;
        if (t0 != 0) self.recordFrame(fpsNowNs() - t0);
        // One line per run, so a scripted Metal run is not silent: the CPU path reports painted pixels and a blit checksum, and the GPU has no such bytes — but "did the layer hand us a drawable" is the question a headless runner answers "no".
        if (self.reported_first_frame) return;
        self.reported_first_frame = true;
        std.log.info("macOS first frame: {d}x{d}, metal, {d} commands, {d} vertices, presented={}", .{
            win_w, win_h, commands.len, self.verts.items.len, presented,
        });
    }

    /// Build a device and pipeline with no layer, for the offscreen parity test. False when the machine has no Metal device.
    pub fn attachOffscreen(self: *Renderer) bool {
        if (self.handle == null) self.handle = c.glin_metal_create(null);
        metal_live = self.handle != null;
        return self.handle != null;
    }

    /// Render a command list offscreen and return BGRA bytes, so a test can compare the GPU against the CPU reference.
    pub fn renderOffscreen(self: *Renderer, commands: []const cl.RenderCommand, w: i32, h: i32) ?[]u8 {
        const mh = self.handle orelse return null;
        _ = c.glin_metal_resize(mh, w, h);
        self.verts.clearRetainingCapacity();
        self.segs.clearRetainingCapacity();
        self.seg_start = 0;
        self.seg_open_scissor = null;
        self.scissor_depth = 0;
        const clear = soft.currentClearColor();
        const k = soft.renderScale();
        for (commands) |*cmd| {
            const bb = cmd.bounding_box;
            switch (cmd.command_type) {
                .rectangle => {
                    const r = cmd.render_data.rectangle;
                    if (r.background_color[3] <= 0) continue;
                    const cr = soft.cornerRadiusVec4(r.corner_radius);
                    self.pushRect(bb.x * k, bb.y * k, bb.width * k, bb.height * k, .{
                        cr[0] * k, cr[1] * k, cr[2] * k, cr[3] * k,
                    }, 0, 0, r.background_color);
                },
                .border => {
                    const bd = cmd.render_data.border;
                    self.pushRect(bb.x * k, bb.y * k, bb.width * k, bb.height * k, .{ 0, 0, 0, 0 }, 1, @floatFromInt(borderWidth(bd.width)), bd.color);
                },
                .text => {
                    const td = cmd.render_data.text;
                    const bytes = td.string_contents.chars[0..@intCast(td.string_contents.length)];
                    self.pushText(bb.x * k, bb.y * k, bb.height * k, bytes, @intFromFloat(@round(@as(f32, @floatFromInt(td.font_size)) * k)), td.text_color);
                },
                .scissor_start => self.pushScissor(bb.x * k, bb.y * k, bb.width * k, bb.height * k),
                .scissor_end => self.popScissor(),
                .image => {
                    const im = cmd.render_data.image;
                    if (im.image_data) |ptr| {
                        const ref: *const common.ImageRef = @ptrCast(@alignCast(ptr));
                        self.pushImage(bb.x * k, bb.y * k, bb.width * k, bb.height * k, ref);
                    }
                },
                else => {},
            }
        }
        self.closeSegment();
        if (self.atlas_dirty and self.atlas.len > 0) {
            c.glin_metal_set_atlas(mh, self.atlas.ptr, @intCast(atlas_w), @intCast(atlas_h));
            self.atlas_dirty = false;
        }
        const bytes = c.glin_metal_offscreen(mh, self.verts.items.ptr, self.segs.items.ptr, @intCast(self.segs.items.len), w, h, clear[0], clear[1], clear[2], clear[3]) orelse return null;
        defer c.glin_metal_free(bytes);
        const len: usize = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
        const out = self.alloc.alloc(u8, len) catch return null;
        @memcpy(out, bytes[0..len]);
        return out;
    }

    fn recordFrame(self: *Renderer, ns: i96) void {
        self.fps_frames += 1;
        self.fps_ns += ns;
        if (self.fps_frames == 60) {
            const avg_ms = @as(f64, @floatFromInt(self.fps_ns)) / 60.0 / 1.0e6;
            std.debug.print("FRAME {d:.2} ms  ({d:.0} fps)\n", .{ avg_ms, 1000.0 / avg_ms });
            self.fps_frames = 0;
            self.fps_ns = 0;
        }
    }

    // Open a clip. It INTERSECTS the one in force, so an inner clip (a field's, as tall as its content) never widens the scroll box around it.
    fn pushScissor(self: *Renderer, x: f32, y: f32, w: f32, h: f32) void {
        self.closeSegment();
        const next: [4]i32 = .{
            @intFromFloat(@max(x, 0)),
            @intFromFloat(@max(y, 0)),
            @intFromFloat(@max(w, 0)),
            @intFromFloat(@max(h, 0)),
        };
        if (self.scissor_depth < self.scissor_stack.len) {
            self.scissor_stack[self.scissor_depth] = self.seg_open_scissor;
            self.scissor_depth += 1;
        }
        self.seg_open_scissor = intersectScissor(self.seg_open_scissor, next);
    }

    fn popScissor(self: *Renderer) void {
        self.closeSegment();
        if (self.scissor_depth == 0) {
            self.seg_open_scissor = null;
            return;
        }
        self.scissor_depth -= 1;
        self.seg_open_scissor = self.scissor_stack[self.scissor_depth];
    }

    // The overlap of two clips, or an empty (zero-size) rect when they do not touch: a scissor of nothing clips everything.
    fn intersectScissor(cur: ?[4]i32, next: [4]i32) [4]i32 {
        const prev = cur orelse return next;
        const x0 = @max(prev[0], next[0]);
        const y0 = @max(prev[1], next[1]);
        const x1 = @min(prev[0] + prev[2], next[0] + next[2]);
        const y1 = @min(prev[1] + prev[3], next[1] + next[3]);
        return .{ x0, y0, @max(x1 - x0, 0), @max(y1 - y0, 0) };
    }

    fn closeSegment(self: *Renderer) void {
        const end = self.verts.items.len;
        if (end > self.seg_start) {
            const sc = self.seg_open_scissor;
            // An empty clip (two clips that do not overlap) hides the whole run, so the run is dropped, not drawn unscissored.
            if (sc) |v| {
                if (v[2] <= 0 or v[3] <= 0) {
                    self.seg_start = end;
                    return;
                }
            }
            self.segs.append(self.alloc, .{
                .start = @intCast(self.seg_start),
                .count = @intCast(end - self.seg_start),
                .has_scissor = if (sc != null) 1 else 0,
                .sx = if (sc) |v| v[0] else 0,
                .sy = if (sc) |v| v[1] else 0,
                .sw = if (sc) |v| v[2] else 0,
                .sh = if (sc) |v| v[3] else 0,
                .texture_id = self.seg_texture,
            }) catch {};
        }
        self.seg_start = end;
    }

    fn pushQuad(self: *Renderer, x: f32, y: f32, w: f32, h: f32, v: Vertex) void {
        const a = v;
        var b = v;
        var cc = v;
        var d = v;
        a.pos = .{ x, y };
        b.pos = .{ x + w, y };
        cc.pos = .{ x + w, y + h };
        d.pos = .{ x, y + h };
        self.verts.appendSlice(self.alloc, &.{ a, b, cc, a, cc, d }) catch {};
    }

    fn pushRect(self: *Renderer, x: f32, y: f32, w: f32, h: f32, radius: [4]f32, mode: f32, border: f32, color: [4]f32) void {
        if (w <= 0 or h <= 0) return;
        const n = soft.normalizeColorPublic(color);
        // Corners carry box-local coordinates; the fragment shader turns them into the SDF.
        const v = Vertex{
            .pos = .{ 0, 0 },
            .local = .{ 0, 0 },
            .size = .{ w, h },
            .radius = radius,
            .color = n,
            .mode = mode,
            .border = border,
            .kind = 0,
        };
        self.pushQuadLocal(x, y, w, h, v);
    }

    // A rect's `local` varies per corner, so it cannot use the shared quad writer.
    fn pushQuadLocal(self: *Renderer, x: f32, y: f32, w: f32, h: f32, v: Vertex) void {
        var a = v;
        var b = v;
        var c2 = v;
        var d = v;
        a.pos = .{ x, y };
        a.local = .{ 0, 0 };
        b.pos = .{ x + w, y };
        b.local = .{ w, 0 };
        c2.pos = .{ x + w, y + h };
        c2.local = .{ w, h };
        d.pos = .{ x, y + h };
        d.local = .{ 0, h };
        self.verts.appendSlice(self.alloc, &.{ a, b, c2, a, c2, d }) catch {};
    }

    fn pushText(self: *Renderer, bbox_x: f32, bbox_y: f32, bbox_h: f32, bytes: []const u8, fs: u16, color: [4]f32) void {
        if (bytes.len == 0) return;
        const face = text_face.font() orelse return;
        const size: u16 = if (fs == 0) 16 else fs;
        const m = glyphs.measure(face, bytes, size);
        if (m.width <= 0) return;
        const n = soft.normalizeColorPublic(color);
        // Same baseline rule as the CPU path: the CAP BOX is centred in the box, not the font's line box.
        const baseline = if (glyphs.capBox(face, size)) |cap|
            bbox_y + (if (bbox_h > 0) (bbox_h - cap.height) * 0.5 else 0) - cap.top
        else
            bbox_y + (if (bbox_h > 0) bbox_h - face.lineHeight(size) else 0) * 0.5 + m.ascent;

        var pen = bbox_x;
        var i: usize = 0;
        while (i < bytes.len) {
            const cp = glyphs.nextCodepoint(bytes, &i);
            const gm = face.glyphMetrics(cp, size);
            if (self.glyphSlot(face, cp, size)) |slot| {
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
                    var c2 = a;
                    var d = a;
                    b.pos = .{ gx + gw, gy };
                    b.local = .{ tu1, tv0 };
                    c2.pos = .{ gx + gw, gy + gh };
                    c2.local = .{ tu1, tv1 };
                    d.pos = .{ gx, gy + gh };
                    d.local = .{ tu0, tv1 };
                    self.verts.appendSlice(self.alloc, &.{ a, b, c2, a, c2, d }) catch {};
                }
            }
            pen += gm.advance;
        }
    }

    // Decode once per (path, max_dim) and keep the texture; the CPU surface keys its cache the same way.
    fn imageTex(self: *Renderer, path: []const u8, max_dim: u16) ?ImageTex {
        if (path.len == 0) return null;
        const key = common.hashImageKey(path, max_dim);
        if (self.images.get(key)) |t| return t;

        var cbuf: [std.fs.max_path_bytes]u8 = undefined;
        if (path.len + 1 > cbuf.len) return null;
        @memcpy(cbuf[0..path.len], path);
        cbuf[path.len] = 0;

        var iw: c_int = 0;
        var ih: c_int = 0;
        var nch: c_int = 0;
        const px = stbi.stbi_load(@ptrCast(&cbuf), &iw, &ih, &nch, 4) orelse return null;
        defer stbi.stbi_image_free(px);
        if (iw <= 0 or ih <= 0) return null;

        const dims = common.scaledDims(@intCast(iw), @intCast(ih), max_dim);
        var src: [*]const u8 = px;
        var owned: []u8 = &.{};
        defer if (owned.len > 0) self.alloc.free(owned);
        if (dims[0] != @as(u32, @intCast(iw)) or dims[1] != @as(u32, @intCast(ih))) {
            owned = self.alloc.alloc(u8, dims[0] * dims[1] * 4) catch return null;
            if (stbi.stbir_resize_uint8_linear(px, iw, ih, 0, owned.ptr, @intCast(dims[0]), @intCast(dims[1]), 0, stbi.STBIR_RGBA) == null) return null;
            src = owned.ptr;
        }

        const id = self.next_image_id;
        self.next_image_id += 1;
        // Metal keeps a fixed table; wrap rather than grow, so a long-lived app cannot exhaust it silently.
        if (self.next_image_id >= max_images) self.next_image_id = 1;

        const h = self.handle orelse return null;
        c.glin_metal_set_image(h, id, src, @intCast(dims[0]), @intCast(dims[1]));
        const tex = ImageTex{ .id = id, .w = dims[0], .h = dims[1] };
        self.images.put(self.alloc, key, tex) catch {};
        return tex;
    }

    fn pushImage(self: *Renderer, x: f32, y: f32, w: f32, h: f32, ref: *const common.ImageRef) void {
        if (w <= 0 or h <= 0) return;
        const path = ref.path_ptr[0..ref.path_len];
        const max_dim: u16 = if (ref.max_dim == 0) 256 else ref.max_dim;
        const placeholder = soft.img_placeholder.toClay();
        const tex = self.imageTex(path, max_dim) orelse {
            self.pushRect(x, y, w, h, .{ 0, 0, 0, 0 }, 0, 0, placeholder);
            return;
        };
        const iw: f32 = @floatFromInt(tex.w);
        const ih: f32 = @floatFromInt(tex.h);
        var qx = x;
        var qy = y;
        var qw = w;
        var qh = h;
        var uv = [4]f32{ 0, 0, 1, 1 };
        switch (ref.fit) {
            .cover => uv = common.coverUv(iw, ih, w, h),
            .contain => {
                self.pushRect(x, y, w, h, .{ 0, 0, 0, 0 }, 0, 0, placeholder);
                const b = common.containBox(iw, ih, w, h);
                qx = x + b[0];
                qy = y + b[1];
                qw = b[2];
                qh = b[3];
            },
            .stretch => {},
        }
        if (qw <= 0 or qh <= 0) return;

        // Its own segment, because the texture changes: the encoder binds one texture per segment.
        self.closeSegment();
        self.seg_texture = tex.id;
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
        self.verts.appendSlice(self.alloc, &.{ a, b2, c2, a, c2, d2 }) catch {};
        self.closeSegment();
        self.seg_texture = 0;
    }

    const Slot = struct { x: u32, y: u32, w: u32, h: u32, xoff: f32, yoff: f32 };

    fn glyphSlot(self: *Renderer, face: *const glyphs.Font, cp: u21, fs: u16) ?Slot {
        const key = GlyphKey{ .cp = cp, .size = fs };
        if (self.glyphs_map.get(key)) |s| {
            const mask = glyphs.cachedGlyph(face, cp, fs) orelse return null;
            return .{ .x = s.x, .y = s.y, .w = s.w, .h = s.h, .xoff = mask.xoff, .yoff = mask.yoff };
        }
        const mask = glyphs.cachedGlyph(face, cp, fs) orelse return null;
        if (mask.w == 0 or mask.h == 0) return null;

        if (self.atlas.len == 0) {
            self.atlas = self.alloc.alloc(u8, @as(usize, atlas_w) * atlas_h) catch return null;
            @memset(self.atlas, 0);
            self.atlas_dirty = true;
        }
        // Shelf packing: rows fill left to right, then a new shelf starts below the tallest glyph on the previous one.
        if (self.shelf_x + mask.w > atlas_w) {
            self.shelf_x = 0;
            self.shelf_y += self.shelf_h;
            self.shelf_h = 0;
        }
        if (self.shelf_y + mask.h > atlas_h) return null;

        const slot = GlyphSlot{ .x = self.shelf_x, .y = self.shelf_y, .w = @intCast(mask.w), .h = @intCast(mask.h) };
        var row: usize = 0;
        while (row < mask.h) : (row += 1) {
            const dst = @as(usize, slot.y + @as(u32, @intCast(row))) * atlas_w + slot.x;
            @memcpy(self.atlas[dst .. dst + mask.w], mask.data[row * mask.w .. row * mask.w + mask.w]);
        }
        self.shelf_x += @intCast(mask.w);
        self.shelf_h = @max(self.shelf_h, @as(u32, @intCast(mask.h)));
        self.atlas_dirty = true;
        self.glyphs_map.put(self.alloc, key, slot) catch {};
        return .{ .x = slot.x, .y = slot.y, .w = slot.w, .h = slot.h, .xoff = mask.xoff, .yoff = mask.yoff };
    }
};

const ImageTex = struct { id: u32, w: u32, h: u32 };

// Must match GLIN_METAL_MAX_IMAGES in metal.h.
const max_images: u32 = 32;

fn fpsNowNs() i96 {
    return std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds;
}

fn borderWidth(bw: cl.BorderWidth) u16 {
    // Clay's BorderWidth is a struct of four sides; the CPU path draws each side, the shader needs one number.
    return @max(bw.left, @max(bw.right, @max(bw.top, bw.bottom)));
}
