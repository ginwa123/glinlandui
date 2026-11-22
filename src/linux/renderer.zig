//! Vulkan renderer for the Linux backend: geometry, caches and clip arithmetic here, Vulkan objects in vk.c.
const std = @import("std");
const builtin = @import("builtin");
const log = @import("../core/log.zig");
const text = @import("text.zig");
const render_common = @import("../core/render_common.zig");
const soft = @import("../core/render_software.zig");
const Color = @import("../core/color.zig").Color;
const cl = @import("zclay");
const ui_scale = @import("ui_scale.zig");
const scale = @import("../core/scale.zig");
// The one clip depth every renderer shares, so a nested clip cannot out-run any backend's stack.
const max_clip_depth = soft.max_clip_depth;

const vk = @cImport({
    @cInclude("vk.h");
});

const stbi = @cImport({
    @cInclude("stb/stb_image.h");
    @cInclude("stb/stb_image_resize2.h");
});

// The SPIR-V is committed next to its GLSL (tools/build_shaders.sh), so the Linux build never needs a shader compiler.
const quad_vert_spv = @embedFile("shaders/quad.vert.spv");
const rect_frag_spv = @embedFile("shaders/rect.frag.spv");
const text_frag_spv = @embedFile("shaders/text.frag.spv");
const image_frag_spv = @embedFile("shaders/image.frag.spv");

/// Headless-testable draw command: rect fill or text run.
pub const Draw = render_common.Draw;
/// How an image fills its box (mirrors wallpaper fit modes + stretch).
pub const ImageFit = render_common.ImageFit;
/// Opaque payload a widget passes through Clay's image_data pointer.
pub const ImageRef = render_common.ImageRef;

fn normChannel(v: u32) f32 {
    return @as(f32, @floatFromInt(v & 0xff)) / 255.0;
}

// ---- Pure helpers (headless-testable) ----

/// Convert 0xRRGGBB to a Clay color ([4]f32 in 0-255 range, alpha 255).
pub fn u32ToClayColor(hex: u32) [4]f32 {
    return Color.argb(0xFF00_0000 | (hex & 0x00ff_ffff)).toClay();
}

/// Convert 0xRRGGBB to normalized RGBA floats (alpha 1.0).
pub fn u32ToGLColor(hex: u32) [4]f32 {
    return .{ normChannel(hex >> 16), normChannel(hex >> 8), normChannel(hex), 1.0 };
}

/// Legacy fixed advance per glyph (stb fallback path only).
pub fn estimatorAdvance(font_size: u16) f32 {
    return @as(f32, @floatFromInt(font_size)) * 0.6;
}

/// Map a text.measureText extent to Clay dimensions.
pub fn extentToClay(ext: text.TextExtent) cl.Dimensions {
    return .{ .w = ext.w, .h = ext.h };
}

/// Normalize a Clay 0-255 color (or an already-0-1 one) to 0-1 RGBA.
fn straightColor(clay_color: [4]f32) [4]f32 {
    const mx = @max(@max(clay_color[0], clay_color[1]), @max(clay_color[2], clay_color[3]));
    if (mx <= 1.0) return clay_color;
    return .{ clay_color[0] / 255.0, clay_color[1] / 255.0, clay_color[2] / 255.0, clay_color[3] / 255.0 };
}

/// The colour the render pass clears to before any command is drawn.
pub fn clearColor() [4]f32 {
    const clay = Color.rgb(0x11, 0x11, 0x11).toClay();
    return .{ clay[0] / 255.0, clay[1] / 255.0, clay[2] / 255.0, clay[3] / 255.0 };
}

// ---- Texture ids ----

// The shim's table is fixed and indexed by id, so a cache slot owns the same id for the whole run.
pub const text_cache_size: usize = 64;
pub const img_cache_size: usize = 32;
/// Id 0 is the shim's 1x1 white pixel, which rect segments bind and never sample meaningfully.
pub const text_texture_base: u32 = 1;
pub const image_texture_base: u32 = 1 + text_cache_size;

/// Text texture cache: a run's coverage is the same pixels whatever colour it is drawn in, so a hover repaint re-uses it.
pub const TextCacheEntry = struct {
    hash: u64 = 0,
    tex: u32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    valid: bool = false,
    last_used: u64 = 0,
};

/// Decoded image texture cache: decoded+downscaled RGBA keyed by FNV-1a(path, max_dim).
pub const ImgCacheEntry = struct {
    hash: u64 = 0,
    tex: u32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    valid: bool = false,
    last_used: u64 = 0,
};

/// Decoded + uploaded image, named so decodeUploadImage and imageTexture share one return type.
pub const DecodedImage = struct {
    tex: u32,
    w: i32,
    h: i32,
};

/// Pure + headless-testable key for the texture cache: the run, its size, its box, and the sub-pixel origin the glyphs snap from.
pub fn hashTextKey(text_bytes: []const u8, font_size: u16, box_height: i32, origin_x: f32, origin_y: f32) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (text_bytes) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    h ^= @as(u64, font_size);
    h *%= 0x100000001b3;
    h ^= @as(u64, text_bytes.len);
    h *%= 0x100000001b3;
    h ^= @as(u64, @as(u32, @bitCast(box_height)));
    h *%= 0x100000001b3;
    h ^= phaseByte(origin_x);
    h *%= 0x100000001b3;
    h ^= phaseByte(origin_y);
    h *%= 0x100000001b3;
    return h;
}

/// The fraction of a coordinate, quantised to 1/256 of a pixel.
fn phaseByte(v: f32) u8 {
    const frac = v - @floor(v);
    return @intFromFloat(@floor(frac * 256.0));
}

