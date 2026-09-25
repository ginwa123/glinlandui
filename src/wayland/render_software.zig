//! Portable software rasterizer — the reference renderer for glinlandui.
//!
//! This is a faithful, pure-Zig reimplementation of the GLES3 renderer's
//! pixel semantics. It has NO dependency on EGL, GLES, Pango, or any system
//! graphics library, so it compiles and runs identically on Linux and macOS
//! (and anywhere else Zig targets). It is what the shared pixel-assertion
//! suite exercises, and on macOS it is the renderer that actually produces
//! the pixels shown in the window (blitted through CoreGraphics).
//!
//! Ported semantics (from the GLSL in render_gles3.zig):
//!   - Coverage is a signed-distance rounded-box field with a 1px AA band:
//!     cov(d) = clamp(0.5 - d, 0, 1). A 2px smoothstep band is deliberately
//!     NOT used (it blurred 1px borders and eroded corners — see the GLES3
//!     regression note); this 1px clamp keeps borders crisp.
//!   - Corner radius is clamped per-axis against min(w,h)/2, so a large radius
//!     yields a pill/stadium, never an ellipse.
//!   - Border is a second, independent rounded box subtracted from the first;
//!     coverage is the product of the two ramps.
//!   - Blending is straight (non-premultiplied) alpha:
//!       dst.rgb = src.rgb*sa + dst.rgb*(1-sa)
//!       dst.a   = sa       + dst.a  *(1-sa)
//!   - Y is top-down: pixel (px,py) samples at (px+0.5, py+0.5).
//!   - No V-flip: texture row 0 is the top row and maps to the top of a quad.
const std = @import("std");
const cl = @import("zclay");
const common = @import("render_common.zig");

pub const ImageFit = common.ImageFit;
pub const ImageRef = common.ImageRef;
pub const u32ToClayColor = common.u32ToClayColor;
pub const coverUv = common.coverUv;
pub const containBox = common.containBox;
pub const hashImageKey = common.hashImageKey;

/// Placeholder color drawn when an image cannot be decoded (mirrors
/// `img_placeholder = 0x1a1a1a` in the GLES3 backend).
pub const img_placeholder: u32 = 0x1a1a1a;

/// Corner radii, ordered (top_left, top_right, bottom_left, bottom_right).
const R4 = [4]f32;

// ---- Signed distance field ----

/// Rounded-box signed distance for a sample in LOCAL box space, where the box
/// spans [0,bx*2] x [0,by*2] and the sample is centred at the origin. This is
/// the scalar port of the `sdRoundBox` GLSL helper. `r` is ordered
/// (top_left, top_right, bottom_left, bottom_right) and assumed pre-clamped.
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

/// 1px antialias band: exactly 1.0 when the sample is >= half a pixel inside,
/// 0.0 when half a pixel outside, linear in between.
inline fn cov(d: f32) f32 {
    return @min(@max(0.5 - d, 0.0), 1.0);
}

/// Fragment coverage for a rounded box. `mode == 1` punches a rounded hole for
/// a border of width `border_w`. Returns the coverage alpha in 0..1.
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
    // Clamp every corner against min(c.x, c.y) — the minimum half-extent, not
    // each axis separately, so an oversized radius becomes a pill shape.
    const m = @min(cx, cy);
    const r: R4 = .{
        @min(@max(radius[0], 0.0), m),
        @min(@max(radius[1], 0.0), m),
        @min(@max(radius[2], 0.0), m),
        @min(@max(radius[3], 0.0), m),
    };
    var a = cov(sdRoundBox(px, py, cx, cy, r));
    if (mode == 1) {
        // Inner box: per-axis inset, radius shrunk by the border width and
        // re-clamped to the inner minimum half-extent. Coverage is the product
        // of the outer and inner ramps, so a 1px integer border lands on
        // exactly one fully-opaque ring with a fully-transparent interior.
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

/// A decoded RGBA8 image, top-left origin, row 0 = top. The software renderer
/// does not decode files itself; callers (tests, or the platform window
/// backend) supply decoded pixels through `Surface.putImage`.
pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []const u8, // RGBA8, width*height*4 bytes
};

/// The scissor region, top-down, half-open on the max edges.
const Scissor = struct { x0: i64, y0: i64, x1: i64, y1: i64 };

