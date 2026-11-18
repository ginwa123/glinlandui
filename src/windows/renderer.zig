//! Windows renderer — D3D11 on the GPU, with the shared CPU rasteriser as the fallback. The mirror of `src/mac/renderer.zig`: this half turns Clay's command stream into vertices and segments, and `src/windows/shim.c` owns the device and the draws. Everything that decides WHERE a pixel goes is here, so it is testable without a GPU; everything that talks to Direct3D is behind `src/windows/d3d11.zig`, which is the only file that `@cImport`s the shim.
const std = @import("std");
const builtin = @import("builtin");
const cl = @import("zclay");
const soft = @import("../core/render_software.zig");
const glyphs = @import("../core/glyphs.zig");
const text_face = @import("../core/text_face.zig");
const color_glyphs = @import("../core/color_glyphs.zig");
const scale_mod = @import("../core/scale.zig");
const common = @import("../core/render_common.zig");

/// The CPU surface type: still the reference the golden gate compares against.
pub const Surface = soft.Surface;

const on_windows = builtin.os.tag == .windows;
// Always imported, on every host: the module stubs itself out where there is no shim, so a gpu.c reference type-checks everywhere instead of relying on "this branch is dead, so it is not analysed".
const gpu = @import("d3d11.zig");

const atlas_w: u32 = 1024;
const atlas_h: u32 = 1024;

/// Must match `GLIN_MAX_IMAGES` in shim.h.
const max_images: u32 = 32;

/// One vertex. Byte-for-byte `GlinVertex` in shim.h: 17 floats, 68 bytes, and every field is an f32 ARRAY rather than a vector so no compiler gets to disagree about alignment.
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

/// Byte-for-byte `GlinSegment` in shim.h.
const Segment = extern struct {
    start: c_int,
    count: c_int,
    has_scissor: c_int,
    sx: c_int,
    sy: c_int,
    sw: c_int,
    sh: c_int,
    texture_id: c_int,
};

const GlyphKey = struct { cp: u21, size: u16 };

// Module-level, like `mac/renderer.zig`'s `attachView`: the window hands itself over before `run()`, and the frame asks whether the last draw went to the GPU. The Renderer instance lives in frame.zig, which the window cannot reach.
var pending_window: ?*anyopaque = null;
var last_frame_gpu: bool = false;

/// Hand the window over so the renderer can build its pipeline on the window's own device.
pub fn attachWindow(win: ?*anyopaque) void {
    pending_window = win;
}

/// True when the last frame's pixels reached the screen through D3D11, so the window must NOT blit the (stale) CPU surface on top of it.
pub fn drewOnGpu() bool {
    return last_frame_gpu;
}

const GlyphSlot = struct { x: u32, y: u32, w: u32, h: u32 };
const ImageTex = struct { id: u32, w: u32, h: u32 };