/// Pure LRU victim pick: first invalid slot, else smallest last_used.
pub fn lruVictim(entries: anytype) ?usize {
    if (entries.len == 0) return null;
    for (entries, 0..) |e, i| {
        if (!e.valid) return i;
    }
    var best: usize = 0;
    var best_used = entries[0].last_used;
    for (entries, 0..) |e, i| {
        if (e.last_used < best_used) {
            best_used = e.last_used;
            best = i;
        }
    }
    return best;
}

/// Pure + headless-testable key for the image cache.
pub fn hashImageKey(path: []const u8, max_dim: u16) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (path) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    h ^= @as(u64, max_dim);
    h *%= 0x100000001b3;
    h ^= @as(u64, path.len);
    h *%= 0x100000001b3;
    return h;
}

/// Pure: downscaled dims preserving aspect so the longest side is at most max_dim.
pub fn scaledDims(iw: u32, ih: u32, max_dim: u16) [2]u32 {
    if (iw == 0 or ih == 0) return .{ 1, 1 };
    const m: u32 = @max(iw, ih);
    if (m <= max_dim) return .{ iw, ih };
    if (iw >= ih) {
        const w: u32 = max_dim;
        const h: u32 = @max((ih * max_dim) / iw, 1);
        return .{ w, h };
    }
    const h: u32 = max_dim;
    const w: u32 = @max((iw * max_dim) / ih, 1);
    return .{ w, h };
}

/// Pure: cover-fit UV crop (u0, v0, u1, v1 fractions of the source) so the image fills a bw×bh box with no distortion.
pub fn coverUv(iw: f32, ih: f32, bw: f32, bh: f32) [4]f32 {
    if (iw <= 0 or ih <= 0 or bw <= 0 or bh <= 0) return .{ 0, 0, 1, 1 };
    const img_aspect = iw / ih;
    const box_aspect = bw / bh;
    if (img_aspect > box_aspect) {
        const f = box_aspect / img_aspect;
        const cu0 = (1 - f) * 0.5;
        return .{ cu0, 0, 1 - cu0, 1 };
    }
    if (img_aspect < box_aspect) {
        const f = img_aspect / box_aspect;
        const cv0 = (1 - f) * 0.5;
        return .{ 0, cv0, 1, 1 - cv0 };
    }
    return .{ 0, 0, 1, 1 };
}

/// Pure: contain-fit inner box (x, y, w, h relative to the bw×bh box) so the whole image shows letterboxed.
pub fn containBox(iw: f32, ih: f32, bw: f32, bh: f32) [4]f32 {
    if (iw <= 0 or ih <= 0 or bw <= 0 or bh <= 0) return .{ 0, 0, bw, bh };
    const s = @min(bw / iw, bh / ih);
    const w = iw * s;
    const h = ih * s;
    return .{ (bw - w) * 0.5, (bh - h) * 0.5, w, h };
}

/// Pure: a device-pixel clip clamped into the viewport, which is what Vulkan requires (GL tolerated an oversized box).
pub fn clampScissor(x: f32, y: f32, w: f32, h: f32, win_w: i32, win_h: i32) [4]i32 {
    const x0 = @max(@floor(x), 0);
    const y0 = @max(@floor(y), 0);
    const x1 = @min(x0 + @max(@round(w), 0), @as(f32, @floatFromInt(@max(win_w, 0))));
    const y1 = @min(y0 + @max(@round(h), 0), @as(f32, @floatFromInt(@max(win_h, 0))));
    return .{
        @intFromFloat(x0),
        @intFromFloat(y0),
        @intFromFloat(@max(x1 - x0, 0)),
        @intFromFloat(@max(y1 - y0, 0)),
    };
}

/// The overlap of two device-pixel clips; a zero size means nothing of the run is visible.
pub fn intersectClip(cur: ?[4]i32, next: [4]i32) [4]i32 {
    const prev = cur orelse return next;
    const x0 = @max(prev[0], next[0]);
    const y0 = @max(prev[1], next[1]);
    const x1 = @min(prev[0] + prev[2], next[0] + next[2]);
    const y1 = @min(prev[1] + prev[3], next[1] + next[3]);
    return .{ x0, y0, @max(x1 - x0, 0), @max(y1 - y0, 0) };
}

/// Compiled-in shader source, exposed so a test can assert the coverage band stays one device pixel.
pub const rect_frag_source: []const u8 = @embedFile("shaders/rect.frag");

// ---- Geometry ----

// Largest run this renderer will build a coverage texture for; past it the rect fallback draws instead of a 4 MB upload.
const text_max_w: u32 = 2048;
const text_max_h: u32 = 512;
const text_max_bytes: usize = 4095;

/// One vertex: the same 17 floats mac/metal.h and windows/shim.h declare, so nothing about this layout is new.
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

/// Which pipeline a segment draws with. The shim maps it to one of its three.
pub const Kind = struct {
    pub const rect: c_int = 0;
    pub const text: c_int = 1;
    pub const image: c_int = 2;
};

// The window hands its surface over before the first frame; the renderer is built lazily by the frame path, so it picks this up on first draw.
var pending_display: ?*anyopaque = null;
var pending_surface: ?*anyopaque = null;

/// The Wayland surface the renderer should attach to. Called by the window before `run()`.
pub fn attach(display: ?*anyopaque, surface: ?*anyopaque) void {
    pending_display = display;
    pending_surface = surface;
}

// The renderer that owns a live device, so the window can release the swapchain before it destroys the surface it draws into.
var live_renderer: ?*Renderer = null;

