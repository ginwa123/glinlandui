// Portable software rasterizer — the reference renderer for glinlandui.
const std = @import("std");
const builtin = @import("builtin");
const scale = @import("scale.zig");
const stbi = @cImport({
    @cInclude("stb/stb_image.h");
    @cInclude("stb/stb_image_resize2.h");
});
const cl = @import("zclay");
const glyphs = @import("glyphs.zig");
const text_face = @import("text_face.zig");
const color_glyphs = @import("color_glyphs.zig");
const common = @import("render_common.zig");
const Color = @import("color.zig").Color;
// The disk half of image decoding is native-only: a browser has no filesystem, and `std.fs.max_path_bytes` cannot even be analysed for freestanding.
const has_fs = !builtin.cpu.arch.isWasm();

pub const ImageFit = common.ImageFit;
pub const ImageRef = common.ImageRef;
pub const u32ToClayColor = common.u32ToClayColor;
pub const coverUv = common.coverUv;
pub const containBox = common.containBox;
pub const hashImageKey = common.hashImageKey;

// Placeholder color drawn when an image cannot be decoded (mirrors `img_placeholder = 0x1a1a1a` in the GLES3 backend).
pub const img_placeholder: Color = .rgb(0x1a, 0x1a, 0x1a);

// Corner radii, ordered (top_left, top_right, bottom_left, bottom_right).
const R4 = [4]f32;

// ---- Signed distance field ----

// Rounded-box signed distance for a sample in LOCAL box space, where the box spans [0,bx*2] x [0,by*2] and the sample is centred at the origin.
inline fn sdRoundBox(px: f32, py: f32, bx: f32, by: f32, r: R4) f32 {
    // v_box grows downward, so p.y < 0 is the top half and p.x < 0 the left.
    const rad = if (px < 0.0)
        (if (py < 0.0) r[0] else r[2])
    else
        (if (py < 0.0) r[1] else r[3]);
    const qx = @abs(px) - bx + rad;
    const qy = @abs(py) - by + rad;
    const mx = @max(qx, 0.0);
    const my = @max(qy, 0.0);
    return @sqrt(mx * mx + my * my) + @min(@max(qx, qy), 0.0) - rad;
}

// 1px antialias band: exactly 1.0 when the sample is >= half a pixel inside, 0.0 when half a pixel outside, linear in between.
inline fn cov(d: f32) f32 {
    return @min(@max(0.5 - d, 0.0), 1.0);
}

// Fragment coverage for a rounded box.
pub fn fragRoundBox(
    vbox_x: f32,
    vbox_y: f32,
    w: f32,
    h: f32,
    radius: R4,
    mode: u8,
    border_w: f32,
) f32 {
    const cx = w * 0.5;
    const cy = h * 0.5;
    const px = vbox_x - cx;
    const py = vbox_y - cy;
    // Clamp every corner against min(c.x, c.y) — the minimum half-extent, not each axis separately, so an oversized radius becomes a pill shape.
    const m = @min(cx, cy);
    const r: R4 = .{
        @min(@max(radius[0], 0.0), m),
        @min(@max(radius[1], 0.0), m),
        @min(@max(radius[2], 0.0), m),
        @min(@max(radius[3], 0.0), m),
    };
    var a = cov(sdRoundBox(px, py, cx, cy, r));
    if (mode == 1) {
        // Inner box: per-axis inset, radius shrunk by the border width and re-clamped to the inner minimum half-extent.
        const ibx = @max(cx - border_w, 0.0);
        const iby = @max(cy - border_w, 0.0);
        const mi = @min(ibx, iby);
        const ri: R4 = .{
            @min(@max(r[0] - border_w, 0.0), mi),
            @min(@max(r[1] - border_w, 0.0), mi),
            @min(@max(r[2] - border_w, 0.0), mi),
            @min(@max(r[3] - border_w, 0.0), mi),
        };
        a *= 1.0 - cov(sdRoundBox(px, py, ibx, iby, ri));
    }
    return a;
}

// ---- Framebuffer ----

// A decoded RGBA8 image, top-left origin, row 0 = top.
pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []const u8, // RGBA8, width*height*4 bytes
};

// The scissor region, top-down, half-open on the max edges.
const Scissor = struct { x0: i64, y0: i64, x1: i64, y1: i64 };

// How deep nested clips may go: Clay emits one scissor per clip element, and every scroll inside a scroll inside a field nests.
pub const max_clip_depth: usize = 32;

