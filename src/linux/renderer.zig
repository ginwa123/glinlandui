// Agnostic GLES3 renderer — lives in src/linux/, re-exported as wayland.render.
const std = @import("std");
const log = @import("../core/log.zig");
const builtin = @import("builtin");
const text = @import("text.zig");
const render_common = @import("../core/render_common.zig");
const Color = @import("../core/color.zig").Color;
const cl = @import("zclay");
// The density the window adopted from the compositor, and the one definition of a logical-to-device pixel size.
const ui_scale = @import("ui_scale.zig");
const scale = @import("../core/scale.zig");

const egl = @cImport({
    @cInclude("EGL/egl.h");
});

const gl = @cImport({
    @cInclude("GLES3/gl3.h");
});

const stbi = @cImport({
    @cInclude("stb/stb_image.h");
    @cInclude("stb/stb_image_resize2.h");
});

/// Headless-testable draw command: rect fill or text run.
pub const Draw = render_common.Draw;

fn normChannel(v: u32) f32 {
    return @as(f32, @floatFromInt(v & 0xff)) / 255.0;
}

/// Real EGL init: eglGetDisplay + eglInitialize.
pub fn initGL() !void {
    if (std.c.getenv("WAYLAND_DISPLAY") == null) return error.NoDisplay;
    if (comptime builtin.is_test) {
        return error.NoDisplay;
    } else {
        const dpy = egl.eglGetDisplay(egl.EGL_DEFAULT_DISPLAY);
        if (dpy == egl.EGL_NO_DISPLAY) return error.NoDisplay;
        var major: egl.EGLint = 0;
        var minor: egl.EGLint = 0;
        if (egl.eglInitialize(dpy, &major, &minor) == egl.EGL_FALSE) return error.EglInitFailed;
    }
}

// ---- Pure helpers (headless-testable) ----

/// Convert 0xRRGGBB to a Clay color ([4]f32 in 0-255 range, alpha 255).
pub fn u32ToClayColor(hex: u32) [4]f32 {
    return Color.argb(0xFF00_0000 | (hex & 0x00ff_ffff)).toClay();
}

/// Convert 0xRRGGBB to normalized GL RGBA floats (alpha 1.0).
pub fn u32ToGLColor(hex: u32) [4]f32 {
    return .{
        normChannel(hex >> 16),
        normChannel(hex >> 8),
        normChannel(hex),
        1.0,
    };
}

/// Legacy fixed advance per glyph (stb fallback path only).
pub fn estimatorAdvance(font_size: u16) f32 {
    return @as(f32, @floatFromInt(font_size)) * 0.6;
}

/// Map a text.measureText extent to Clay dimensions.
pub fn extentToClay(ext: text.TextExtent) cl.Dimensions {
    return .{ .w = ext.w, .h = ext.h };
}

/// Normalize a Clay 0-255 color (or an already-0-1 one) to 0-1 GL RGBA.
fn straightColor(clay_color: [4]f32) [4]f32 {
    const mx = @max(@max(clay_color[0], clay_color[1]), @max(clay_color[2], clay_color[3]));
    if (mx <= 1.0) return clay_color;
    return .{
        clay_color[0] / 255.0,
        clay_color[1] / 255.0,
        clay_color[2] / 255.0,
        clay_color[3] / 255.0,
    };
}

// ---- GLES3 renderer (exe only; guarded in tests) ----

// Largest run this renderer will build a coverage texture for; past it the rect fallback draws instead of a 4 MB upload.
const text_max_w: u32 = 2048;
const text_max_h: u32 = 512;
const text_max_bytes: usize = 4095;

/// Text texture cache: a run's coverage is the same pixels whatever colour it is drawn in, so a hover repaint re-uses it.
pub const text_cache_size: usize = 64;