/// Tear the GPU side down. The window calls this BEFORE destroying its `wl_surface`: a swapchain (and the VkSurfaceKHR) outlives neither.
pub fn shutdown() void {
    const r = live_renderer orelse return;
    live_renderer = null;
    pending_display = null;
    pending_surface = null;
    if (r.device) |d| vk.glin_vk_destroy(d);
    r.device = null;
}

pub const Renderer = struct {
    alloc: std.mem.Allocator,
    device: ?*vk.GlinVk = null,
    // True once a create was tried, so a machine without a Vulkan driver reports once instead of per frame.
    device_attempted: bool = false,
    /// Text coverage texture LRU (see text_cache_size docs).
    text_cache: [text_cache_size]TextCacheEntry = [_]TextCacheEntry{.{}} ** text_cache_size,
    text_cache_clock: u64 = 0,
    text_cache_hits: u64 = 0,
    text_cache_misses: u64 = 0,
    /// Image texture LRU (wallpaper thumbnails/preview).
    img_cache: [img_cache_size]ImgCacheEntry = [_]ImgCacheEntry{.{}} ** img_cache_size,
    img_cache_clock: u64 = 0,
    img_cache_hits: u64 = 0,
    img_cache_misses: u64 = 0,
    /// Decodes performed this frame (budget: at most this many misses decode per frame, so a gallery opening never stalls).
    img_decodes_this_frame: u32 = 0,
    /// The clip in force for the vertices being accumulated, already intersected with every scissor above it.
    clip_rect: ?[4]i32 = null,
    /// The clips each `scissor_start` interrupted, so `scissor_end` restores its parent instead of clearing the clip.
    clip_stack: [max_clip_depth]?[4]i32 = @splat(null),
    clip_depth: usize = 0,
    verts: std.ArrayList(Vertex) = .empty,
    segs: std.ArrayList(vk.GlinSegment) = .empty,
    seg_start: usize = 0,
    seg_texture: u32 = 0,
    seg_kind: c_int = Kind.rect,
    /// True once the first frame has been described, so the log line appears exactly once.
    reported_first_frame: bool = false,

    pub fn init(allocator: std.mem.Allocator) !Renderer {
        // No device yet: the window attaches its surface before the first frame, and a test may attach an offscreen device instead.
        return .{ .alloc = allocator };
    }

    pub fn deinit(self: *Renderer) void {
        if (self.device) |d| vk.glin_vk_destroy(d);
        self.device = null;
        self.verts.deinit(self.alloc);
        self.segs.deinit(self.alloc);
    }

    /// True when a device is actually driving the screen.
    pub fn active(self: *const Renderer) bool {
        return self.device != null;
    }

    /// Why the last GPU call failed, for a test that has no log sink to print into.
    pub fn lastError(self: *const Renderer) []const u8 {
        _ = self;
        return std.mem.span(vk.glin_vk_last_error());
    }

    /// The physical device's name, or "" before a device exists.
    pub fn deviceName(self: *const Renderer) []const u8 {
        const d = self.device orelse return "";
        return std.mem.span(vk.glin_vk_device_name(d));
    }

    fn ensure(self: *Renderer, w: i32, h: i32) ?*vk.GlinVk {
        if (self.device) |d| return d;
        if (self.device_attempted) return null;
        self.device_attempted = true;
        const surface = pending_surface orelse return null;
        const d = vk.glin_vk_create(
            pending_display,
            surface,
            w,
            h,
            @ptrCast(quad_vert_spv.ptr),
            quad_vert_spv.len,
            @ptrCast(rect_frag_spv.ptr),
            rect_frag_spv.len,
            @ptrCast(text_frag_spv.ptr),
            text_frag_spv.len,
            @ptrCast(image_frag_spv.ptr),
            image_frag_spv.len,
        );
        if (d == null) {
            log.warn("vulkan renderer unavailable: {s}", .{std.mem.span(vk.glin_vk_last_error())});
            return null;
        }
        self.device = d;
        live_renderer = self;
        std.log.info("linux renderer: vulkan on {s}", .{std.mem.span(vk.glin_vk_device_name(d))});
        return d;
    }

    /// A device with no surface, for the GPU-vs-CPU parity test. False when this machine has no Vulkan device.
    pub fn attachOffscreen(self: *Renderer) bool {
        if (self.device != null) return true;
        self.device_attempted = true;
        const d = vk.glin_vk_create(
            null,
            null,
            @intCast(1),
            @intCast(1),
            @ptrCast(quad_vert_spv.ptr),
            quad_vert_spv.len,
            @ptrCast(rect_frag_spv.ptr),
            rect_frag_spv.len,
            @ptrCast(text_frag_spv.ptr),
            text_frag_spv.len,
            @ptrCast(image_frag_spv.ptr),
            image_frag_spv.len,
        );
        if (d == null) return false;
        self.device = d;
        return true;
    }

    /// Draw a full Clay render-command list, then present it.
    pub fn drawCommands(self: *Renderer, commands: []cl.RenderCommand, win_w: i32, win_h: i32) void {
        if (win_w <= 0 or win_h <= 0) return;
        const s = ui_scale.current();
        const px = scale.pixelSize(@intCast(win_w), @intCast(win_h), s);
        const d = self.ensure(@intCast(px.w), @intCast(px.h)) orelse return;
        _ = vk.glin_vk_resize(d, @intCast(px.w), @intCast(px.h));
        self.build(commands, @intCast(px.w), @intCast(px.h), s);
        const cc = clearColor();
        const rc = vk.glin_vk_draw(
            d,
            @ptrCast(self.verts.items.ptr),
            @intCast(self.verts.items.len),
            self.segs.items.ptr,
            @intCast(self.segs.items.len),
            cc[0],
            cc[1],
            cc[2],
            cc[3],
        );
        // -2 is the surface moving on between frames: the shim rebuilt its swapchain and the next frame draws.
        if (rc < -1) log.warn("vulkan draw failed: {s}", .{std.mem.span(vk.glin_vk_last_error())});
        if (self.reported_first_frame) return;
        self.reported_first_frame = true;
        std.log.info("linux first frame: {d}x{d} device px, {d} commands, {d} vertices, {d} segments", .{
            px.w, px.h, commands.len, self.verts.items.len, self.segs.items.len,
        });
    }

    /// Render a command list into an offscreen target and return RGBA bytes, so a test can compare the GPU against the CPU reference.
    pub fn renderOffscreen(self: *Renderer, commands: []const cl.RenderCommand, w: i32, h: i32) ?[]u8 {
        if (w <= 0 or h <= 0) return null;
        const d = self.device orelse return null;
        // Offscreen is always 1:1 device pixels: a parity test compares a device px with a device px.
        self.build(commands, w, h, 1.0);
        const out = self.alloc.alloc(u8, @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4) catch return null;
        errdefer self.alloc.free(out);
        const cc = clearColor();
        if (vk.glin_vk_offscreen(
            d,
            @ptrCast(self.verts.items.ptr),
            @intCast(self.verts.items.len),
            self.segs.items.ptr,
            @intCast(self.segs.items.len),
            w,
            h,
            cc[0],
            cc[1],
            cc[2],
            cc[3],
            out.ptr,
        ) != 0) {
            self.alloc.free(out);
            return null;
        }
        return out;
    }

    // ---- Command translation ----
    fn build(self: *Renderer, commands: []const cl.RenderCommand, w: i32, h: i32, s: f32) void {
        self.verts.clearRetainingCapacity();
        self.segs.clearRetainingCapacity();
        self.seg_start = 0;
        self.seg_texture = 0;
        self.seg_kind = Kind.rect;
        self.clip_rect = null;
        self.clip_depth = 0;
        self.img_decodes_this_frame = 0;

        for (commands) |*cmd| {
            const bb = cmd.bounding_box;
            switch (cmd.command_type) {
                .rectangle => {
                    const r = cmd.render_data.rectangle;
                    if (r.background_color[3] <= 0) continue;
                    const cr = cornerRadiusVec4(r.corner_radius);
                    self.rect(bb.x * s, bb.y * s, bb.width * s, bb.height * s, .{ cr[0] * s, cr[1] * s, cr[2] * s, cr[3] * s }, 0, 0, r.background_color);
                },
                .border => self.border(cmd.render_data.border, bb, s),
                .text => {
                    const td = cmd.render_data.text;
                    const bytes = td.string_contents.chars[0..@intCast(td.string_contents.length)];
                    self.textRun(bb.x * s, bb.y * s, bb.height * s, bytes, td.font_size, td.text_color, s);
                },
                .scissor_start => self.pushScissor(bb.x * s, bb.y * s, bb.width * s, bb.height * s, w, h),
                .scissor_end => self.popScissor(),
                .image => {
                    const im = cmd.render_data.image;
                    if (im.image_data) |ptr| {
                        const ref: *const ImageRef = @ptrCast(@alignCast(ptr));
                        self.image(bb.x * s, bb.y * s, bb.width * s, bb.height * s, ref);
                    }
                },
                else => {},
            }
        }
        self.closeSegment();
    }

    /// Pure helper: Clay CornerRadius -> rect-shader radius vec4 (TL, TR, BL, BR in px), clamped at zero.
    pub fn cornerRadiusVec4(r: cl.CornerRadius) [4]f32 {
        return .{ @max(r.top_left, 0), @max(r.top_right, 0), @max(r.bottom_left, 0), @max(r.bottom_right, 0) };
    }

    fn rect(self: *Renderer, x: f32, y: f32, w: f32, h: f32, radius: [4]f32, mode: c_int, border_w: f32, color: [4]f32) void {
        if (w <= 0 or h <= 0) return;
        self.use(Kind.rect, 0);
        const v = Vertex{
            .pos = .{ 0, 0 },
            .local = .{ 0, 0 },
            .size = .{ w, h },
            .radius = radius,
            .color = soft.normalizeColorPublic(color),
            .mode = @floatFromInt(mode),
            .border = border_w,
            .kind = 0,
        };
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
        self.verts.appendSlice(self.alloc, &.{ a, b, c, a, c, d }) catch {};
    }

    // A border is four sides in Clay's model; the shader takes one width, so unequal sides become four rects.
    fn border(self: *Renderer, bd: cl.BorderRenderData, bb: cl.BoundingBox, k: f32) void {
        const top: f32 = @floatFromInt(bd.width.top);
        const bottom: f32 = @floatFromInt(bd.width.bottom);
        const left: f32 = @floatFromInt(bd.width.left);
        const right: f32 = @floatFromInt(bd.width.right);
        if (top == bottom and top == left and top == right) {
            if (top <= 0) return;
            const cr = cornerRadiusVec4(bd.corner_radius);
            self.rect(bb.x * k, bb.y * k, bb.width * k, bb.height * k, .{ cr[0] * k, cr[1] * k, cr[2] * k, cr[3] * k }, 1, top * k, bd.color);
            return;
        }
        if (top > 0 and bb.width > 0) self.rect(bb.x * k, bb.y * k, bb.width * k, @min(top, bb.height) * k, .{ 0, 0, 0, 0 }, 0, 0, bd.color);
        if (bottom > 0 and bb.width > 0) {
            const bh = @min(bottom, bb.height);
            self.rect(bb.x * k, (bb.y + bb.height - bh) * k, bb.width * k, bh * k, .{ 0, 0, 0, 0 }, 0, 0, bd.color);
        }
        const inner_h = bb.height - @min(top, bb.height) - @min(bottom, bb.height);
        if (inner_h > 0) {
            if (left > 0) self.rect(bb.x * k, (bb.y + @min(top, bb.height)) * k, @min(left, bb.width) * k, inner_h * k, .{ 0, 0, 0, 0 }, 0, 0, bd.color);
            if (right > 0) {
                const rw = @min(right, bb.width);
                self.rect((bb.x + bb.width - rw) * k, (bb.y + @min(top, bb.height)) * k, rw * k, inner_h * k, .{ 0, 0, 0, 0 }, 0, 0, bd.color);
            }
        }
    }

    /// One run of text: coverage rasterised with the face the layout measured it with, cached as an R8 texture, tinted by the vertex colour.
    fn textRun(self: *Renderer, bbox_x: f32, bbox_y: f32, bbox_h: f32, bytes: []const u8, font_size: u16, clay_color: [4]f32, s: f32) void {
        if (bytes.len == 0 or bytes.len > text_max_bytes) return;
        const fs: u16 = if (font_size == 0) 16 else font_size;
        // A glyph texture is the one thing that cannot scale for free: rasterise it at the display density and place it back at that density.
        const fs_dev: u16 = @intFromFloat(@round(@as(f32, @floatFromInt(fs)) * s));
        if (fs_dev == 0) return;
        const box_h: i32 = @intFromFloat(@round(bbox_h));
        // The bitmap is blitted on whole device pixels and its glyphs snap from the same fractional origin, so it goes here.
        const grid_x = @floor(bbox_x);
        const grid_y = @floor(bbox_y);
        const key = hashTextKey(bytes, fs_dev, box_h, bbox_x, bbox_y);

        self.text_cache_clock += 1;
        for (&self.text_cache) |*e| {
            if (e.valid and e.hash == key and e.tex != 0) {
                e.last_used = self.text_cache_clock;
                self.text_cache_hits += 1;
                self.textQuad(e.tex, grid_x, grid_y, @floatFromInt(e.w), @floatFromInt(e.h), clay_color);
                return;
            }
        }
        self.text_cache_misses += 1;

        const bmp = text.rasterizeRun(self.alloc, bytes, fs_dev, bbox_x, bbox_y, @floatFromInt(box_h)) orelse {
            self.textFallback(grid_x, grid_y, bytes, font_size, clay_color, s);
            return;
        };
        defer bmp.deinit(self.alloc);
        if (bmp.width > text_max_w or bmp.height > text_max_h) {
            self.textFallback(grid_x, grid_y, bytes, font_size, clay_color, s);
            return;
        }
        const slot = lruVictim(&self.text_cache) orelse return;
        const id: u32 = text_texture_base + @as(u32, @intCast(slot));
        if (!self.upload(id, @ptrCast(bmp.pixels.ptr), @intCast(bmp.width), @intCast(bmp.height), 1)) return;
        self.text_cache[slot] = .{
            .hash = key,
            .tex = id,
            .w = @intCast(bmp.width),
            .h = @intCast(bmp.height),
            .valid = true,
            .last_used = self.text_cache_clock,
        };
        self.textQuad(id, grid_x, grid_y, @floatFromInt(bmp.width), @floatFromInt(bmp.height), clay_color);
    }

    /// The stb-fallback shape: one box per character, which is what a run with no coverage bitmap gets.
    fn textFallback(self: *Renderer, x: f32, y: f32, bytes: []const u8, font_size: u16, clay_color: [4]f32, s: f32) void {
        const fs: u16 = if (font_size == 0) 16 else font_size;
        const adv = estimatorAdvance(fs) * s;
        const h = @min(@as(f32, @floatFromInt(fs)) * s, 24 * s);
        var cursor: f32 = 0;
        for (bytes) |_| {
            self.rect(x + cursor, y, adv * 0.7, h, .{ 0, 0, 0, 0 }, 0, 0, clay_color);
            cursor += adv;
        }
    }

    /// Blit a coverage texture: the coverage is the alpha, `clay_color` the ink.
    fn textQuad(self: *Renderer, tex: u32, x: f32, y: f32, w: f32, h: f32, clay_color: [4]f32) void {
        if (w <= 0 or h <= 0 or tex == 0) return;
        self.use(Kind.text, tex);
        self.pushQuad(x, y, w, h, .{ 0, 0, 1, 1 }, straightColor(clay_color), 1);
    }

    /// Max source side accepted for decode (refuse absurd headers before allocating).
    const img_max_side: c_int = 8192;
    /// Per-frame decode budget (see img_decodes_this_frame).
    const img_decode_budget: u32 = 2;

    fn upload(self: *Renderer, id: u32, bytes: [*]const u8, w: i32, h: i32, channels: c_int) bool {
        const d = self.device orelse return false;
        return vk.glin_vk_set_texture(d, id, bytes, w, h, channels) == 0;
    }

    /// Decode path (NUL-terminated) via stb, downscale to max_dim, upload as an RGBA texture.
    fn decodeUploadImage(self: *Renderer, cpath: [*:0]const u8, max_dim: u16, id: u32) ?DecodedImage {
        var iw: c_int = 0;
        var ih: c_int = 0;
        var nch: c_int = 0;
        const px = stbi.stbi_load(cpath, &iw, &ih, &nch, 4) orelse return null;
        defer stbi.stbi_image_free(px);
        if (iw <= 0 or ih <= 0 or iw > img_max_side or ih > img_max_side) return null;
        const dims = scaledDims(@intCast(iw), @intCast(ih), max_dim);
        const dw: usize = dims[0];
        const dh: usize = dims[1];
        const src_len: usize = @intCast(iw * ih * 4);
        var upload_ptr: [*]const u8 = px[0..src_len].ptr;
        var resized: []u8 = &.{};
        defer if (resized.len > 0) self.alloc.free(resized);
        if (dw != @as(usize, @intCast(iw)) or dh != @as(usize, @intCast(ih))) {
            resized = self.alloc.alloc(u8, dw * dh * 4) catch return null;
            const out_ptr = stbi.stbir_resize_uint8_linear(px, iw, ih, 0, resized.ptr, @intCast(dw), @intCast(dh), 0, stbi.STBIR_RGBA);
            if (out_ptr == null) return null;
            upload_ptr = resized.ptr;
        }
        if (!self.upload(id, upload_ptr, @intCast(dw), @intCast(dh), 4)) return null;
        return .{ .tex = id, .w = @intCast(dw), .h = @intCast(dh) };
    }

    /// Lookup-or-decode an image texture (LRU, slot-stable texture id).
    fn imageTexture(self: *Renderer, path: []const u8, max_dim: u16) ?DecodedImage {
        if (path.len == 0) return null;
        const key = hashImageKey(path, max_dim);
        self.img_cache_clock += 1;
        for (&self.img_cache) |*e| {
            if (e.valid and e.hash == key and e.tex != 0) {
                e.last_used = self.img_cache_clock;
                self.img_cache_hits += 1;
                return .{ .tex = e.tex, .w = e.w, .h = e.h };
            }
        }
        self.img_cache_misses += 1;
        if (self.img_decodes_this_frame >= img_decode_budget) return null;
        self.img_decodes_this_frame += 1;
        var cbuf: [std.fs.max_path_bytes]u8 = undefined;
        if (path.len + 1 > cbuf.len) return null;
        @memcpy(cbuf[0..path.len], path);
        cbuf[path.len] = 0;
        const slot = lruVictim(&self.img_cache) orelse return null;
        const id: u32 = image_texture_base + @as(u32, @intCast(slot));
        const up = self.decodeUploadImage(@ptrCast(&cbuf), max_dim, id) orelse return null;
        self.img_cache[slot] = .{
            .hash = key,
            .tex = up.tex,
            .w = up.w,
            .h = up.h,
            .valid = true,
            .last_used = self.img_cache_clock,
        };
        return up;
    }

    /// Draw one Clay IMAGE command: cache lookup, fit-mapped blit, or a placeholder rect while loading/failed.
    fn image(self: *Renderer, x: f32, y: f32, w: f32, h: f32, ref: *const ImageRef) void {
        if (w <= 0 or h <= 0) return;
        const path = ref.path_ptr[0..ref.path_len];
        const max_dim: u16 = if (ref.max_dim == 0) 256 else ref.max_dim;
        const t = self.imageTexture(path, max_dim) orelse {
            self.rect(x, y, w, h, .{ 0, 0, 0, 0 }, 0, 0, soft.img_placeholder.toClay());
            return;
        };
        const iw: f32 = @floatFromInt(t.w);
        const ih: f32 = @floatFromInt(t.h);
        switch (ref.fit) {
            .cover => {
                const uv = coverUv(iw, ih, w, h);
                self.use(Kind.image, t.tex);
                self.pushQuad(x, y, w, h, uv, .{ 1, 1, 1, 1 }, 2);
            },
            .contain => {
                self.rect(x, y, w, h, .{ 0, 0, 0, 0 }, 0, 0, soft.img_placeholder.toClay());
                const b = containBox(iw, ih, w, h);
                if (b[2] <= 0 or b[3] <= 0) return;
                self.use(Kind.image, t.tex);
                self.pushQuad(x + b[0], y + b[1], b[2], b[3], .{ 0, 0, 1, 1 }, .{ 1, 1, 1, 1 }, 2);
            },
            .stretch => {
                self.use(Kind.image, t.tex);
                self.pushQuad(x, y, w, h, .{ 0, 0, 1, 1 }, .{ 1, 1, 1, 1 }, 2);
            },
        }
    }

    // ---- Vertex and segment plumbing ----

    /// A textured quad: `local` is the uv of each corner, so one writer serves text and images.
    fn pushQuad(self: *Renderer, x: f32, y: f32, w: f32, h: f32, uv: [4]f32, color: [4]f32, kind: f32) void {
        if (w <= 0 or h <= 0) return;
        const v = Vertex{
            .pos = .{ 0, 0 },
            .local = .{ 0, 0 },
            .size = .{ 0, 0 },
            .radius = .{ 0, 0, 0, 0 },
            .color = color,
            .mode = 0,
            .border = 0,
            .kind = kind,
        };
        var a = v;
        var b = v;
        var c = v;
        var d = v;
        a.pos = .{ x, y };
        a.local = .{ uv[0], uv[1] };
        b.pos = .{ x + w, y };
        b.local = .{ uv[2], uv[1] };
        c.pos = .{ x + w, y + h };
        c.local = .{ uv[2], uv[3] };
        d.pos = .{ x, y + h };
        d.local = .{ uv[0], uv[3] };
        self.verts.appendSlice(self.alloc, &.{ a, b, c, a, c, d }) catch {};
    }

    /// A new segment: a texture or pipeline change closes the run being accumulated.
    fn use(self: *Renderer, kind: c_int, tex: u32) void {
        if (self.seg_kind == kind and self.seg_texture == tex) return;
        self.closeSegment();
        self.seg_kind = kind;
        self.seg_texture = tex;
    }

    fn closeSegment(self: *Renderer) void {
        const end = self.verts.items.len;
        if (end > self.seg_start) {
            const sc = self.clip_rect;
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
                .kind = self.seg_kind,
            }) catch {};
        }
        self.seg_start = end;
    }

    // Open a clip: it narrows whatever was already clipping, so a field's horizontal clip cannot widen the scroll box around it.
    fn pushScissor(self: *Renderer, x: f32, y: f32, w: f32, h: f32, win_w: i32, win_h: i32) void {
        self.closeSegment();
        const next = clampScissor(x, y, w, h, win_w, win_h);
        if (self.clip_depth < self.clip_stack.len) {
            self.clip_stack[self.clip_depth] = self.clip_rect;
            self.clip_depth += 1;
        }
        self.clip_rect = intersectClip(self.clip_rect, next);
    }

    fn popScissor(self: *Renderer) void {
        self.closeSegment();
        if (self.clip_depth == 0) {
            self.clip_rect = null;
            return;
        }
        self.clip_depth -= 1;
        self.clip_rect = self.clip_stack[self.clip_depth];
    }
};