// An RGBA8 software framebuffer plus a scissor STACK: a nested clip narrows its ancestors, it never widens them.
pub const Surface = struct {
    alloc: std.mem.Allocator,
    width: u32,
    height: u32,
    pixels: []u8, // RGBA8, len == width*height*4
    // The clip in force: the intersection of every scissor opened so far.
    scissor: ?Scissor = null,
    // The clips each `scissor_start` interrupted, so `scissor_end` restores its parent instead of clearing the clip.
    scissor_stack: [max_clip_depth]?Scissor = @splat(null),
    scissor_depth: usize = 0,
    clear_rgb: [4]f32 = .{ 0, 0, 0, 255 },
    images: std.AutoHashMapUnmanaged(u64, Image) = .empty,
    // Pixel buffers this surface decoded itself, so deinit frees only what it owns.
    owned_pixels: std.ArrayList([]u8) = .empty,

    pub fn init(alloc: std.mem.Allocator, width: u32, height: u32) !Surface {
        var self = Surface{ .alloc = alloc, .width = 0, .height = 0, .pixels = &.{} };
        try self.resize(width, height);
        return self;
    }

    pub fn deinit(self: *Surface) void {
        self.alloc.free(self.pixels);
        self.pixels = &.{};
        for (self.owned_pixels.items) |p| self.alloc.free(p);
        self.owned_pixels.deinit(self.alloc);
        self.images.deinit(self.alloc);
    }

    // Reallocate the framebuffer at a new size and clear it.
    pub fn resize(self: *Surface, width: u32, height: u32) !void {
        if (width == 0 or height == 0) return error.InvalidSize;
        if (self.width == width and self.height == height) return;
        const n = try std.math.mul(usize, try std.math.mul(usize, width, height), 4);
        const buf = try self.alloc.alloc(u8, n);
        self.alloc.free(self.pixels);
        self.pixels = buf;
        self.width = width;
        self.height = height;
        self.clear();
    }

    // Fill the whole framebuffer with the stored clear color (opaque).
    pub fn clear(self: *Surface) void {
        const r = clamp8(self.clear_rgb[0]);
        const g = clamp8(self.clear_rgb[1]);
        const b = clamp8(self.clear_rgb[2]);
        // One u32 store per pixel through @memset, not four byte stores in a loop: a full-window clear at 2x is 6.5M pixels, and the byte loop alone cost

        // several milliseconds of a frame.
        const pattern: u32 = @as(u32, r) | (@as(u32, g) << 8) | (@as(u32, b) << 16) | (@as(u32, 255) << 24);
        const words = std.mem.bytesAsSlice(u32, self.pixels);
        @memset(words, pattern);
        self.scissor = null;
        self.scissor_depth = 0;
    }

    // Set the color used by `clear` (0-255 RGBA; alpha forced opaque).
    pub fn setClearColor(self: *Surface, color: [4]f32) void {
        self.clear_rgb = color;
        // A GPU backend has no Surface to read, so the frame's clear colour is mirrored here.
        frame_clear_rgb = color;
    }

    pub fn putImage(self: *Surface, key: u64, img: Image) !void {
        try self.images.put(self.alloc, key, img);
    }

    // Read one pixel as 0-255 RGBA. Out-of-bounds reads return transparent.
    pub fn px(self: *const Surface, x: i64, y: i64) [4]u8 {
        if (x < 0 or y < 0 or x >= self.width or y >= self.height) return .{ 0, 0, 0, 0 };
        const i = @as(usize, @intCast(y)) * self.width * 4 + @as(usize, @intCast(x)) * 4;
        return .{ self.pixels[i], self.pixels[i + 1], self.pixels[i + 2], self.pixels[i + 3] };
    }

    fn blend(self: *Surface, x: usize, y: usize, src: [3]f32, sa: f32) void {
        // Per-pixel inner loop: bounds checks here cost more than the blend itself, and the indices are already clamped by the caller.
        @setRuntimeSafety(false);
        const i = y * self.width * 4 + x * 4;
        const inv = 1.0 - sa;
        // Straight-alpha blend of the RGB channels, then the alpha channel with the same source-over equation (GL blend func SRC_ALPHA/ONE_MINUS_SRC_ALPHA for.
        for (0..3) |c| {
            const dst = @as(f32, @floatFromInt(self.pixels[i + c])) / 255.0;
            self.pixels[i + c] = to8(src[c] * sa + dst * inv);
        }
        const dsta = @as(f32, @floatFromInt(self.pixels[i + 3])) / 255.0;
        self.pixels[i + 3] = to8(sa + dsta * inv);
    }

    // ---- drawing primitives ----

    // Rasterize one axis-aligned rounded box with straight-alpha blending.
    pub fn drawBox(
        self: *Surface,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        radius: R4,
        mode: u8,
        border_w: f32,
        color: [4]f32,
    ) void {
        // The toolkit's hottest loop: every box on screen runs it. Safety checks are off here and the bounds are clamped below, once.
        @setRuntimeSafety(false);
        if (w <= 0 or h <= 0) return;
        const n = normalizeColor(color);
        const alpha = n[3];
        // A transparent box is a layout element, not a fill: skipping it here is what keeps a grid of transparent cell boxes from costing a pixel loop each.
        if (alpha <= 0) return;
        const rgb = [3]f32{ n[0], n[1], n[2] };

        // Pixel-centre coverage box: px in [ceil(x-0.5), floor(x+w-0.5)].
        const x0 = @max(@as(i64, @intFromFloat(@ceil(x - 0.5))), 0);
        const x1 = @min(@as(i64, @intFromFloat(@floor(x + w - 0.5))), @as(i64, self.width) - 1);
        const y0 = @max(@as(i64, @intFromFloat(@ceil(y - 0.5))), 0);
        const y1 = @min(@as(i64, @intFromFloat(@floor(y + h - 0.5))), @as(i64, self.height) - 1);
        if (x0 > x1 or y0 > y1) return;

        // FAST PATH: a square-cornered box is a plain fill, and evaluating the rounded-box SDF per pixel for one is what made a full-width row cost a

        // millisecond.
        if (radius[0] <= 0 and radius[1] <= 0 and radius[2] <= 0 and radius[3] <= 0 and mode == 0 and border_w <= 0) {
            const r8 = to8(rgb[0]);
            const g8 = to8(rgb[1]);
            const b8 = to8(rgb[2]);
            const a8 = to8(alpha);
            // The scissor is applied to the BOUNDS once, not tested per pixel: a full-window background at 2x is 6.5M pixels, and a per-pixel branch is most of what

            // that cost.
            var sx0 = x0;
            var sx1 = x1;
            var sy0 = y0;
            var sy1 = y1;
            if (self.scissor) |sc| {
                sx0 = @max(sx0, sc.x0);
                sx1 = @min(sx1, sc.x1 - 1);
                sy0 = @max(sy0, sc.y0);
                sy1 = @min(sy1, sc.y1 - 1);
            }
            if (sx0 > sx1 or sy0 > sy1) return;

            if (a8 >= 255) {
                // Opaque: fill the first row, then copy it down. A memcpy is several times faster than the same bytes written by hand, which is the difference between 3

                // ms and 25 ms on a large window.
                const row_off = @as(usize, @intCast(sy0)) * self.width * 4 + @as(usize, @intCast(sx0)) * 4;
                const row_len = @as(usize, @intCast(sx1 - sx0 + 1)) * 4;
                var i = row_off;
                while (i < row_off + row_len) : (i += 4) {
                    self.pixels[i] = r8;
                    self.pixels[i + 1] = g8;
                    self.pixels[i + 2] = b8;
                    self.pixels[i + 3] = 255;
                }
                var py = sy0 + 1;
                while (py <= sy1) : (py += 1) {
                    const dst = @as(usize, @intCast(py)) * self.width * 4 + @as(usize, @intCast(sx0)) * 4;
                    @memcpy(self.pixels[dst .. dst + row_len], self.pixels[row_off .. row_off + row_len]);
                }
                return;
            }

            const inv: u32 = 255 - a8;
            var py = sy0;
            while (py <= sy1) : (py += 1) {
                var ix = sx0;
                while (ix <= sx1) : (ix += 1) {
                    const i = @as(usize, @intCast(py)) * self.width * 4 + @as(usize, @intCast(ix)) * 4;
                    const a: u32 = a8;
                    self.pixels[i] = @intCast((@as(u32, r8) * a + @as(u32, self.pixels[i]) * inv) / 255);
                    self.pixels[i + 1] = @intCast((@as(u32, g8) * a + @as(u32, self.pixels[i + 1]) * inv) / 255);
                    self.pixels[i + 2] = @intCast((@as(u32, b8) * a + @as(u32, self.pixels[i + 2]) * inv) / 255);
                    self.pixels[i + 3] = @intCast(@min(@as(u32, 255), a + @as(u32, self.pixels[i + 3]) * inv / 255));
                }
            }
            return;
        }

        // A rounded box's interior is fully covered, so the SDF only has to run on the border band: a 1920x1000 box at r=8 is ~52k SDF pixels instead of 1.9M.
        const half_min = @min(w, h) * 0.5;
        const rmax: f32 = @min(@max(@max(radius[0], radius[1]), @max(radius[2], radius[3])), half_min);
        const is_plain_fill = mode == 0 and border_w <= 0 and rmax > 0;
        const inset: i64 = if (is_plain_fill) @as(i64, @intFromFloat(@ceil(rmax))) + 1 else 0;
        const core_x0 = x0 + inset;
        const core_x1 = x1 - inset;
        const core_y0 = y0 + inset;
        const core_y1 = y1 - inset;
        const has_core = is_plain_fill and core_x0 <= core_x1 and core_y0 <= core_y1;

        // The core is one flat colour at full coverage, so it is stores rather than a blend: identical bytes, a fraction of the work.
        if (has_core) {
            const cr8 = to8(rgb[0]);
            const cg8 = to8(rgb[1]);
            const cb8 = to8(rgb[2]);
            const ca8 = to8(alpha);
            var cx_lo = core_x0;
            var cx_hi = core_x1;
            var cy_lo = core_y0;
            var cy_hi = core_y1;
            if (self.scissor) |sc| {
                cx_lo = @max(cx_lo, sc.x0);
                cx_hi = @min(cx_hi, sc.x1 - 1);
                cy_lo = @max(cy_lo, sc.y0);
                cy_hi = @min(cy_hi, sc.y1 - 1);
            }
            var fy: i64 = cy_lo;
            while (fy <= cy_hi and cx_lo <= cx_hi) : (fy += 1) {
                var fx: i64 = cx_lo;
                if (ca8 >= 255) {
                    while (fx <= cx_hi) : (fx += 1) {
                        const i = @as(usize, @intCast(fy)) * self.width * 4 + @as(usize, @intCast(fx)) * 4;
                        self.pixels[i] = cr8;
                        self.pixels[i + 1] = cg8;
                        self.pixels[i + 2] = cb8;
                        self.pixels[i + 3] = ca8;
                    }
                } else {
                    while (fx <= cx_hi) : (fx += 1) self.blend(@intCast(fx), @intCast(fy), rgb, alpha);
                }
            }
        }

        var py: i64 = y0;
        while (py <= y1) : (py += 1) {
            if (self.scissor) |s| {
                if (py < s.y0 or py >= s.y1) continue;
            }
            var ix: i64 = x0;
            while (ix <= x1) : (ix += 1) {
                if (self.scissor) |s| {
                    if (ix < s.x0 or ix >= s.x1) continue;
                }
                // Fully covered and already written above, so the SDF has nothing to say about it.
                if (has_core and ix >= core_x0 and ix <= core_x1 and py >= core_y0 and py <= core_y1) continue;
                const vbx = (@as(f32, @floatFromInt(ix)) + 0.5) - x;
                const vby = (@as(f32, @floatFromInt(py)) + 0.5) - y;
                const a = fragRoundBox(vbx, vby, w, h, radius, mode, border_w);
                if (a <= 0.0) continue; // discard, exactly like the GLSL
                self.blend(@intCast(ix), @intCast(py), rgb, alpha * a);
            }
        }
    }

    // Sample an image with bilinear filtering and CLAMP_TO_EDGE addressing, matching the GLES3 texture sampler.
    fn sampleBilinear(img: Image, u: f32, v: f32) [4]f32 {
        const tw: f32 = @floatFromInt(img.width);
        const th: f32 = @floatFromInt(img.height);
        const x = u * tw - 0.5;
        const y = v * th - 0.5;
        const ix: i64 = @intFromFloat(@floor(x));
        const iy: i64 = @intFromFloat(@floor(y));
        const fx = x - @floor(x);
        const fy = y - @floor(y);
        const last_x: i64 = @as(i64, img.width) - 1;
        const last_y: i64 = @as(i64, img.height) - 1;
        var acc = [4]f32{ 0, 0, 0, 0 };
        for (0..2) |dy| {
            for (0..2) |dx| {
                const sx = std.math.clamp(ix + @as(i64, @intCast(dx)), 0, last_x);
                const sy = std.math.clamp(iy + @as(i64, @intCast(dy)), 0, last_y);
                const i = @as(usize, @intCast(sy)) * img.width * 4 + @as(usize, @intCast(sx)) * 4;
                const wgt = (if (dx == 0) 1.0 - fx else fx) * (if (dy == 0) 1.0 - fy else fy);
                for (0..4) |c| {
                    acc[c] += @as(f32, @floatFromInt(img.pixels[i + c])) / 255.0 * wgt;
                }
            }
        }
        return acc;
    }

    // Blit a texture into a box with the given UV window (u0,v0,u1,v1), sampling bilinearly and blending straight-alpha over the destination.
    pub fn drawImageQuad(
        self: *Surface,
        img: Image,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        uv: [4]f32,
    ) void {
        if (w <= 0 or h <= 0) return;
        const x0 = @max(@as(i64, @intFromFloat(@ceil(x))), 0);
        const x1 = @min(@as(i64, @intFromFloat(@ceil(x + w))) - 1, @as(i64, self.width) - 1);
        const y0 = @max(@as(i64, @intFromFloat(@ceil(y))), 0);
        const y1 = @min(@as(i64, @intFromFloat(@ceil(y + h))) - 1, @as(i64, self.height) - 1);
        var py: i64 = y0;
        while (py <= y1) : (py += 1) {
            if (self.scissor) |s| {
                if (py < s.y0 or py >= s.y1) continue;
            }
            var ix: i64 = x0;
            while (ix <= x1) : (ix += 1) {
                if (self.scissor) |s| {
                    if (ix < s.x0 or ix >= s.x1) continue;
                }
                const fx = (@as(f32, @floatFromInt(ix)) + 0.5 - x) / w;
                const fy = (@as(f32, @floatFromInt(py)) + 0.5 - y) / h;
                const u = uv[0] + (uv[2] - uv[0]) * fx;
                const v = uv[1] + (uv[3] - uv[1]) * fy;
                const t = sampleBilinear(img, u, v);
                if (t[3] <= 0.0) continue;
                self.blend(@intCast(ix), @intCast(py), [3]f32{ t[0], t[1], t[2] }, t[3]);
            }
        }
    }

    // Fill the whole framebuffer with a single straight color.
    pub fn fill(self: *Surface, color: [4]f32) void {
        const n = normalizeColor(color);
        for (0..self.height) |y| {
            for (0..self.width) |x| {
                self.blend(x, y, [3]f32{ n[0], n[1], n[2] }, n[3]);
            }
        }
    }

    // ---- command dispatch ----

    // Render a slice of Clay render commands into the surface, in order.
    pub fn renderCommands(self: *Surface, commands: []const cl.RenderCommand) void {
        const k = render_scale;
        for (commands) |cmd| {
            const bb = cl.BoundingBox{
                .x = cmd.bounding_box.x * k,
                .y = cmd.bounding_box.y * k,
                .width = cmd.bounding_box.width * k,
                .height = cmd.bounding_box.height * k,
            };
            switch (cmd.command_type) {
                .rectangle => {
                    const r = cmd.render_data.rectangle;
                    if (r.background_color[3] <= 0) continue;
                    const cr = cornerRadiusVec4(r.corner_radius);
                    self.drawBox(
                        bb.x,
                        bb.y,
                        bb.width,
                        bb.height,
                        .{ cr[0] * k, cr[1] * k, cr[2] * k, cr[3] * k },
                        0,
                        0,
                        r.background_color,
                    );
                },
                .border => self.drawBorder(cmd.render_data.border, bb),
                .text => {
                    const td = cmd.render_data.text;
                    const bytes = td.string_contents.chars[0..@intCast(td.string_contents.length)];
                    // The box's HEIGHT matters: it is the box the layout reserved for this run, and the run is centred in it.
                    self.drawTextRun(
                        bb.x,
                        bb.y,
                        bb.height,
                        bytes,
                        // Rounded, not truncated: a 14 point run at 150% is 21 pixels, not 20.
                        @intFromFloat(@round(@as(f32, @floatFromInt(td.font_size)) * k)),
                        td.text_color,
                    );
                },
                .image => {
                    if (cmd.render_data.image.image_data) |ptr| {
                        const ref: *const ImageRef = @ptrCast(@alignCast(ptr));
                        self.drawImageCmd(bb, ref);
                    }
                },
                .scissor_start => {
                    const sx: i64 = @intFromFloat(@max(bb.x, 0));
                    const sw: i64 = @intFromFloat(@max(bb.width, 0));
                    const sy: i64 = @intFromFloat(@max(bb.y, 0));
                    const sh: i64 = @intFromFloat(@max(bb.height, 0));
                    self.pushScissor(.{ .x0 = sx, .y0 = sy, .x1 = sx + sw, .y1 = sy + sh });
                },
                .scissor_end => self.popScissor(),
                .none, .custom => {},
            }
        }
        // A leaked scissor must never affect the next frame.
        self.scissor = null;
        self.scissor_depth = 0;
    }

    // Open a clip: it narrows whatever was already clipping, so a wide inner clip (a field's, as tall as its content) can never paint over its ancestors.
    fn pushScissor(self: *Surface, next: Scissor) void {
        if (self.scissor_depth < self.scissor_stack.len) {
            self.scissor_stack[self.scissor_depth] = self.scissor;
            self.scissor_depth += 1;
        }
        self.scissor = if (self.scissor) |cur| intersect(cur, next) else next;
    }

    fn popScissor(self: *Surface) void {
        if (self.scissor_depth == 0) {
            self.scissor = null;
            return;
        }
        self.scissor_depth -= 1;
        self.scissor = self.scissor_stack[self.scissor_depth];
    }

    // The overlap of two clips: empty (x1 <= x0 or y1 <= y0) means nothing can be painted, which the per-pixel tests already understand.
    fn intersect(a: Scissor, b: Scissor) Scissor {
        return .{
            .x0 = @max(a.x0, b.x0),
            .y0 = @max(a.y0, b.y0),
            .x1 = @min(a.x1, b.x1),
            .y1 = @min(a.y1, b.y1),
        };
    }

    fn drawBorder(self: *Surface, bd: cl.BorderRenderData, bb: cl.BoundingBox) void {
        const top: f32 = @floatFromInt(bd.width.top);
        const bottom: f32 = @floatFromInt(bd.width.bottom);
        const left: f32 = @floatFromInt(bd.width.left);
        const right: f32 = @floatFromInt(bd.width.right);
        if (top == bottom and top == left and top == right) {
            if (top <= 0) return;
            self.drawBox(bb.x, bb.y, bb.width, bb.height, cornerRadiusVec4(bd.corner_radius), 1, top, bd.color);
            return;
        }
        // Mixed widths: painter-ordered square quads, radius forced to 0.
        if (top > 0 and bb.width > 0) {
            self.drawBox(bb.x, bb.y, bb.width, @min(top, bb.height), noRadius, 0, 0, bd.color);
        }
        if (bottom > 0 and bb.width > 0) {
            const bh = @min(bottom, bb.height);
            self.drawBox(bb.x, bb.y + bb.height - bh, bb.width, bh, noRadius, 0, 0, bd.color);
        }
        const inner_h = bb.height - @min(top, bb.height) - @min(bottom, bb.height);
        if (inner_h > 0) {
            if (left > 0) {
                self.drawBox(bb.x, bb.y + @min(top, bb.height), @min(left, bb.width), inner_h, noRadius, 0, 0, bd.color);
            }
            if (right > 0) {
                const rw = @min(right, bb.width);
                self.drawBox(bb.x + bb.width - rw, bb.y + @min(top, bb.height), rw, inner_h, noRadius, 0, 0, bd.color);
            }
        }
    }

    // Rasterize a text run with real glyphs.
    pub fn drawTextRun(
        self: *Surface,
        bbox_x: f32,
        bbox_y: f32,
        bbox_h: f32,
        text_bytes: []const u8,
        font_size: u16,
        color: [4]f32,
    ) void {
        // One glyph blit per character per frame, each with a per-pixel coverage multiply: the checks cost more than the arithmetic.
        @setRuntimeSafety(false);
        if (text_bytes.len == 0) return;
        const n = normalizeColor(color);
        const face = text_face.font() orelse {
            self.drawTextRunFallback(bbox_x, bbox_y, text_bytes, font_size, color);
            return;
        };
        const font = face;
        const fs: u16 = if (font_size == 0) 16 else font_size;
        const m = glyphs.measure(font, text_bytes, fs);
        if (m.width <= 0) {
            self.drawTextRunFallback(bbox_x, bbox_y, text_bytes, font_size, color);
            return;
        }
        // Centre the CAP BOX, not the font's line box: a deep descent (Consolas) makes the line box asymmetric, so centring it puts the glyphs visibly high.
        const baseline = if (glyphs.capBox(font, fs)) |cap|
            bbox_y + (if (bbox_h > 0) (bbox_h - cap.height) * 0.5 else 0) - cap.top
        else
            bbox_y + (if (bbox_h > 0) bbox_h - font.lineHeight(fs) else 0) * 0.5 + m.ascent;

        var pen = bbox_x;
        var i: usize = 0;
        while (i < text_bytes.len) {
            const cp = glyphs.nextCodepoint(text_bytes, &i);
            // An emoji the text face cannot draw comes back as a colour image, blitted at its own offset and advance.
            if (text_face.colorGlyph(cp, fs)) |image| {
                self.drawColourGlyph(image, pen, baseline);
                pen += image.advance;
                continue;
            }
            const gm = font.glyphMetrics(cp, fs);
            if (glyphs.cachedGlyph(font, cp, fs)) |mask| {
                const gx: isize = @intFromFloat(@floor(pen + mask.xoff));
                // stb's yoff is measured from the BASELINE, positive downward (stbtt_GetGlyphBitmapBoxSubpixel negates the font-space y1), so the mask's top row sits.
                const top = baseline + mask.yoff;
                const gy: isize = @intFromFloat(@floor(top));
                for (0..mask.h) |row| {
                    for (0..mask.w) |col| {
                        const coverage = @as(f32, @floatFromInt(mask.data[row * mask.w + col])) / 255.0;
                        if (coverage <= 0) continue;
                        const x: isize = gx + @as(isize, @intCast(col));
                        const y: isize = gy + @as(isize, @intCast(row));
                        if (x < 0 or y < 0) continue;
                        if (x >= @as(isize, @intCast(self.width)) or
                            y >= @as(isize, @intCast(self.height))) continue;
                        // The scissor clips TEXT too. Without this a scrolled table's glyphs drew over the sidebar while its row backgrounds were correctly clipped.
                        if (self.scissor) |sc| {
                            if (x < sc.x0 or x >= sc.x1 or y < sc.y0 or y >= sc.y1) continue;
                        }
                        // Glyph coverage multiplies the colour's alpha, so a dim label stays dim.
                        self.blend(
                            @intCast(x),
                            @intCast(y),
                            .{ n[0], n[1], n[2] },
                            coverage * n[3],
                        );
                    }
                }
            }
            pen += gm.advance;
        }
    }

    // One colour glyph: its own pixels, straight alpha, at the offset the font gave it from the pen and the baseline.
    fn drawColourGlyph(self: *Surface, image: *const color_glyphs.Rgba, pen: f32, baseline: f32) void {
        @setRuntimeSafety(false);
        if (image.w == 0 or image.h == 0) return;
        const gx: isize = @intFromFloat(@floor(pen + @as(f32, @floatFromInt(image.xoff))));
        const gy: isize = @intFromFloat(@floor(baseline + @as(f32, @floatFromInt(image.yoff))));
        for (0..image.h) |row| {
            for (0..image.w) |col| {
                const at = (row * image.w + col) * 4;
                const a = @as(f32, @floatFromInt(image.pixels[at + 3])) / 255.0;
                if (a <= 0) continue;
                const x: isize = gx + @as(isize, @intCast(col));
                const y: isize = gy + @as(isize, @intCast(row));
                if (x < 0 or y < 0) continue;
                if (x >= @as(isize, @intCast(self.width)) or y >= @as(isize, @intCast(self.height))) continue;
                if (self.scissor) |sc| {
                    if (x < sc.x0 or x >= sc.x1 or y < sc.y0 or y >= sc.y1) continue;
                }
                const rgb = .{
                    @as(f32, @floatFromInt(image.pixels[at + 0])) / 255.0,
                    @as(f32, @floatFromInt(image.pixels[at + 1])) / 255.0,
                    @as(f32, @floatFromInt(image.pixels[at + 2])) / 255.0,
                };
                self.blend(@intCast(x), @intCast(y), rgb, a);
            }
        }
    }

    // The deterministic per-byte rect fallback used for text when no glyph backend is available.
    pub fn drawTextRunFallback(
        self: *Surface,
        bbox_x: f32,
        bbox_y: f32,
        text_bytes: []const u8,
        font_size: u16,
        color: [4]f32,
    ) void {
        if (text_bytes.len == 0) return;
        const fs: f32 = @floatFromInt(if (font_size == 0) 16 else font_size);
        const adv = fs * 0.6;
        const box_w = adv * 0.7;
        const box_h = @min(fs, 24);
        var cursor: f32 = 0;
        for (text_bytes) |_| {
            self.drawBox(bbox_x + cursor, bbox_y, box_w, box_h, noRadius, 0, 0, color);
            cursor += adv;
        }
    }

    // Read a file off disk, downscale it to `max_dim` and hand back RGBA8 the caller owns.
    fn decodeImage(self: *Surface, path: []const u8, max_dim: u16) ?Image {
        // A browser has no filesystem — and `std.fs.max_path_bytes` does not even ANALYSE there, so the disk half must be pruned, not guarded.
        if (comptime has_fs) return self.decodeImageFromDisk(path, max_dim);
        return null;
    }

    fn decodeImageFromDisk(self: *Surface, path: []const u8, max_dim: u16) ?Image {
        if (path.len == 0 or path.len + 1 > std.fs.max_path_bytes) return null;
        var cbuf: [std.fs.max_path_bytes]u8 = undefined;
        @memcpy(cbuf[0..path.len], path);
        cbuf[path.len] = 0;

        var iw: c_int = 0;
        var ih: c_int = 0;
        var nch: c_int = 0;
        const raw = stbi.stbi_load(@ptrCast(&cbuf), &iw, &ih, &nch, 4) orelse return null;
        defer stbi.stbi_image_free(raw);
        if (iw <= 0 or ih <= 0) return null;

        const dims = common.scaledDims(@intCast(iw), @intCast(ih), max_dim);
        const len: usize = @as(usize, dims[0]) * dims[1] * 4;
        const out = self.alloc.alloc(u8, len) catch return null;
        if (dims[0] == @as(u32, @intCast(iw)) and dims[1] == @as(u32, @intCast(ih))) {
            @memcpy(out, raw[0..len]);
        } else if (stbi.stbir_resize_uint8_linear(raw, iw, ih, 0, out.ptr, @intCast(dims[0]), @intCast(dims[1]), 0, stbi.STBIR_RGBA) == null) {
            self.alloc.free(out);
            return null;
        }
        self.owned_pixels.append(self.alloc, out) catch {};
        return .{ .width = dims[0], .height = dims[1], .pixels = out };
    }

    fn drawImageCmd(self: *Surface, bb: cl.BoundingBox, ref: *const ImageRef) void {
        if (bb.width <= 0 or bb.height <= 0) return;
        const path = ref.path_ptr[0..ref.path_len];
        const max_dim: u16 = if (ref.max_dim == 0) 256 else ref.max_dim;
        const key = hashImageKey(path, max_dim);
        const img = blk: {
            if (self.images.get(key)) |found| break :blk found;
            // Decode on demand, exactly as the GPU backends do: without this every CPU platform drew a placeholder.
            const decoded = self.decodeImage(path, max_dim) orelse {
                self.drawBox(bb.x, bb.y, bb.width, bb.height, noRadius, 0, 0, img_placeholder.toClay());
                return;
            };
            self.images.put(self.alloc, key, decoded) catch {
                self.drawBox(bb.x, bb.y, bb.width, bb.height, noRadius, 0, 0, img_placeholder.toClay());
                return;
            };
            break :blk self.images.get(key).?;
        };
        const iw: f32 = @floatFromInt(img.width);
        const ih: f32 = @floatFromInt(img.height);
        switch (ref.fit) {
            .cover => self.drawImageQuad(img, bb.x, bb.y, bb.width, bb.height, coverUv(iw, ih, bb.width, bb.height)),
            .contain => {
                self.drawBox(bb.x, bb.y, bb.width, bb.height, noRadius, 0, 0, img_placeholder.toClay());
                const b = containBox(iw, ih, bb.width, bb.height);
                self.drawImageQuad(img, bb.x + b[0], bb.y + b[1], b[2], b[3], .{ 0, 0, 1, 1 });
            },
            .stretch => self.drawImageQuad(img, bb.x, bb.y, bb.width, bb.height, .{ 0, 0, 1, 1 }),
        }
    }
};