pub const TextCacheEntry = struct {
    hash: u64 = 0,
    tex: c_uint = 0,
    w: i32 = 0,
    h: i32 = 0,
    valid: bool = false,
    last_used: u64 = 0,
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

// ---- Image support (wallpaper thumbnails/preview) ----

/// How an image fills its box (mirrors wallpaper fit modes + stretch).
pub const ImageFit = enum { cover, contain, stretch };

/// Opaque payload a widget passes through Clay's image_data pointer.
pub const ImageRef = struct {
    path_ptr: [*]const u8,
    path_len: usize,
    fit: ImageFit = .cover,
    /// Decode ceiling: the longest side is downscaled to this (no upscale).
    max_dim: u16 = 256,
};

/// Decoded + uploaded image (named so decodeUploadImage and imageTexture share one return type).
pub const DecodedImage = struct {
    tex: c_uint,
    w: i32,
    h: i32,
};

/// Image texture cache: decoded+downscaled RGBA GL textures keyed by FNV-1a(path, max_dim).
pub const img_cache_size: usize = 32;

pub const ImgCacheEntry = struct {
    hash: u64 = 0,
    tex: c_uint = 0,
    w: i32 = 0,
    h: i32 = 0,
    valid: bool = false,
    last_used: u64 = 0,
};

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
        // Wide source: crop the sides.
        const f = box_aspect / img_aspect;
        const cu0 = (1 - f) * 0.5;
        return .{ cu0, 0, 1 - cu0, 1 };
    }
    if (img_aspect < box_aspect) {
        // Tall source: crop top/bottom.
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

const rect_vert_src: [:0]const u8 =
    \\#version 300 es
    \\layout(location=0) in vec2 a_pos;
    \\layout(location=1) in vec2 a_uv;
    \\uniform vec2 u_res;
    \\uniform vec2 u_pos;
    \\uniform vec2 u_size;
    \\out vec2 v_box;
    \\void main() {
    \\  vec2 p = u_pos + a_pos * u_size;
    \\  vec2 clip = (p / u_res) * 2.0 - 1.0;
    \\  gl_Position = vec4(clip.x, -clip.y, 0.0, 1.0);
    \\  v_box = a_pos * u_size;
    \\}
;

const rect_frag_src: [:0]const u8 =
    \\#version 300 es
    \\precision highp float;
    \\uniform vec4 u_color;
    \\uniform vec4 u_radius;
    \\uniform int u_mode;
    \\uniform float u_border;
    \\uniform float u_scale;
    \\uniform vec2 u_size;
    \\in vec2 v_box;
    \\out vec4 o_color;
    \\float sdRoundBox(vec2 p, vec2 b, vec4 r) {
    \\  float rad = (p.x < 0.0) ? (p.y < 0.0 ? r.x : r.z) : (p.y < 0.0 ? r.y : r.w);
    \\  vec2 q = abs(p) - b + rad;
    \\  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - rad;
    \\}
    \\// Pixel coverage of a signed distance (1px AA band): exactly 1.0
    \\// when the sample is >= half a pixel inside, 0.0 half a pixel out.
    \\// A 2px smoothstep band blurred 1px borders across two pixels and
    \\// eroded convex corners (radius looked wrong); 1px clamp is crisp.
    \\float cov(float d) {
    \\  return clamp(0.5 - d * u_scale, 0.0, 1.0);
    \\}
    \\void main() {
    \\  vec2 c = u_size * 0.5;
    \\  vec2 p = v_box - c;
    \\  float m = min(c.x, c.y);
    \\  vec4 r = min(max(u_radius, vec4(0.0)), vec4(m));
    \\  float d = sdRoundBox(p, c, r);
    \\  float a = cov(d);
    \\  if (u_mode == 1) {
    \\    vec2 ib = max(c - vec2(u_border), vec2(0.0));
    \\    float mi = min(ib.x, ib.y);
    \\    vec4 ri = min(max(r - vec4(u_border), vec4(0.0)), vec4(mi));
    \\    float d2 = sdRoundBox(p, ib, ri);
    \\    float a2 = cov(d2);
    \\    a *= (1.0 - a2);
    \\  }
    \\  if (a <= 0.0) discard;
    \\  o_color = vec4(u_color.rgb, u_color.a * a);
    \\}
;

const text_vert_src: [:0]const u8 =
    \\#version 300 es
    \\layout(location=0) in vec2 a_pos;
    \\layout(location=1) in vec2 a_uv;
    \\uniform vec2 u_res;
    \\uniform vec2 u_pos;
    \\uniform vec2 u_size;
    \\out vec2 v_uv;
    \\void main() {
    \\  vec2 p = u_pos + a_pos * u_size;
    \\  vec2 clip = (p / u_res) * 2.0 - 1.0;
    \\  gl_Position = vec4(clip.x, -clip.y, 0.0, 1.0);
    \\  v_uv = a_uv;
    \\}
;

const text_frag_src: [:0]const u8 =
    \\#version 300 es
    \\precision mediump float;
    \\in vec2 v_uv;
    \\uniform sampler2D u_tex;
    \\uniform vec4 u_color;
    \\out vec4 o_color;
    \\void main() {
    \\  float a = texture(u_tex, v_uv).r;
    \\  o_color = vec4(u_color.rgb, u_color.a * a);
    \\}
;

// Image path: the decoded pixels carry their own colour, so the shader outputs the texture directly.
const image_frag_src: [:0]const u8 =
    \\#version 300 es
    \\precision mediump float;
    \\in vec2 v_uv;
    \\uniform sampler2D u_tex;
    \\out vec4 o_color;
    \\void main() { o_color = texture(u_tex, v_uv); }
;

fn compileShader(kind: c_uint, src: [:0]const u8) !c_uint {
    const sh = gl.glCreateShader(kind);
    if (sh == 0) return error.ShaderCreateFailed;
    errdefer gl.glDeleteShader(sh);
    var ptr: [*c]const u8 = src.ptr;
    gl.glShaderSource(sh, 1, @ptrCast(&ptr), null);
    gl.glCompileShader(sh);
    var status: c_int = 0;
    gl.glGetShaderiv(sh, gl.GL_COMPILE_STATUS, &status);
    if (status == 0) {
        var info_log: [512]u8 = undefined;
        var len: c_int = 0;
        gl.glGetShaderInfoLog(sh, 512, &len, @ptrCast(&info_log));
        const n: usize = @intCast(@max(len, 0));
        log.err("shader compile failed: {s}", .{info_log[0..@min(n, info_log.len)]});
        return error.ShaderCompileFailed;
    }
    return sh;
}

fn linkProgram(vs: c_uint, fs: c_uint) !c_uint {
    const prog = gl.glCreateProgram();
    if (prog == 0) return error.ProgramCreateFailed;
    errdefer gl.glDeleteProgram(prog);
    gl.glAttachShader(prog, vs);
    gl.glAttachShader(prog, fs);
    gl.glLinkProgram(prog);
    var status: c_int = 0;
    gl.glGetProgramiv(prog, gl.GL_LINK_STATUS, &status);
    if (status == 0) {
        var info_log: [512]u8 = undefined;
        var len: c_int = 0;
        gl.glGetProgramInfoLog(prog, 512, &len, @ptrCast(&info_log));
        const n: usize = @intCast(@max(len, 0));
        log.err("program link failed: {s}", .{info_log[0..@min(n, info_log.len)]});
        return error.ProgramLinkFailed;
    }
    return prog;
}

pub const Renderer = struct {
    alloc: std.mem.Allocator,
    prog_rect: c_uint = 0,
    prog_text: c_uint = 0,
    prog_image: c_uint = 0,
    vao: c_uint = 0,
    vbo: c_uint = 0,
    /// Cached uniform locations (queried once at init, reused per quad).
    loc_rect_res: c_int = -1,
    loc_rect_pos: c_int = -1,
    loc_rect_size: c_int = -1,
    loc_rect_col: c_int = -1,
    loc_rect_rad: c_int = -1,
    loc_rect_mode: c_int = -1,
    loc_rect_border: c_int = -1,
    loc_rect_scale: c_int = -1,
    loc_image_res: c_int = -1,
    loc_image_pos: c_int = -1,
    loc_image_size: c_int = -1,
    loc_image_tex: c_int = -1,
    loc_text_res: c_int = -1,
    loc_text_pos: c_int = -1,
    loc_text_size: c_int = -1,
    loc_text_col: c_int = -1,
    loc_text_tex: c_int = -1,
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
    /// Decodes performed this frame (budget: at most img_decode_budget misses decode per frame so opening a full gallery never stalls; the rest keep their.
    img_decodes_this_frame: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) !Renderer {
        if (comptime builtin.is_test) return error.NoDisplay;
        var self = Renderer{ .alloc = allocator };

        // Shaders (compile once, log errors).
        const vs_rect = try compileShader(gl.GL_VERTEX_SHADER, rect_vert_src);
        defer gl.glDeleteShader(vs_rect);
        const fs_rect = try compileShader(gl.GL_FRAGMENT_SHADER, rect_frag_src);
        defer gl.glDeleteShader(fs_rect);
        self.prog_rect = try linkProgram(vs_rect, fs_rect);

        const vs_text = try compileShader(gl.GL_VERTEX_SHADER, text_vert_src);
        defer gl.glDeleteShader(vs_text);
        const fs_text = try compileShader(gl.GL_FRAGMENT_SHADER, text_frag_src);
        defer gl.glDeleteShader(fs_text);
        self.prog_text = try linkProgram(vs_text, fs_text);

        // The image program shares the text vertex shader.
        const vs_image = try compileShader(gl.GL_VERTEX_SHADER, text_vert_src);
        defer gl.glDeleteShader(vs_image);
        const fs_image = try compileShader(gl.GL_FRAGMENT_SHADER, image_frag_src);
        defer gl.glDeleteShader(fs_image);
        self.prog_image = try linkProgram(vs_image, fs_image);

        // Cache uniform locations once (per-quad string lookups are pure overhead — see struct docs).
        self.loc_rect_res = gl.glGetUniformLocation(self.prog_rect, "u_res");
        self.loc_rect_pos = gl.glGetUniformLocation(self.prog_rect, "u_pos");
        self.loc_rect_size = gl.glGetUniformLocation(self.prog_rect, "u_size");
        self.loc_rect_col = gl.glGetUniformLocation(self.prog_rect, "u_color");
        self.loc_rect_rad = gl.glGetUniformLocation(self.prog_rect, "u_radius");
        self.loc_rect_mode = gl.glGetUniformLocation(self.prog_rect, "u_mode");
        self.loc_rect_border = gl.glGetUniformLocation(self.prog_rect, "u_border");
        self.loc_rect_scale = gl.glGetUniformLocation(self.prog_rect, "u_scale");
        // An unset float uniform reads 0, which would make every `cov` return 0.5, so it starts at 1x.
        if (self.loc_rect_scale >= 0) gl.glUniform1f(self.loc_rect_scale, 1.0);
        self.loc_image_res = gl.glGetUniformLocation(self.prog_image, "u_res");
        self.loc_image_pos = gl.glGetUniformLocation(self.prog_image, "u_pos");
        self.loc_image_size = gl.glGetUniformLocation(self.prog_image, "u_size");
        self.loc_image_tex = gl.glGetUniformLocation(self.prog_image, "u_tex");
        self.loc_text_res = gl.glGetUniformLocation(self.prog_text, "u_res");
        self.loc_text_pos = gl.glGetUniformLocation(self.prog_text, "u_pos");
        self.loc_text_size = gl.glGetUniformLocation(self.prog_text, "u_size");
        self.loc_text_col = gl.glGetUniformLocation(self.prog_text, "u_color");
        self.loc_text_tex = gl.glGetUniformLocation(self.prog_text, "u_tex");

        // Unit quad VBO (pos + uv) + VAO.
        const quad: [4][4]f32 = .{
            .{ 0, 0, 0, 0 },
            .{ 1, 0, 1, 0 },
            .{ 0, 1, 0, 1 },
            .{ 1, 1, 1, 1 },
        };
        gl.glGenVertexArrays(1, @ptrCast(&self.vao));
        gl.glBindVertexArray(self.vao);
        gl.glGenBuffers(1, @ptrCast(&self.vbo));
        gl.glBindBuffer(gl.GL_ARRAY_BUFFER, self.vbo);
        gl.glBufferData(gl.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(quad)), @ptrCast(&quad), gl.GL_STATIC_DRAW);
        gl.glEnableVertexAttribArray(0);
        gl.glVertexAttribPointer(0, 2, gl.GL_FLOAT, gl.GL_FALSE, 4 * @sizeOf(f32), @ptrFromInt(0));
        gl.glEnableVertexAttribArray(1);
        gl.glVertexAttribPointer(1, 2, gl.GL_FLOAT, gl.GL_FALSE, 4 * @sizeOf(f32), @ptrFromInt(2 * @sizeOf(f32)));
        gl.glBindVertexArray(0);
        return self;
    }

    pub fn deinit(self: *Renderer) void {
        for (&self.text_cache) |*e| {
            if (e.valid and e.tex != 0) {
                var t = e.tex;
                gl.glDeleteTextures(1, @ptrCast(&t));
                e.tex = 0;
                e.valid = false;
            }
        }
        for (&self.img_cache) |*e| {
            if (e.valid and e.tex != 0) {
                var t = e.tex;
                gl.glDeleteTextures(1, @ptrCast(&t));
                e.tex = 0;
                e.valid = false;
            }
        }
        if (self.vbo != 0) {
            var v = self.vbo;
            gl.glDeleteBuffers(1, @ptrCast(&v));
        }
        if (self.vao != 0) {
            var a = self.vao;
            gl.glDeleteVertexArrays(1, @ptrCast(&a));
        }
        if (self.prog_rect != 0) gl.glDeleteProgram(self.prog_rect);
        if (self.prog_text != 0) gl.glDeleteProgram(self.prog_text);
        if (self.prog_image != 0) gl.glDeleteProgram(self.prog_image);
        self.* = undefined;
    }

    fn drawQuad(self: *Renderer, prog: c_uint, win_w: i32, win_h: i32, x: f32, y: f32, w: f32, h: f32, color: [4]f32) void {
        if (w <= 0 or h <= 0) return;
        gl.glUseProgram(prog);
        gl.glBindVertexArray(self.vao);
        const rw: f32 = @floatFromInt(win_w);
        const rh: f32 = @floatFromInt(win_h);
        // Cached locations (queried once at init).
        var loc_res = self.loc_rect_res;
        var loc_pos = self.loc_rect_pos;
        var loc_size = self.loc_rect_size;
        var loc_col = self.loc_rect_col;
        if (prog != self.prog_rect) {
            loc_res = gl.glGetUniformLocation(prog, "u_res");
            loc_pos = gl.glGetUniformLocation(prog, "u_pos");
            loc_size = gl.glGetUniformLocation(prog, "u_size");
            loc_col = gl.glGetUniformLocation(prog, "u_color");
        }
        if (loc_res >= 0) gl.glUniform2f(loc_res, rw, rh);
        if (loc_pos >= 0) gl.glUniform2f(loc_pos, x, y);
        if (loc_size >= 0) gl.glUniform2f(loc_size, w, h);
        if (loc_col >= 0) {
            const r = color[0] / 255.0;
            const g = color[1] / 255.0;
            const b = color[2] / 255.0;
            const a = color[3] / 255.0;
            // u32ToGLColor callers pass 0-255 Clay colors; normalized u32ToGLColor output (0-1) also works: values < 1 stay dim but visible.
            const mx = @max(@max(color[0], color[1]), @max(color[2], color[3]));
            if (mx <= 1.0) {
                gl.glUniform4f(loc_col, color[0], color[1], color[2], color[3]);
            } else {
                gl.glUniform4f(loc_col, r, g, b, a);
            }
        }
        // Reset the rounded path: drawQuad is the square fast path sharing prog_rect, so a stale u_radius/u_mode from drawRoundBox would otherwise leak into.
        if (prog == self.prog_rect) {
            if (self.loc_rect_rad >= 0) gl.glUniform4f(self.loc_rect_rad, 0, 0, 0, 0);
            if (self.loc_rect_mode >= 0) gl.glUniform1i(self.loc_rect_mode, 0);
            if (self.loc_rect_border >= 0) gl.glUniform1f(self.loc_rect_border, 0);
        }
        gl.glDrawArrays(gl.GL_TRIANGLE_STRIP, 0, 4);
        gl.glBindVertexArray(0);
    }

    /// Pure helper: Clay CornerRadius -> rect-shader u_radius vec4 (TL, TR, BL, BR in px), clamped at zero (the shader additionally clamps to half the box.
    pub fn cornerRadiusVec4(r: cl.CornerRadius) [4]f32 {
        return .{ @max(r.top_left, 0), @max(r.top_right, 0), @max(r.bottom_left, 0), @max(r.bottom_right, 0) };
    }

    /// Rounded-rect draw over the unit-quad VBO: like drawQuad plus the u_radius/u_mode/u_border uniforms (mode 0 = fill, 1 = border outline of width.
    fn drawRoundBox(self: *Renderer, win_w: i32, win_h: i32, x: f32, y: f32, w: f32, h: f32, radius: [4]f32, mode: c_int, border_w: f32, color: [4]f32) void {
        if (w <= 0 or h <= 0) return;
        gl.glUseProgram(self.prog_rect);
        gl.glBindVertexArray(self.vao);
        const rw: f32 = @floatFromInt(win_w);
        const rh: f32 = @floatFromInt(win_h);
        if (self.loc_rect_res >= 0) gl.glUniform2f(self.loc_rect_res, rw, rh);
        if (self.loc_rect_pos >= 0) gl.glUniform2f(self.loc_rect_pos, x, y);
        if (self.loc_rect_size >= 0) gl.glUniform2f(self.loc_rect_size, w, h);
        if (self.loc_rect_rad >= 0) gl.glUniform4f(self.loc_rect_rad, radius[0], radius[1], radius[2], radius[3]);
        if (self.loc_rect_mode >= 0) gl.glUniform1i(self.loc_rect_mode, mode);
        if (self.loc_rect_border >= 0) gl.glUniform1f(self.loc_rect_border, border_w);
        if (self.loc_rect_col >= 0) {
            const mx = @max(@max(color[0], color[1]), @max(color[2], color[3]));
            if (mx <= 1.0) {
                gl.glUniform4f(self.loc_rect_col, color[0], color[1], color[2], color[3]);
            } else {
                gl.glUniform4f(self.loc_rect_col, color[0] / 255.0, color[1] / 255.0, color[2] / 255.0, color[3] / 255.0);
            }
        }
        gl.glDrawArrays(gl.GL_TRIANGLE_STRIP, 0, 4);
        gl.glBindVertexArray(0);
    }

    fn drawRectCmd(self: *Renderer, win_w: i32, win_h: i32, x: f32, y: f32, w: f32, h: f32, clay_color: [4]f32, radius: cl.CornerRadius) void {
        self.drawRoundBox(win_w, win_h, x, y, w, h, cornerRadiusVec4(radius), 0, 0, clay_color);
    }

    /// Draw a Clay BORDER command as a rounded inset outline (single quad, shader mode 1) when all four widths match (the `.outside()` shape every component.
    fn drawBorderCmd(self: *Renderer, win_w: i32, win_h: i32, bb_x: f32, bb_y: f32, bb_w: f32, bb_h: f32, bd: cl.BorderRenderData) void {
        const color = bd.color;
        const top: f32 = @floatFromInt(bd.width.top);
        const bottom: f32 = @floatFromInt(bd.width.bottom);
        const left: f32 = @floatFromInt(bd.width.left);
        const right: f32 = @floatFromInt(bd.width.right);
        if (top == bottom and top == left and top == right) {
            if (top <= 0) return;
            self.drawRoundBox(win_w, win_h, bb_x, bb_y, bb_w, bb_h, cornerRadiusVec4(bd.corner_radius), 1, top, color);
            return;
        }
        if (top > 0 and bb_w > 0) self.drawQuad(self.prog_rect, win_w, win_h, bb_x, bb_y, bb_w, @min(top, bb_h), color);
        if (bottom > 0 and bb_w > 0) {
            const bh = @min(bottom, bb_h);
            self.drawQuad(self.prog_rect, win_w, win_h, bb_x, bb_y + bb_h - bh, bb_w, bh, color);
        }
        const inner_h = bb_h - @min(top, bb_h) - @min(bottom, bb_h);
        if (inner_h > 0) {
            if (left > 0) self.drawQuad(self.prog_rect, win_w, win_h, bb_x, bb_y + @min(top, bb_h), @min(left, bb_w), inner_h, color);
            if (right > 0) {
                const rw = @min(right, bb_w);
                self.drawQuad(self.prog_rect, win_w, win_h, bb_x + bb_w - rw, bb_y + @min(top, bb_h), rw, inner_h, color);
            }
        }
    }

    fn drawTextFallback(self: *Renderer, win_w: i32, win_h: i32, bbox_x: f32, bbox_y: f32, text_bytes: []const u8, font_size: u16, clay_color: [4]f32) void {
        const adv = estimatorAdvance(if (font_size == 0) 16 else font_size);
        const fs: f32 = @floatFromInt(if (font_size == 0) 16 else font_size);
        var cursor: f32 = 0;
        for (text_bytes) |_| {
            self.drawRectCmd(win_w, win_h, bbox_x + cursor, bbox_y, adv * 0.7, @min(fs, 24), clay_color, .{});
            cursor += adv;
        }
    }

    /// One run of text: coverage rasterised with the face the layout measured it with, cached as an R8 texture, tinted by u_color.
    fn drawTextCmd(self: *Renderer, win_w: i32, win_h: i32, bbox_x: f32, bbox_y: f32, bbox_h: f32, text_bytes: []const u8, font_size: u16, clay_color: [4]f32) void {
        if (comptime builtin.is_test) return;
        if (text_bytes.len == 0 or text_bytes.len > text_max_bytes) return;
        const fs: u16 = if (font_size == 0) 16 else font_size;
        // A glyph texture is the one thing that cannot scale for free: rasterise it at the display density and place it back in points.
        const s = ui_scale.current();
        const fs_dev: u16 = @intFromFloat(@round(@as(f32, @floatFromInt(fs)) * s));
        const ds = @as(f32, @floatFromInt(fs_dev)) / @as(f32, @floatFromInt(fs));
        const box_h: i32 = @intFromFloat(@round(bbox_h * ds));
        const dev_x = bbox_x * ds;
        const dev_y = bbox_y * ds;
        // The bitmap is blitted on whole device pixels and its glyphs snap from the same fractional origin, so it goes here.
        const grid_x = @floor(dev_x);
        const grid_y = @floor(dev_y);

        // A run's coverage does not depend on its colour, so a hover repaint finds it by (run, size, box, sub-pixel origin) — all in device pixels.
        const key = hashTextKey(text_bytes, fs_dev, box_h, dev_x, dev_y);
        self.text_cache_clock += 1;
        for (&self.text_cache) |*e| {
            if (e.valid and e.hash == key and e.tex != 0) {
                e.last_used = self.text_cache_clock;
                self.text_cache_hits += 1;
                self.drawCoverageQuad(e.tex, win_w, win_h, grid_x / ds, grid_y / ds, @as(f32, @floatFromInt(e.w)) / ds, @as(f32, @floatFromInt(e.h)) / ds, clay_color);
                return;
            }
        }
        self.text_cache_misses += 1;

        const bmp = text.rasterizeRun(self.alloc, text_bytes, fs_dev, dev_x, dev_y, @floatFromInt(box_h)) orelse {
            self.drawTextFallback(win_w, win_h, bbox_x, bbox_y, text_bytes, font_size, clay_color);
            return;
        };
        defer bmp.deinit(self.alloc);
        if (bmp.width > text_max_w or bmp.height > text_max_h) {
            self.drawTextFallback(win_w, win_h, bbox_x, bbox_y, text_bytes, font_size, clay_color);
            return;
        }

        var tex: c_uint = 0;
        gl.glGenTextures(1, @ptrCast(&tex));
        if (tex == 0) {
            self.drawTextFallback(win_w, win_h, bbox_x, bbox_y, text_bytes, font_size, clay_color);
            return;
        }
        gl.glBindTexture(gl.GL_TEXTURE_2D, tex);
        gl.glPixelStorei(gl.GL_UNPACK_ALIGNMENT, 1);
        gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_R8, @intCast(bmp.width), @intCast(bmp.height), 0, gl.GL_RED, gl.GL_UNSIGNED_BYTE, @ptrCast(bmp.pixels.ptr));
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_NEAREST);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_NEAREST);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);
        gl.glBindTexture(gl.GL_TEXTURE_2D, 0);

        const slot = lruVictim(&self.text_cache) orelse {
            var t = tex;
            gl.glDeleteTextures(1, @ptrCast(&t));
            return;
        };
        const ev = &self.text_cache[slot];
        if (ev.valid and ev.tex != 0) {
            var old = ev.tex;
            gl.glDeleteTextures(1, @ptrCast(&old));
        }
        ev.* = .{ .hash = key, .tex = tex, .w = @intCast(bmp.width), .h = @intCast(bmp.height), .valid = true, .last_used = self.text_cache_clock };
        self.drawCoverageQuad(tex, win_w, win_h, grid_x / ds, grid_y / ds, @as(f32, @floatFromInt(bmp.width)) / ds, @as(f32, @floatFromInt(bmp.height)) / ds, clay_color);
    }

    /// Blit an 8-bit coverage texture with the text program: the coverage is the alpha, `clay_color` the ink.
    fn drawCoverageQuad(self: *Renderer, tex: c_uint, win_w: i32, win_h: i32, x: f32, y: f32, w: f32, h: f32, clay_color: [4]f32) void {
        if (w <= 0 or h <= 0 or tex == 0) return;
        gl.glUseProgram(self.prog_text);
        gl.glActiveTexture(gl.GL_TEXTURE0);
        gl.glBindTexture(gl.GL_TEXTURE_2D, tex);
        gl.glBindVertexArray(self.vao);
        gl.glBindBuffer(gl.GL_ARRAY_BUFFER, self.vbo);
        gl.glEnableVertexAttribArray(0);
        gl.glVertexAttribPointer(0, 2, gl.GL_FLOAT, gl.GL_FALSE, 4 * @sizeOf(f32), @ptrFromInt(0));
        gl.glEnableVertexAttribArray(1);
        gl.glVertexAttribPointer(1, 2, gl.GL_FLOAT, gl.GL_FALSE, 4 * @sizeOf(f32), @ptrFromInt(2 * @sizeOf(f32)));
        const rw: f32 = @floatFromInt(win_w);
        const rh: f32 = @floatFromInt(win_h);
        if (self.loc_text_res >= 0) gl.glUniform2f(self.loc_text_res, rw, rh);
        if (self.loc_text_pos >= 0) gl.glUniform2f(self.loc_text_pos, x, y);
        if (self.loc_text_size >= 0) gl.glUniform2f(self.loc_text_size, w, h);
        if (self.loc_text_tex >= 0) gl.glUniform1i(self.loc_text_tex, 0);
        const c = straightColor(clay_color);
        if (self.loc_text_col >= 0) gl.glUniform4f(self.loc_text_col, c[0], c[1], c[2], c[3]);
        gl.glDrawArrays(gl.GL_TRIANGLE_STRIP, 0, 4);
        gl.glBindVertexArray(0);
        gl.glBindTexture(gl.GL_TEXTURE_2D, 0);
    }

    /// Max source side accepted for decode (refuse absurd headers before allocating).
    const img_max_side: c_int = 8192;
    /// Per-frame decode budget (see img_decodes_this_frame).
    const img_decode_budget: u32 = 2;
    /// Placeholder fill while an image loads/fails (neutral dark).
    const img_placeholder = Color.rgb(0x1a, 0x1a, 0x1a);

    /// Decode path (NUL-terminated) via stb, downscale to max_dim, upload as an RGBA GL texture.
    fn decodeUploadImage(self: *Renderer, cpath: [*:0]const u8, max_dim: u16) ?DecodedImage {
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
        var tex: c_uint = 0;
        gl.glGenTextures(1, @ptrCast(&tex));
        if (tex == 0) return null;
        gl.glBindTexture(gl.GL_TEXTURE_2D, tex);
        gl.glPixelStorei(gl.GL_UNPACK_ALIGNMENT, 4);
        gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA, @intCast(dw), @intCast(dh), 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, upload_ptr);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);
        gl.glBindTexture(gl.GL_TEXTURE_2D, 0);
        return .{ .tex = tex, .w = @intCast(dw), .h = @intCast(dh) };
    }

    /// Lookup-or-decode an image texture (LRU).
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
        const up = self.decodeUploadImage(@ptrCast(&cbuf), max_dim) orelse return null;
        if (lruVictim(&self.img_cache)) |idx| {
            const ev = &self.img_cache[idx];
            if (ev.valid and ev.tex != 0) {
                var old = ev.tex;
                gl.glDeleteTextures(1, @ptrCast(&old));
            }
            ev.* = .{ .hash = key, .tex = up.tex, .w = up.w, .h = up.h, .valid = true, .last_used = self.img_cache_clock };
        } else {
            var t = up.tex;
            gl.glDeleteTextures(1, @ptrCast(&t));
            return null;
        }
        return up;
    }

    /// Draw an RGBA texture with custom UVs (temp VBO), for a fit-mapped image.
    fn drawImageQuad(self: *Renderer, tex: c_uint, win_w: i32, win_h: i32, x: f32, y: f32, w: f32, h: f32, uv: [4]f32) void {
        if (w <= 0 or h <= 0 or tex == 0) return;
        const prog = self.prog_image;
        gl.glUseProgram(prog);
        gl.glActiveTexture(gl.GL_TEXTURE0);
        gl.glBindTexture(gl.GL_TEXTURE_2D, tex);
        if (self.loc_image_tex >= 0) gl.glUniform1i(self.loc_image_tex, 0);
        var verts: [4][4]f32 = .{
            .{ 0, 0, uv[0], uv[1] },
            .{ 1, 0, uv[2], uv[1] },
            .{ 0, 1, uv[0], uv[3] },
            .{ 1, 1, uv[2], uv[3] },
        };
        var tmp: c_uint = 0;
        gl.glGenBuffers(1, @ptrCast(&tmp));
        gl.glBindVertexArray(self.vao);
        gl.glBindBuffer(gl.GL_ARRAY_BUFFER, tmp);
        gl.glBufferData(gl.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(verts)), @ptrCast(&verts), gl.GL_STREAM_DRAW);
        gl.glEnableVertexAttribArray(0);
        gl.glVertexAttribPointer(0, 2, gl.GL_FLOAT, gl.GL_FALSE, 4 * @sizeOf(f32), @ptrFromInt(0));
        gl.glEnableVertexAttribArray(1);
        gl.glVertexAttribPointer(1, 2, gl.GL_FLOAT, gl.GL_FALSE, 4 * @sizeOf(f32), @ptrFromInt(2 * @sizeOf(f32)));
        const rw: f32 = @floatFromInt(win_w);
        const rh: f32 = @floatFromInt(win_h);
        if (self.loc_image_res >= 0) gl.glUniform2f(self.loc_image_res, rw, rh);
        if (self.loc_image_pos >= 0) gl.glUniform2f(self.loc_image_pos, x, y);
        if (self.loc_image_size >= 0) gl.glUniform2f(self.loc_image_size, w, h);
        gl.glDrawArrays(gl.GL_TRIANGLE_STRIP, 0, 4);
        gl.glBindVertexArray(0);
        gl.glDeleteBuffers(1, @ptrCast(&tmp));
        // Restore unit-quad VBO binding for the rect path.
        gl.glBindVertexArray(self.vao);
        gl.glBindBuffer(gl.GL_ARRAY_BUFFER, self.vbo);
        gl.glEnableVertexAttribArray(0);
        gl.glVertexAttribPointer(0, 2, gl.GL_FLOAT, gl.GL_FALSE, 4 * @sizeOf(f32), @ptrFromInt(0));
        gl.glEnableVertexAttribArray(1);
        gl.glVertexAttribPointer(1, 2, gl.GL_FLOAT, gl.GL_FALSE, 4 * @sizeOf(f32), @ptrFromInt(2 * @sizeOf(f32)));
        gl.glBindVertexArray(0);
        gl.glBindTexture(gl.GL_TEXTURE_2D, 0);
    }

    /// Draw one Clay IMAGE command: cache lookup, fit-mapped blit, or a placeholder rect while loading/failed.
    fn drawImageCmd(self: *Renderer, win_w: i32, win_h: i32, bb_x: f32, bb_y: f32, bb_w: f32, bb_h: f32, ref: *const ImageRef) void {
        if (comptime builtin.is_test) return;
        if (bb_w <= 0 or bb_h <= 0) return;
        const path = ref.path_ptr[0..ref.path_len];
        const max_dim: u16 = if (ref.max_dim == 0) 256 else ref.max_dim;
        const t = self.imageTexture(path, max_dim) orelse {
            self.drawRectCmd(win_w, win_h, bb_x, bb_y, bb_w, bb_h, img_placeholder.toClay(), .{});
            return;
        };
        const iw: f32 = @floatFromInt(t.w);
        const ih: f32 = @floatFromInt(t.h);
        switch (ref.fit) {
            .cover => {
                const uv = coverUv(iw, ih, bb_w, bb_h);
                self.drawImageQuad(t.tex, win_w, win_h, bb_x, bb_y, bb_w, bb_h, uv);
            },
            .contain => {
                self.drawRectCmd(win_w, win_h, bb_x, bb_y, bb_w, bb_h, img_placeholder.toClay(), .{});
                const b = containBox(iw, ih, bb_w, bb_h);
                self.drawImageQuad(t.tex, win_w, win_h, bb_x + b[0], bb_y + b[1], b[2], b[3], .{ 0, 0, 1, 1 });
            },
            .stretch => {
                self.drawImageQuad(t.tex, win_w, win_h, bb_x, bb_y, bb_w, bb_h, .{ 0, 0, 1, 1 });
            },
        }
    }

    /// Draw a full Clay render-command list.
    pub fn drawCommands(self: *Renderer, commands: []cl.RenderCommand, win_w: i32, win_h: i32) void {
        // The commands are in points; the viewport is the device pixel buffer they are painted into, so a 2x display gets 2x the pixels.
        const s = ui_scale.current();
        const px = scale.pixelSize(@intCast(@max(win_w, 1)), @intCast(@max(win_h, 1)), s);
        gl.glViewport(0, 0, @intCast(px.w), @intCast(px.h));
        // The rounded-box AA band is one DEVICE pixel: at 2x a logical-unit band would leave every edge a quarter-transparent column.
        if (self.loc_rect_scale >= 0) {
            gl.glUseProgram(self.prog_rect);
            gl.glUniform1f(self.loc_rect_scale, s);
        }
        gl.glDisable(gl.GL_SCISSOR_TEST);
        gl.glEnable(gl.GL_BLEND);
        // Separate alpha factors: the window is opaque (glClear alpha 1.0), so keep the destination alpha saturated.
        gl.glBlendFuncSeparate(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA, gl.GL_ONE, gl.GL_ONE_MINUS_SRC_ALPHA);
        self.img_decodes_this_frame = 0;
        for (commands) |*cmd| {
            switch (cmd.command_type) {
                .rectangle => {
                    const bb = cmd.bounding_box;
                    self.drawRectCmd(win_w, win_h, bb.x, bb.y, bb.width, bb.height, cmd.render_data.rectangle.background_color, cmd.render_data.rectangle.corner_radius);
                },
                .text => {
                    const bb = cmd.bounding_box;
                    const td = cmd.render_data.text;
                    const bytes = td.string_contents.chars[0..@intCast(td.string_contents.length)];
                    self.drawTextCmd(win_w, win_h, bb.x, bb.y, bb.height, bytes, td.font_size, td.text_color);
                },
                .scissor_start => {
                    const bb = cmd.bounding_box;
                    gl.glEnable(gl.GL_SCISSOR_TEST);
                    // glScissor is in device pixels, so the point-space box is scaled with everything else.
                    const sx: c_int = @intFromFloat(@round(@max(bb.x, 0) * s));
                    const sw: c_int = @intFromFloat(@round(@max(bb.width, 0) * s));
                    // GL origin is bottom-left; Clay is top-left.
                    const top: f32 = (bb.y + bb.height) * s;
                    const sy: c_int = @intFromFloat(@max(@as(f32, @floatFromInt(px.h)) - top, 0));
                    const sh: c_int = @intFromFloat(@round(@max(bb.height, 0) * s));
                    gl.glScissor(sx, sy, sw, sh);
                },
                .scissor_end => {
                    gl.glDisable(gl.GL_SCISSOR_TEST);
                },
                .border => {
                    const bb = cmd.bounding_box;
                    self.drawBorderCmd(win_w, win_h, bb.x, bb.y, bb.width, bb.height, cmd.render_data.border);
                },
                .image => {
                    const bb = cmd.bounding_box;
                    const im = cmd.render_data.image;
                    if (im.image_data) |ptr| {
                        const ref: *const ImageRef = @ptrCast(@alignCast(ptr));
                        self.drawImageCmd(win_w, win_h, bb.x, bb.y, bb.width, bb.height, ref);
                    }
                },
                else => {},
            }
        }
        gl.glDisable(gl.GL_SCISSOR_TEST);
    }
};