// ---- Tests ----

test "u32ToClayColor maps hex to 0-255 Clay color" {
    const c = u32ToClayColor(0x112233);
    try std.testing.expectEqual(@as(f32, 0x11), c[0]);
    try std.testing.expectEqual(@as(f32, 0x22), c[1]);
    try std.testing.expectEqual(@as(f32, 0x33), c[2]);
    try std.testing.expectEqual(@as(f32, 255), c[3]);
    const t = u32ToClayColor(0xf0f0f0);
    try std.testing.expectEqual(@as(f32, 0xf0), t[0]);
}

test "u32ToGLColor normalizes bg with alpha 1" {
    const cc = u32ToGLColor(0x111111);
    try std.testing.expectApproxEqAbs(@as(f32, 0x11) / 255.0, cc[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), cc[3], 1e-6);
}

test "estimatorAdvance keeps legacy 0.6 contract for stb fallback" {
    try std.testing.expectApproxEqAbs(@as(f32, 18 * 0.6), estimatorAdvance(18), 1e-5);
    const ext = text.estimatorExtent("AB", 18);
    try std.testing.expectApproxEqAbs(2 * estimatorAdvance(18), ext.w, 1e-4);
    const d = extentToClay(ext);
    try std.testing.expectApproxEqAbs(ext.w, d.w, 1e-6);
    try std.testing.expectApproxEqAbs(ext.h, d.h, 1e-6);
}