const noRadius: R4 = .{ 0, 0, 0, 0 };

// Map a Clay CornerRadius to the (TL, TR, BL, BR) order, clamping negatives to zero.
pub fn cornerRadiusVec4(r: cl.CornerRadius) R4 {
    return .{
        @max(r.top_left, 0),
        @max(r.top_right, 0),
        @max(r.bottom_left, 0),
        @max(r.bottom_right, 0),
    };
}

// Convert a 0-255 (or 0-1) RGBA color to normalized 0..1, auto-detecting range exactly like the GLES3 `mx <= 1.0` heuristic.
fn normalizeColor(color: [4]f32) [4]f32 {
    const mx = @max(@max(color[0], color[1]), @max(color[2], color[3]));
    if (mx <= 1.0) return color;
    return .{ color[0] / 255.0, color[1] / 255.0, color[2] / 255.0, color[3] / 255.0 };
}

// Clamp an already-0-255 float to a u8 (no 0..1 rescaling).
fn clamp8(v: f32) u8 {
    const s = @round(v);
    if (s <= 0) return 0;
    if (s >= 255) return 255;
    return @intFromFloat(s);
}

// Quantize a 0..1 float to 0..255 with round-half-up and clamping.
fn to8(v: f32) u8 {
    const s = @round(v * 255.0);
    if (s <= 0) return 0;
    if (s >= 255) return 255;
    return @intFromFloat(s);
}