test "initGL returns an error headless instead of crashing" {
    const result = initGL();
    try std.testing.expectError(error.NoDisplay, result);
}

test "u32ToClayColor maps hex to 0-255 Clay color" {
    const c = u32ToClayColor(0x112233);
    try std.testing.expectEqual(@as(f32, 0x11), c[0]);
    try std.testing.expectEqual(@as(f32, 0x22), c[1]);
    try std.testing.expectEqual(@as(f32, 0x33), c[2]);
    try std.testing.expectEqual(@as(f32, 255), c[3]);
    // Agnostic sample: literals only (no ui/theme import allowed here).
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
    // 16:9 image in a square box: crop sides, full height.
    const wide = coverUv(16, 9, 1, 1);
    try std.testing.expectApproxEqAbs(@as(f32, (1 - 9.0 / 16.0) * 0.5), wide[0], 1e-5);
    try std.testing.expectEqual(@as(f32, 0), wide[1]);
    try std.testing.expectApproxEqAbs(@as(f32, 1 - (1 - 9.0 / 16.0) * 0.5), wide[2], 1e-5);
    try std.testing.expectEqual(@as(f32, 1), wide[3]);
    // 9:16 image in a square box: crop top/bottom, full width.
    const tall = coverUv(9, 16, 1, 1);
    try std.testing.expectEqual(@as(f32, 0), tall[0]);
    try std.testing.expectApproxEqAbs(@as(f32, (1 - 9.0 / 16.0) * 0.5), tall[1], 1e-5);
    // Same aspect: identity.
    const same = coverUv(16, 9, 32, 18);
    try std.testing.expectEqual([4]f32{ 0, 0, 1, 1 }, same);
    // Degenerate: identity.
    try std.testing.expectEqual([4]f32{ 0, 0, 1, 1 }, coverUv(0, 9, 1, 1));
}