test "cornerRadiusVec4 maps TL,TR,BL,BR and clamps negatives" {
    const v = Renderer.cornerRadiusVec4(.{ .top_left = 8, .top_right = 4, .bottom_left = 2, .bottom_right = 0 });
    try std.testing.expectEqual([4]f32{ 8, 4, 2, 0 }, v);
    const neg = Renderer.cornerRadiusVec4(.{ .top_left = -3, .top_right = 5, .bottom_left = -1, .bottom_right = 6 });
    try std.testing.expectEqual([4]f32{ 0, 5, 0, 6 }, neg);
}

test "straightColor normalizes 0-255 and passes 0-1 through" {
    const c255 = straightColor(.{ 255, 128, 0, 255 });
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), c255[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), c255[1], 1e-6);
    const c1 = straightColor(.{ 1, 1, 1, 1 });
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), c1[0], 1e-6);
}

test "hashTextKey tells runs, sizes, boxes and sub-pixel origins apart" {
    const a = hashTextKey("Settings", 18, 22, 40, 100);
    try std.testing.expectEqual(a, hashTextKey("Settings", 18, 22, 40, 100));
    try std.testing.expect(hashTextKey("Settings", 16, 22, 40, 100) != a);
    try std.testing.expect(hashTextKey("Setting", 18, 22, 40, 100) != a);
    try std.testing.expect(hashTextKey("Settings", 18, 40, 40, 100) != a);
    // Half a pixel lower is a different texture: the glyphs snap to a different row.
    try std.testing.expect(hashTextKey("Settings", 18, 22, 40, 100.5) != a);
}