/// An RGBA8 software framebuffer plus a scissor stack of depth 1. Pixels are
/// stored RGBA, row-major, top-down (row 0 is the top of the image), which is
/// also the layout both EGL and CoreGraphics accept with a stride of w*4.
pub const Surface = struct {
    alloc: std.mem.Allocator,
    width: u32,
    height: u32,
    pixels: []u8, // RGBA8, len == width*height*4
    scissor: ?Scissor = null,
    clear_rgb: [4]f32 = .{ 0, 0, 0, 255 },
    images: std.AutoHashMapUnmanaged(u64, Image) = .empty,

    pub fn init(alloc: std.mem.Allocator, width: u32, height: u32) !Surface {
        var self = Surface{ .alloc = alloc, .width = 0, .height = 0, .pixels = &.{} };
        try self.resize(width, height);
        return self;
    }

    pub fn deinit(self: *Surface) void {
        self.alloc.free(self.pixels);
        self.pixels = &.{};
        self.images.deinit(self.alloc);
    }

    /// Reallocate the framebuffer at a new size and clear it. Reallocation is
    /// expected only on resize, not per frame.
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

    /// Fill the whole framebuffer with the stored clear color (opaque).
    /// Note: clear_rgb is stored in 0-255, so clamp directly — do NOT run it
    /// through to8(), which expects a normalized 0..1 value.
    pub fn clear(self: *Surface) void {
        const r = clamp8(self.clear_rgb[0]);
        const g = clamp8(self.clear_rgb[1]);
        const b = clamp8(self.clear_rgb[2]);
        var i: usize = 0;
        while (i + 3 < self.pixels.len) : (i += 4) {
            self.pixels[i + 0] = r;
            self.pixels[i + 1] = g;
            self.pixels[i + 2] = b;
            self.pixels[i + 3] = 255;
        }
        self.scissor = null;
    }

    /// Set the color used by `clear` (0-255 RGBA; alpha forced opaque).
    pub fn setClearColor(self: *Surface, color: [4]f32) void {
        self.clear_rgb = color;
    }

    pub fn putImage(self: *Surface, key: u64, img: Image) !void {
        try self.images.put(self.alloc, key, img);
    }

    /// Read one pixel as 0-255 RGBA. Out-of-bounds reads return transparent.
    pub fn px(self: *const Surface, x: i64, y: i64) [4]u8 {
        if (x < 0 or y < 0 or x >= self.width or y >= self.height) return .{ 0, 0, 0, 0 };
        const i = @as(usize, @intCast(y)) * self.width * 4 + @as(usize, @intCast(x)) * 4;
        return .{ self.pixels[i], self.pixels[i + 1], self.pixels[i + 2], self.pixels[i + 3] };
    }

    fn blend(self: *Surface, x: usize, y: usize, src: [3]f32, sa: f32) void {
        const i = y * self.width * 4 + x * 4;
        const inv = 1.0 - sa;
        // Straight-alpha blend of the RGB channels, then the alpha channel
        // with the same source-over equation (GL blend func
        // SRC_ALPHA/ONE_MINUS_SRC_ALPHA for RGB, ONE/ONE_MINUS_SRC_ALPHA for A).
        for (0..3) |c| {
            const dst = @as(f32, @floatFromInt(self.pixels[i + c])) / 255.0;
            self.pixels[i + c] = to8(src[c] * sa + dst * inv);
        }
        const dsta = @as(f32, @floatFromInt(self.pixels[i + 3])) / 255.0;
        self.pixels[i + 3] = to8(sa + dsta * inv);
    }

    // ---- drawing primitives ----

    /// Rasterize one axis-aligned rounded box with straight-alpha blending.
    /// `radius` is (top_left, top_right, bottom_left, bottom_right); `mode == 1`
    /// renders a border ring of width `border_w` instead of a fill.
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
        if (w <= 0 or h <= 0) return;
        const n = normalizeColor(color);
        const alpha = n[3];
        const rgb = [3]f32{ n[0], n[1], n[2] };

        // Pixel-centre coverage box: px in [ceil(x-0.5), floor(x+w-0.5)].
        const x0 = @max(@as(i64, @intFromFloat(@ceil(x - 0.5))), 0);
        const x1 = @min(@as(i64, @intFromFloat(@floor(x + w - 0.5))), @as(i64, self.width) - 1);
        const y0 = @max(@as(i64, @intFromFloat(@ceil(y - 0.5))), 0);
        const y1 = @min(@as(i64, @intFromFloat(@floor(y + h - 0.5))), @as(i64, self.height) - 1);
        if (x0 > x1 or y0 > y1) return;

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
                const vbx = (@as(f32, @floatFromInt(ix)) + 0.5) - x;
                const vby = (@as(f32, @floatFromInt(py)) + 0.5) - y;
                const a = fragRoundBox(vbx, vby, w, h, radius, mode, border_w);
                if (a <= 0.0) continue; // discard, exactly like the GLSL
                self.blend(@intCast(ix), @intCast(py), rgb, alpha * a);
            }
        }
    }

    /// Sample an image with bilinear filtering and CLAMP_TO_EDGE addressing,
    /// matching the GLES3 texture sampler. Returns straight-alpha RGBA 0..1.
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

    /// Blit a texture into a box with the given UV window (u0,v0,u1,v1),
    /// sampling bilinearly and blending straight-alpha over the destination.
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

    /// Fill the whole framebuffer with a single straight color.
    pub fn fill(self: *Surface, color: [4]f32) void {
        const n = normalizeColor(color);
        for (0..self.height) |y| {
            for (0..self.width) |x| {
                self.blend(x, y, [3]f32{ n[0], n[1], n[2] }, n[3]);
            }
        }
    }

    // ---- command dispatch ----

    /// Render a slice of Clay render commands into the surface, in order.
    ///
    /// This is the portable mirror of `Renderer.drawCommands` in the GLES3
    /// backend. The per-command semantics — including the subtle ones — are
    /// reproduced exactly:
    ///   - `border` with uniform widths uses the single rounded-box border path
    ///     (corner radius honoured); mixed widths fall back to up to four
    ///     square quads with radius 0, and side quads are dropped entirely when
    ///     top+bottom exceed the box height.
    ///   - `text` draws the deterministic per-byte rect fallback: one small AA'd
    ///     box per UTF-8 byte, advance 0.6*font_size, box 0.42*font_size wide.
    ///   - `image` draws nothing when `image_data` is null, a placeholder box
    ///     when the path has no decoded source, and a bilinear blit otherwise.
    ///   - `scissor_start` replaces (does not intersect) the clip region;
    ///     `scissor_end` clears it.
    ///   - `none` and `custom` paint nothing.
    pub fn renderCommands(self: *Surface, commands: []const cl.RenderCommand) void {
        for (commands) |cmd| {
            switch (cmd.command_type) {
                .rectangle => {
                    const r = cmd.render_data.rectangle;
                    self.drawBox(
                        cmd.bounding_box.x,
                        cmd.bounding_box.y,
                        cmd.bounding_box.width,
                        cmd.bounding_box.height,
                        cornerRadiusVec4(r.corner_radius),
                        0,
                        0,
                        r.background_color,
                    );
                },
                .border => self.drawBorder(cmd.render_data.border, cmd.bounding_box),
                .text => {
                    const td = cmd.render_data.text;
                    const bytes = td.string_contents.chars[0..@intCast(td.string_contents.length)];
                    self.drawTextRun(
                        cmd.bounding_box.x,
                        cmd.bounding_box.y,
                        bytes,
                        td.font_size,
                        td.text_color,
                    );
                },
                .image => {
                    if (cmd.render_data.image.image_data) |ptr| {
                        const ref: *const ImageRef = @ptrCast(@alignCast(ptr));
                        self.drawImageCmd(cmd.bounding_box, ref);
                    }
                },
                .scissor_start => {
                    const bb = cmd.bounding_box;
                    const sx: i64 = @intFromFloat(@max(bb.x, 0));
                    const sw: i64 = @intFromFloat(@max(bb.width, 0));
                    const sy: i64 = @intFromFloat(@max(bb.y, 0));
                    const sh: i64 = @intFromFloat(@max(bb.height, 0));
                    self.scissor = .{ .x0 = sx, .y0 = sy, .x1 = sx + sw, .y1 = sy + sh };
                },
                .scissor_end => self.scissor = null,
                .none, .custom => {},
            }
        }
        // A leaked scissor must never affect the next frame.
        self.scissor = null;
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

    /// The deterministic per-byte rect fallback used for text when no glyph
    /// backend is available. One AA'd box per UTF-8 *byte*; this is the
    /// portable, glyph-free text rendering the shared pixel suite verifies.
    pub fn drawTextRun(
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

    fn drawImageCmd(self: *Surface, bb: cl.BoundingBox, ref: *const ImageRef) void {
        if (bb.width <= 0 or bb.height <= 0) return;
        const path = ref.path_ptr[0..ref.path_len];
        const max_dim: u16 = if (ref.max_dim == 0) 256 else ref.max_dim;
        const img = self.images.get(hashImageKey(path, max_dim)) orelse {
            self.drawBox(bb.x, bb.y, bb.width, bb.height, noRadius, 0, 0, u32ToClayColor(img_placeholder));
            return;
        };
        const iw: f32 = @floatFromInt(img.width);
        const ih: f32 = @floatFromInt(img.height);
        switch (ref.fit) {
            .cover => self.drawImageQuad(img, bb.x, bb.y, bb.width, bb.height, coverUv(iw, ih, bb.width, bb.height)),
            .contain => {
                self.drawBox(bb.x, bb.y, bb.width, bb.height, noRadius, 0, 0, u32ToClayColor(img_placeholder));
                const b = containBox(iw, ih, bb.width, bb.height);
                self.drawImageQuad(img, bb.x + b[0], bb.y + b[1], b[2], b[3], .{ 0, 0, 1, 1 });
            },
            .stretch => self.drawImageQuad(img, bb.x, bb.y, bb.width, bb.height, .{ 0, 0, 1, 1 }),
        }
    }
};

const noRadius: R4 = .{ 0, 0, 0, 0 };

/// Map a Clay CornerRadius to the (TL, TR, BL, BR) order, clamping negatives
/// to zero. Identical to the GLES3 backend's `cornerRadiusVec4`.
pub fn cornerRadiusVec4(r: cl.CornerRadius) R4 {
    return .{
        @max(r.top_left, 0),
        @max(r.top_right, 0),
        @max(r.bottom_left, 0),
        @max(r.bottom_right, 0),
    };
}

/// Convert a 0-255 (or 0-1) RGBA color to normalized 0..1, auto-detecting range
/// exactly like the GLES3 `mx <= 1.0` heuristic.
fn normalizeColor(color: [4]f32) [4]f32 {
    const mx = @max(@max(color[0], color[1]), @max(color[2], color[3]));
    if (mx <= 1.0) return color;
    return .{ color[0] / 255.0, color[1] / 255.0, color[2] / 255.0, color[3] / 255.0 };
}

/// Clamp an already-0-255 float to a u8 (no 0..1 rescaling).
fn clamp8(v: f32) u8 {
    const s = @round(v);
    if (s <= 0) return 0;
    if (s >= 255) return 255;
    return @intFromFloat(s);
}

/// Quantize a 0..1 float to 0..255 with round-half-up and clamping.
fn to8(v: f32) u8 {
    const s = @round(v * 255.0);
    if (s <= 0) return 0;
    if (s >= 255) return 255;
    return @intFromFloat(s);
}

// ---- Renderer (matches the frame.zig Renderer contract) ----

/// Adapter so the software surface plugs into the same `render.Renderer`
/// interface frame.zig already calls (`init`, `deinit`, `drawCommands`). The
/// surface is resized on demand to match each drawCommands call.
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
        // `self` is stable here (the renderer lives inside the owning Host), so
        // exposing &self.surface for a window backend to blit is safe. This is
        // set on draw, not on init, because init returns by value.
        current_surface = &self.surface;
        self.surface.resize(@intCast(win_w), @intCast(win_h)) catch return;
        self.surface.clear();
        self.surface.renderCommands(commands);
    }
};

/// The surface the most recent `drawCommands` wrote to. The engine is a
/// single-window design, so a window backend reads this immediately after the
/// delegate's on_frame to blit exactly the pixels just produced. Null until the
/// first draw.
var current_surface: ?*Surface = null;

pub fn currentSurface() ?*Surface {
    return current_surface;
}