// ---- Renderer (matches the frame.zig Renderer contract) ----

// Adapter so the software surface plugs into the same `render.Renderer` interface frame.zig already calls (`init`, `deinit`, `drawCommands`).
pub const Renderer = struct {
    surface: Surface,

    pub fn init(alloc: std.mem.Allocator) !Renderer {
        return .{ .surface = try Surface.init(alloc, 720, 480) };
    }

    pub fn deinit(self: *Renderer) void {
        if (current_surface == &self.surface) current_surface = null;
        self.surface.deinit();
    }

    pub fn drawCommands(
        self: *Renderer,
        commands: []const cl.RenderCommand,
        win_w: i32,
        win_h: i32,
    ) void {
        if (win_w <= 0 or win_h <= 0) return;
        // `self` is stable here (the renderer lives inside the owning Host), so exposing &self.surface for a window backend to blit is safe.
        current_surface = &self.surface;
        const p = scale.pixelSize(@intCast(win_w), @intCast(win_h), render_scale);
        self.surface.resize(p.w, p.h) catch return;
        self.surface.clear();
        self.surface.renderCommands(commands);
    }

    /// Return a decoded image for a GPU backend that uploads it instead of blitting it, through the same cache the CPU path draws from.
    pub fn imageFor(self: *Renderer, path: []const u8, max_dim: u16) ?Image {
        const key = hashImageKey(path, max_dim);
        if (self.surface.images.get(key)) |img| return img;
        const decoded = self.surface.decodeImage(path, max_dim) orelse return null;
        self.surface.images.put(self.surface.alloc, key, decoded) catch return null;
        return decoded;
    }
};