pub const Renderer = struct {
    alloc: std.mem.Allocator,
    /// `*gpu.c.GlinWinGpu` on Windows, opaque so this struct compiles anywhere.
    handle: ?*anyopaque = null,
    attach_tried: bool = false,
    /// The window to attach to, handed over before the first frame (the window pointer, not a view: D3D11 renders into the swap chain the window owns).
    window: ?*anyopaque = null,
    /// True when the last drawCommands put its pixels on screen through D3D11, so the window knows not to blit the (stale) CPU surface over it.
    gpu_presented: bool = false,

    /// The CPU path: used when there is no device, when a frame carries an image (the GPU path does not decode images yet), and for `renderHeadless`.
    cpu: ?soft.Renderer = null,

    verts: std.ArrayList(Vertex) = .empty,
    segs: std.ArrayList(Segment) = .empty,
    seg_start: usize = 0,
    // The clip in force for the vertices being accumulated: already intersected with every scissor opened above it.
    seg_open_scissor: ?[4]i32 = null,
    // The clips each `scissor_start` interrupted, so `scissor_end` restores its parent instead of clearing the clip.
    scissor_stack: [soft.max_clip_depth]?[4]i32 = @splat(null),
    scissor_depth: usize = 0,
    seg_texture: i32 = 0,

    atlas: []u8 = &.{},
    atlas_dirty: bool = true,
    glyph_map: std.AutoHashMapUnmanaged(GlyphKey, GlyphSlot) = .empty,
    images: std.AutoHashMapUnmanaged(u64, ImageTex) = .empty,
    // One RGBA texture per colour glyph (an emoji), because the mask atlas is 8-bit and cannot carry colour.
    colour_map: std.AutoHashMapUnmanaged(GlyphKey, ImageTex) = .empty,
    // The device this frame is drawing into: a colour glyph needs it to upload, and `pushText` has no frame parameter.
    gpu_now: ?*anyopaque = null,
    next_image_id: u32 = 1,
    shelf_x: u32 = 0,
    shelf_y: u32 = 0,
    shelf_h: u32 = 0,
    reported_first_frame: bool = false,

    pub fn init(alloc: std.mem.Allocator) !Renderer {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Renderer) void {
        if (on_windows) {
            if (self.handle) |h| gpu.c.glin_win_gpu_destroy(@ptrCast(@alignCast(h)));
            self.handle = null;
        }
        if (self.cpu) |*r| r.deinit();
        self.cpu = null;
        self.verts.deinit(self.alloc);
        self.segs.deinit(self.alloc);
        self.glyph_map.deinit(self.alloc);
        self.images.deinit(self.alloc);
        self.colour_map.deinit(self.alloc);
        if (self.atlas.len > 0) self.alloc.free(self.atlas);
        self.atlas = &.{};
    }

    /// The window hands itself over before `run()`; the device only exists after the window opened, so the attach is lazy (on the first frame).
    pub fn attachWindow(self: *Renderer, win: ?*anyopaque) void {
        self.window = win;
    }

    /// True when D3D11 is drawing, so the window can skip its CPU blit.
    pub fn active(self: *const Renderer) bool {
        return self.handle != null;
    }

    pub fn drawCommands(self: *Renderer, commands: []cl.RenderCommand, win_w: i32, win_h: i32) void {
        self.gpu_presented = false;
        last_frame_gpu = false;
        if (on_windows) {
            if (self.handle == null and !self.attach_tried) self.attach(self.window orelse pending_window);
            if (self.handle) |h| {
                if (self.drawGpu(h, commands, win_w, win_h)) {
                    self.gpu_presented = true;
                    last_frame_gpu = true;
                    return;
                }
            }
        }
        // The fallback: no device, `GLIN_NO_D3D11`, a frame this path cannot draw yet, or a device that just failed. The CPU rasteriser is the reference implementation, so a frame it draws is never wrong — only slower.
        const cpu = self.cpuRenderer() orelse return;
        cpu.drawCommands(commands, win_w, win_h);
    }

    fn cpuRenderer(self: *Renderer) ?*soft.Renderer {
        if (self.cpu == null) self.cpu = soft.Renderer.init(self.alloc) catch return null;
        return &self.cpu.?;
    }

    /// Attach to a live window's device. `GLIN_NO_D3D11` forces the CPU path, so an A/B on the same window needs no rebuild.
    fn attach(self: *Renderer, win: ?*anyopaque) void {
        self.attach_tried = true;
        if (!on_windows) return;
        if (std.c.getenv("GLIN_NO_D3D11") != null) return;
        if (win == null) return;
        self.handle = @ptrCast(gpu.c.glin_win_gpu_create(@ptrCast(@alignCast(win.?))));
    }

    /// True when D3D11 is usable on this machine right now — the parity test's skip condition, and the window's "should I even try" question.
    pub fn gpuUsable() bool {
        return on_windows;
    }

    fn drawGpu(self: *Renderer, handle: *anyopaque, commands: []cl.RenderCommand, win_w: i32, win_h: i32) bool {
        if (win_w <= 0 or win_h <= 0) return false;
        const h: *gpu.c.GlinWinGpu = @ptrCast(@alignCast(handle));
        // `pushText` reaches the device through this, because a colour glyph has to upload its own texture.
        self.gpu_now = handle;

        self.verts.clearRetainingCapacity();
        self.segs.clearRetainingCapacity();
        self.seg_start = 0;
        self.seg_open_scissor = null;
        self.scissor_depth = 0;
        self.seg_texture = 0;

        // The same clear colour the CPU path uses, so a themed background is identical.
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
                .border => self.pushBorder(cmd.render_data.border, bb, k),
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
                        self.pushImage(h, bb.x * k, bb.y * k, bb.width * k, bb.height * k, ref);
                    }
                },
                else => {},
            }
        }
        self.closeSegment();

        if (self.atlas_dirty and self.atlas.len > 0) {
            gpu.c.glin_win_gpu_set_atlas(h, self.atlas.ptr, @intCast(atlas_w), @intCast(atlas_h));
            self.atlas_dirty = false;
        }
        if (self.verts.items.len == 0 or self.segs.items.len == 0) return false;
        const vptr: [*c]const gpu.c.GlinVertex = @ptrCast(self.verts.items.ptr);
        const sptr: [*c]const gpu.c.GlinSegment = @ptrCast(self.segs.items.ptr);
        const presented = gpu.c.glin_win_gpu_draw(
            h,
            vptr,
            @intCast(self.verts.items.len),
            sptr,
            @intCast(self.segs.items.len),
            clear[0],
            clear[1],
            clear[2],
            clear[3],
        ) != 0;
        if (!self.reported_first_frame) {
            self.reported_first_frame = true;
            std.log.info("Windows first frame: {d}x{d}, d3d11, {d} commands, {d} vertices, presented={}", .{
                win_w, win_h, commands.len, self.verts.items.len, presented,
            });
        }
        return presented;
    }

    /// Build a device with no window, for the offscreen parity test. False when this machine has no D3D11 device at all — the test then skips rather than fails.
    pub fn attachOffscreen(self: *Renderer) bool {
        _ = self;
        return on_windows;
    }

    /// Render a command list offscreen and return the DISPLAYED bytes (R,G,B,A, `w * h * 4`, owned by the caller). Null when the GPU could not draw.
    pub fn renderOffscreen(self: *Renderer, commands: []const cl.RenderCommand, w: i32, h: i32) ?[]u8 {
        if (!on_windows) return null;
        if (w <= 0 or h <= 0) return null;

        self.verts.clearRetainingCapacity();
        self.segs.clearRetainingCapacity();
        self.seg_start = 0;
        self.seg_open_scissor = null;
        self.scissor_depth = 0;
        self.seg_texture = 0;
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
                .border => self.pushBorder(cmd.render_data.border, bb, k),
                .text => {
                    const td = cmd.render_data.text;
                    const bytes = td.string_contents.chars[0..@intCast(td.string_contents.length)];
                    self.pushText(bb.x * k, bb.y * k, bb.height * k, bytes, @intFromFloat(@round(@as(f32, @floatFromInt(td.font_size)) * k)), td.text_color);
                },
                .scissor_start => self.pushScissor(bb.x * k, bb.y * k, bb.width * k, bb.height * k),
                .scissor_end => self.popScissor(),
                .image => return null,
                else => {},
            }
        }
        self.closeSegment();
        if (self.verts.items.len == 0 or self.segs.items.len == 0) return null;

        const vptr: [*c]const gpu.c.GlinVertex = @ptrCast(self.verts.items.ptr);
        const sptr: [*c]const gpu.c.GlinSegment = @ptrCast(self.segs.items.ptr);
        const bytes = gpu.c.glin_win_gpu_offscreen(
            vptr,
            @intCast(self.verts.items.len),
            sptr,
            @intCast(self.segs.items.len),
            w,
            h,
            clear[0],
            clear[1],
            clear[2],
            clear[3],
            if (self.atlas.len > 0) self.atlas.ptr else null,
            @intCast(atlas_w),
            @intCast(atlas_h),
        );
        if (bytes == null) return null;
        const out = self.alloc.alloc(u8, @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4) catch {
            gpu.c.glin_win_gpu_free(bytes);
            return null;
        };
        const src: [*]const u8 = @ptrCast(bytes);
        @memcpy(out, src[0..out.len]);
        gpu.c.glin_win_gpu_free(bytes);
        return out;
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

    // The overlap of two clips; a zero size means nothing of the run is visible.
    fn intersectScissor(cur: ?[4]i32, next: [4]i32) [4]i32 {
        const prev = cur orelse return next;
        const x0 = @max(prev[0], next[0]);
        const y0 = @max(prev[1], next[1]);
        const x1 = @min(prev[0] + prev[2], next[0] + next[2]);
        const y1 = @min(prev[1] + prev[3], next[1] + next[3]);
        return .{ x0, y0, @max(x1 - x0, 0), @max(y1 - y0, 0) };
    }

    /// End the run of vertices that share the current scissor and texture.
    fn closeSegment(self: *Renderer) void {
        const end = self.verts.items.len;
        if (end > self.seg_start) {
            const sc = self.seg_open_scissor;
            // An empty clip (two clips that do not overlap) hides the whole run, so no segment is emitted for it.
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
                .sx = if (sc) |s| s[0] else 0,
                .sy = if (sc) |s| s[1] else 0,
                .sw = if (sc) |s| s[2] else 0,
                .sh = if (sc) |s| s[3] else 0,
                .texture_id = self.seg_texture,
            }) catch {};
        }
        self.seg_start = end;
    }

    // A border is four sides in Clay's model; the shader takes one width, so unequal sides become four rects.
    fn pushBorder(self: *Renderer, bd: cl.BorderRenderData, bb: cl.BoundingBox, k: f32) void {
        const top: f32 = @floatFromInt(bd.width.top);
        const bottom: f32 = @floatFromInt(bd.width.bottom);
        const left: f32 = @floatFromInt(bd.width.left);
        const right: f32 = @floatFromInt(bd.width.right);
        if (top == bottom and top == left and top == right) {
            if (top <= 0) return;
            self.pushRect(bb.x * k, bb.y * k, bb.width * k, bb.height * k, .{ 0, 0, 0, 0 }, 1, top * k, bd.color);
            return;
        }
        if (top > 0 and bb.width > 0) self.pushRect(bb.x * k, bb.y * k, bb.width * k, @min(top, bb.height) * k, .{ 0, 0, 0, 0 }, 0, 0, bd.color);
        if (bottom > 0 and bb.width > 0) {
            const bh = @min(bottom, bb.height);
            self.pushRect(bb.x * k, (bb.y + bb.height - bh) * k, bb.width * k, bh * k, .{ 0, 0, 0, 0 }, 0, 0, bd.color);
        }
        const inner_h = bb.height - @min(top, bb.height) - @min(bottom, bb.height);
        if (inner_h > 0) {
            if (left > 0) self.pushRect(bb.x * k, (bb.y + @min(top, bb.height)) * k, @min(left, bb.width) * k, inner_h * k, .{ 0, 0, 0, 0 }, 0, 0, bd.color);
            if (right > 0) {
                const rw = @min(right, bb.width);
                self.pushRect((bb.x + bb.width - rw) * k, (bb.y + @min(top, bb.height)) * k, rw * k, inner_h * k, .{ 0, 0, 0, 0 }, 0, 0, bd.color);
            }
        }
    }

    fn pushRect(self: *Renderer, x: f32, y: f32, w: f32, h: f32, radius: [4]f32, mode: f32, border: f32, color: [4]f32) void {
        if (w <= 0 or h <= 0) return;
        const n = soft.normalizeColorPublic(color);
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
        var a = v;
        var b = v;
        var c2 = v;
        var d = v;
        // A rect's `local` is box-local, so the SDF can be evaluated per pixel.
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
        // The same baseline rule as the CPU path: the CAP BOX is centred in the box, not the line box.
        const baseline = if (glyphs.capBox(face, size)) |cap|
            bbox_y + (if (bbox_h > 0) (bbox_h - cap.height) * 0.5 else 0) - cap.top
        else
            bbox_y + (if (bbox_h > 0) bbox_h - face.lineHeight(size) else 0) * 0.5 + m.ascent;

        var pen = bbox_x;
        var i: usize = 0;
        while (i < bytes.len) {
            const cp = glyphs.nextCodepoint(bytes, &i);
            // An emoji is a colour image, not a mask: its own texture, its own segment, its own advance.
            if (self.gpu_now) |dev| {
                if (text_face.colorGlyph(cp, size)) |image| {
                    self.pushColourGlyph(@ptrCast(@alignCast(dev)), cp, size, image, pen, baseline);
                    pen += image.advance;
                    continue;
                }
            }
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

    /// Upload an image once per (path, max_dim) into a fixed texture slot and draw its quad, in DEVICE pixels.
    fn pushImage(self: *Renderer, g: *gpu.c.GlinWinGpu, x: f32, y: f32, bw: f32, bh: f32, ref: *const common.ImageRef) void {
        if (bw <= 0 or bh <= 0) return;
        const path = ref.path_ptr[0..ref.path_len];
        const max_dim: u16 = if (ref.max_dim == 0) 256 else ref.max_dim;
        const placeholder = soft.img_placeholder.toClay();
        const tex = self.imageTex(g, path, max_dim) orelse {
            self.pushRect(x, y, bw, bh, .{ 0, 0, 0, 0 }, 0, 0, placeholder);
            return;
        };
        const iw: f32 = @floatFromInt(tex.w);
        const ih: f32 = @floatFromInt(tex.h);
        var qx = x;
        var qy = y;
        var qw = bw;
        var qh = bh;
        var uv = [4]f32{ 0, 0, 1, 1 };
        switch (ref.fit) {
            .cover => uv = common.coverUv(iw, ih, bw, bh),
            .contain => {
                self.pushRect(x, y, bw, bh, .{ 0, 0, 0, 0 }, 0, 0, placeholder);
                const b = common.containBox(iw, ih, bw, bh);
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
        self.seg_texture = @intCast(tex.id);
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

    /// One colour glyph as its own untinted quad: the image path's trick, once per emoji, with its own advance.
    fn pushColourGlyph(self: *Renderer, g: *gpu.c.GlinWinGpu, cp: u21, size: u16, image: *const color_glyphs.Rgba, pen: f32, baseline: f32) void {
        const tex = self.colourTex(g, cp, size, image) orelse return;
        const qx = @floor(pen + @as(f32, @floatFromInt(image.xoff)));
        const qy = @floor(baseline + @as(f32, @floatFromInt(image.yoff)));
        const qw: f32 = @floatFromInt(tex.w);
        const qh: f32 = @floatFromInt(tex.h);
        if (qw <= 0 or qh <= 0) return;
        // Its own segment, because the texture changes and the mask atlas must be bound again after it.
        self.closeSegment();
        self.seg_texture = @intCast(tex.id);
        const white = [4]f32{ 1, 1, 1, 1 };
        const a = Vertex{ .pos = .{ qx, qy }, .local = .{ 0, 0 }, .size = .{ 0, 0 }, .radius = .{ 0, 0, 0, 0 }, .color = white, .mode = 0, .border = 0, .kind = 2 };
        var b = a;
        var c2 = a;
        var d = a;
        b.pos = .{ qx + qw, qy };
        b.local = .{ 1, 0 };
        c2.pos = .{ qx + qw, qy + qh };
        c2.local = .{ 1, 1 };
        d.pos = .{ qx, qy + qh };
        d.local = .{ 0, 1 };
        self.verts.appendSlice(self.alloc, &.{ a, b, c2, a, c2, d }) catch {};
        self.closeSegment();
        self.seg_texture = 0;
    }

    /// Upload one RGBA texture per (codepoint, size) from the same decoded image the CPU path blits.
    fn colourTex(self: *Renderer, g: *gpu.c.GlinWinGpu, cp: u21, size: u16, image: *const color_glyphs.Rgba) ?ImageTex {
        const key = GlyphKey{ .cp = cp, .size = size };
        if (self.colour_map.get(key)) |t| return t;
        if (image.w == 0 or image.h == 0) return null;
        const id = self.next_image_id;
        // The shader's slot table is fixed (GLIN_MAX_IMAGES), and the glyph atlas is slot 0, so wrap rather than grow.
        if (self.next_image_id + 1 >= max_images) self.next_image_id = 1 else self.next_image_id += 1;
        gpu.c.glin_win_gpu_set_image(g, @intCast(id), image.pixels.ptr, @intCast(image.w), @intCast(image.h));
        const tex = ImageTex{ .id = id, .w = @intCast(image.w), .h = @intCast(image.h) };
        self.colour_map.put(self.alloc, key, tex) catch {};
        return tex;
    }

    /// The pixels come from the CPU surface's own decode cache, so the GPU and the reference cannot disagree about the bitmap.
    fn imageTex(self: *Renderer, g: *gpu.c.GlinWinGpu, path: []const u8, max_dim: u16) ?ImageTex {
        if (path.len == 0) return null;
        const key = common.hashImageKey(path, max_dim);
        if (self.images.get(key)) |t| return t;
        const cpu = self.cpuRenderer() orelse return null;
        const img = cpu.imageFor(path, max_dim) orelse return null;
        const id = self.next_image_id;
        // The shader's slot table is fixed (GLIN_MAX_IMAGES, 0 is the glyph atlas), so wrap rather than grow.
        if (self.next_image_id + 1 >= max_images) self.next_image_id = 1 else self.next_image_id += 1;
        gpu.c.glin_win_gpu_set_image(g, @intCast(id), img.pixels.ptr, @intCast(img.width), @intCast(img.height));
        const tex = ImageTex{ .id = id, .w = img.width, .h = img.height };
        self.images.put(self.alloc, key, tex) catch {};
        return tex;
    }

    const Slot = struct { x: u32, y: u32, w: u32, h: u32, xoff: f32, yoff: f32 };

    /// Place one glyph mask in the atlas (shelf packing) and return its slot, in DEVICE pixels. The mask bytes and the offsets come from the same process-wide cache the CPU path blits from, which is what makes the two agree.
    fn glyphSlot(self: *Renderer, face: *const glyphs.Font, cp: u21, fs: u16) ?Slot {
        const key = GlyphKey{ .cp = cp, .size = fs };
        if (self.glyph_map.get(key)) |s| {
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
        // Shelf packing: rows fill left to right, then a new shelf starts below the tallest glyph.
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
        self.glyph_map.put(self.alloc, key, slot) catch {};
        return .{ .x = slot.x, .y = slot.y, .w = slot.w, .h = slot.h, .xoff = mask.xoff, .yoff = mask.yoff };
    }
};