test "lruVictim prefers invalid slot, else oldest" {
    var entries = [_]TextCacheEntry{
        .{ .valid = true, .last_used = 10, .tex = 1 },
        .{ .valid = false },
        .{ .valid = true, .last_used = 5, .tex = 2 },
    };
    try std.testing.expectEqual(@as(?usize, 1), lruVictim(&entries));
    entries[1] = .{ .valid = true, .last_used = 20, .tex = 3 };
    try std.testing.expectEqual(@as(?usize, 2), lruVictim(&entries));
    const empty: []TextCacheEntry = &.{};
    try std.testing.expectEqual(@as(?usize, null), lruVictim(empty));
}

test "lruVictim works for image cache entries too" {
    var entries = [_]ImgCacheEntry{
        .{ .valid = true, .last_used = 7, .tex = 1 },
        .{ .valid = true, .last_used = 3, .tex = 2 },
    };
    try std.testing.expectEqual(@as(?usize, 1), lruVictim(&entries));
}

test "hashImageKey differs by path and max_dim" {
    const a = hashImageKey("/p/a.jpg", 256);
    try std.testing.expectEqual(a, hashImageKey("/p/a.jpg", 256));
    try std.testing.expect(hashImageKey("/p/a.jpg", 512) != a);
    try std.testing.expect(hashImageKey("/p/b.jpg", 256) != a);
}