// True once a glyph-bearing font is available, so the fallback can be skipped. The face comes from `text_face`, which is the SAME face the layout

// measures with — one font, so a run's measured width is exactly the width the rasteriser advances its pen by.
pub fn hasGlyphFont() bool {
    return text_face.font() != null;
}

// The clear colour of the most recent frame, mirrored so a GPU backend clears to the same pixels.
var frame_clear_rgb: [4]f32 = .{ 0, 0, 0, 255 };

/// The colour a GPU backend should clear to, in the same 0-255 (or 0-1) range `setClearColor` accepts.
pub fn currentClearColor() [4]f32 {
    return normalizeColor(frame_clear_rgb);
}

/// Normalize a colour to 0..1 for a backend whose shader wants that range.
pub fn normalizeColorPublic(color: [4]f32) [4]f32 {
    return normalizeColor(color);
}

var render_scale: f32 = 1.0;

// Set the device scale. Values at or below zero are ignored.
pub fn setRenderScale(s: f32) void {
    render_scale = if (s > 0) s else 1.0;
    // Every backend reports its scale here, so the measured width follows the size the glyphs are drawn at.
    text_face.setPixelScale(render_scale);
}

// The current device scale.
pub fn renderScale() f32 {
    return render_scale;
}

// The surface the most recent `drawCommands` wrote to.
var current_surface: ?*Surface = null;

pub fn currentSurface() ?*Surface {
    return current_surface;
}