test "containBox letterboxes inside the box" {
    // 16:9 image in a square 100 box: full width, centered vertically.
    const wide = containBox(16, 9, 100, 100);
    try std.testing.expectApproxEqAbs(@as(f32, 0), wide[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, (100 - 56.25) * 0.5), wide[1], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 100), wide[2], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 56.25), wide[3], 1e-4);
    // 9:16 image in a square 100 box: full height, centered horizontally.
    const tall = containBox(9, 16, 100, 100);
    try std.testing.expectApproxEqAbs(@as(f32, (100 - 56.25) * 0.5), tall[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0), tall[1], 1e-4);
}

test "rect shader keeps a 1px coverage band (crisp borders, true radius)" {
    // Regression: the 2px smoothstep(-1,1,d) band spread a 1px border over two pixels (~0.7 + ~0.16 alpha) and eroded rounded corners, so row outlines.
    try std.testing.expect(std.mem.indexOf(u8, rect_frag_src, "clamp(0.5 - d, 0.0, 1.0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rect_frag_src, "smoothstep(-1.0, 1.0,") == null);
    // Both the outer shape and the border's inner cut use it.
    try std.testing.expect(std.mem.indexOf(u8, rect_frag_src, "float a = cov(d);") != null);
    try std.testing.expect(std.mem.indexOf(u8, rect_frag_src, "float a2 = cov(d2);") != null);
}