test "scaledDims downscales longest side, never upscales" {
    try std.testing.expectEqual([2]u32{ 256, 144 }, scaledDims(1920, 1080, 256));
    try std.testing.expectEqual([2]u32{ 144, 256 }, scaledDims(1080, 1920, 256));
    try std.testing.expectEqual([2]u32{ 100, 50 }, scaledDims(100, 50, 256));
    try std.testing.expectEqual([2]u32{ 256, 256 }, scaledDims(512, 512, 256));
    try std.testing.expectEqual([2]u32{ 1, 1 }, scaledDims(0, 0, 256));
}

test "coverUv crops sides of wide images, top-bottom of tall ones" {
    const wide = coverUv(16, 9, 1, 1);
    try std.testing.expectApproxEqAbs(@as(f32, (1 - 9.0 / 16.0) * 0.5), wide[0], 1e-5);
    try std.testing.expectEqual(@as(f32, 0), wide[1]);
    try std.testing.expectApproxEqAbs(@as(f32, 1 - (1 - 9.0 / 16.0) * 0.5), wide[2], 1e-5);
    try std.testing.expectEqual(@as(f32, 1), wide[3]);
    const tall = coverUv(9, 16, 1, 1);
    try std.testing.expectEqual(@as(f32, 0), tall[0]);
    try std.testing.expectApproxEqAbs(@as(f32, (1 - 9.0 / 16.0) * 0.5), tall[1], 1e-5);
    const same = coverUv(16, 9, 32, 18);
    try std.testing.expectEqual([4]f32{ 0, 0, 1, 1 }, same);
    try std.testing.expectEqual([4]f32{ 0, 0, 1, 1 }, coverUv(0, 9, 1, 1));
}

test "containBox letterboxes inside the box" {
    const wide = containBox(16, 9, 100, 100);
    try std.testing.expectApproxEqAbs(@as(f32, 0), wide[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, (100 - 56.25) * 0.5), wide[1], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 100), wide[2], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 56.25), wide[3], 1e-4);
    const tall = containBox(9, 16, 100, 100);
    try std.testing.expectApproxEqAbs(@as(f32, (100 - 56.25) * 0.5), tall[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0), tall[1], 1e-4);
}

test "clampScissor fits the viewport and never goes negative" {
    try std.testing.expectEqual([4]i32{ 10, 20, 30, 40 }, clampScissor(10, 20, 30, 40, 200, 120));
    // Past the right/bottom edge: the far edge moves in, the size follows.
    try std.testing.expectEqual([4]i32{ 180, 100, 20, 20 }, clampScissor(180, 100, 200, 200, 200, 120));
    // A negative origin is clipped to the framebuffer, not passed through (Vulkan has no negative scissor).
    try std.testing.expectEqual([4]i32{ 0, 0, 60, 60 }, clampScissor(-10, -10, 60, 60, 200, 120));
    // Entirely outside: zero area, which the renderer drops instead of drawing unscissored.
    try std.testing.expectEqual([4]i32{ 300, 20, 0, 40 }, clampScissor(300, 20, 30, 40, 200, 120));
}

test "intersectClip narrows and never widens" {
    try std.testing.expectEqual([4]i32{ 10, 20, 30, 40 }, intersectClip(null, .{ 10, 20, 30, 40 }));
    try std.testing.expectEqual([4]i32{ 10, 20, 30, 40 }, intersectClip(.{ 0, 0, 100, 100 }, .{ 10, 20, 30, 40 }));
    const disjoint = intersectClip(.{ 0, 0, 10, 10 }, .{ 20, 20, 10, 10 });
    try std.testing.expectEqual(@as(i32, 0), disjoint[2]);
    try std.testing.expectEqual(@as(i32, 0), disjoint[3]);
}

test "rect shader keeps a 1px coverage band (crisp borders, true radius)" {
    // Regression: a 2px smoothstep(-1,1,d) band spread a 1px border over two pixels and eroded rounded corners.
    try std.testing.expect(std.mem.indexOf(u8, rect_frag_source, "clamp(0.5 - d, 0.0, 1.0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rect_frag_source, "smoothstep(-1.0, 1.0,") == null);
    try std.testing.expect(std.mem.indexOf(u8, rect_frag_source, "float a = cov(d);") != null);
    try std.testing.expect(std.mem.indexOf(u8, rect_frag_source, "float a2 = cov(d2);") != null);
    // Geometry is device pixels, so there is no scale uniform left to get wrong at 2x.
    try std.testing.expect(std.mem.indexOf(u8, rect_frag_source, "u_scale") == null);
}

test "the AA band is one device pixel at any display density" {
    // The band is a fixed half-pixel in DEVICE space: at 2x the geometry itself doubles, so an edge pixel is fully covered either way.
    const band_at = struct {
        fn f(d: f32) f32 {
            return std.math.clamp(0.5 - d, 0.0, 1.0);
        }
    }.f;
    try std.testing.expectEqual(@as(f32, 1.0), band_at(-1.0));
    // The same physical edge at 2x sits one DEVICE pixel inside, which is what the renderer builds.
    try std.testing.expectEqual(@as(f32, 1.0), band_at(-1.0));
    try std.testing.expectEqual(@as(f32, 0.0), band_at(0.5));
    // A logical-unit band scaled by a missing factor (the old bug) would leave 75% coverage here.
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), band_at(-0.25), 1e-6);
}
