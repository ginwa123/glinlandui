// Agnostic GLES3 renderer — lives in src/wayland/, re-exported
// as wayland.render. Pure drawing primitives over Clay/zclay commands;
// ZERO ui/* imports by design. App-specific mapping (LayoutSummary ->
// draws, theme palette) lives in ui/views.zig + ui/theme.zig; font
// resolve/measure lives in sibling text.zig (wayland.text).
//
// initGL() performs the real eglGetDisplay + eglInitialize path in the
// exe build; in `zig build test` (or when WAYLAND_DISPLAY is unset) it
// returns error.NoDisplay instead of touching a compositor.
//
// Text engine: pangocairo primary, stb fallback.
// - Primary (exe): PangoLayout -> cairo ARGB32 image surface -> CPU
//   un-premultiply + swizzle to RGBA -> GL_RGBA texture -> textured quad.
//   Measurement comes from text.measureText() (Pango), so layout matches
//   by construction. Handles shaping, CJK/Arabic, fontconfig fallback.
// - Fallback: stb-baked 512x512 ASCII atlas (initAtlas) when Pango fails,
//   then small filled rects — never crashes. Tests always take the rect
//   path (builtin.is_test, no GL).
//
// stb_truetype impl lives in exactly one TU:
// src/stb_truetype_impl.c (#define STB_TRUETYPE_IMPLEMENTATION). Kept for
// fallback only; primary path needs no stb calls.
const std = @import("std");
const builtin = @import("builtin");
const text = @import("text.zig");
const cl = @import("zclay");

const egl = @cImport({
    @cInclude("EGL/egl.h");
});

const gl = @cImport({
    @cInclude("GLES3/gl3.h");
});

const stb = @cImport({
    @cInclude("stb/stb_truetype.h");
});

const stbi = @cImport({
    @cInclude("stb/stb_image.h");
    @cInclude("stb/stb_image_resize2.h");
});

const shim = @cImport({
    @cInclude("pango_text.h");
});

/// Headless-testable draw command: rect fill or text run.
pub const Draw = struct {
    kind: enum { rect, text },
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    color: u32,
};

fn normChannel(v: u32) f32 {
    return @as(f32, @floatFromInt(v & 0xff)) / 255.0;
}

/// Real EGL init: eglGetDisplay + eglInitialize. Returns error.NoDisplay
/// gracefully when no WAYLAND_DISPLAY/EGL is present — never crashes
/// headless, and never requires a compositor in tests.
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
    return .{
        @floatFromInt((hex >> 16) & 0xff),
        @floatFromInt((hex >> 8) & 0xff),
        @floatFromInt(hex & 0xff),
        255,
    };
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
/// Primary Pango path measures via text.measureText(), so this is NOT
/// used for layout anymore — kept so the stb fallback renders with the
/// same spacing the old estimator laid out.
pub fn estimatorAdvance(font_size: u16) f32 {
    return @as(f32, @floatFromInt(font_size)) * 0.6;
}

/// Map a text.measureText extent to Clay dimensions.
pub fn extentToClay(ext: text.TextExtent) cl.Dimensions {
    return .{ .w = ext.w, .h = ext.h };
}

/// Normalize a Clay 0-255 color (or 0-1 GL color) to cairo 0-1 RGBA.
fn clayToCairo(clay_color: [4]f32) [4]f64 {
    const mx = @max(@max(clay_color[0], clay_color[1]), @max(clay_color[2], clay_color[3]));
    if (mx <= 1.0) {
        return .{
            @floatCast(clay_color[0]),
            @floatCast(clay_color[1]),
            @floatCast(clay_color[2]),
            @floatCast(clay_color[3]),
        };
    }
    return .{
        @floatCast(clay_color[0] / 255.0),
        @floatCast(clay_color[1] / 255.0),
        @floatCast(clay_color[2] / 255.0),
        @floatCast(clay_color[3] / 255.0),
    };
}

// ---- GLES3 renderer (exe only; guarded in tests) ----

const atlas_w: c_int = 512;
const atlas_h: c_int = 512;
const atlas_font_px: f32 = 18.0;

// Max single text-run surface (w*h*4 bytes). Settings labels are tiny;
// larger runs fall back to stb/rects instead of OOMing per frame.
const pango_max_w: i32 = 2048;
const pango_max_h: i32 = 256;
const pango_max_bytes: usize = 4095;

/// Pango texture cache: static settings labels (~20) re-rendered every
/// hover frame cost ~35 Pango/cairo calls + alloc + upload + delete each.
/// 64-entry LRU keyed by FNV-1a(text, font_size, color bits) turns motion
/// redraws into GPU blits. Color is baked into the cairo image, so it is
/// part of the key. Pure hash + LRU logic is headless-testable below.
pub const text_cache_size: usize = 64;

pub const TextCacheEntry = struct {
    hash: u64 = 0,
    tex: c_uint = 0,
    w: i32 = 0,
    h: i32 = 0,
    valid: bool = false,
    last_used: u64 = 0,
};

/// Pure + headless-testable key for the texture cache.
pub fn hashTextKey(text_bytes: []const u8, font_size: u16, clay_color: [4]f32) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (text_bytes) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    h ^= @as(u64, font_size);
    h *%= 0x100000001b3;
    h ^= @as(u64, text_bytes.len);
    h *%= 0x100000001b3;
    for (clay_color) |c| {
        h ^= @as(u64, @as(u32, @bitCast(c)));
        h *%= 0x100000001b3;
    }
    return h;
}

/// Pure LRU victim pick: first invalid slot, else smallest last_used.
/// Returns null when the cache slice is empty (never in practice).
/// Generic over text + image cache entries (both carry valid/last_used).
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
/// The widget owns the slot (static per-declare scratch, synchronous
/// lifetime like all props); the renderer only reads it during the same
/// frame's drawCommands. `path` points at the owner's stable bytes
/// (e.g. AppState file paths) — never retained past the frame.
pub const ImageRef = struct {
    path_ptr: [*]const u8,
    path_len: usize,
    fit: ImageFit = .cover,
    /// Decode ceiling: the longest side is downscaled to this (no
    /// upscale). Thumbnails pass small values, the preview a larger one.
    max_dim: u16 = 256,
};

/// Decoded + uploaded image (named so decodeUploadImage and
/// imageTexture share one return type).
pub const DecodedImage = struct {
    tex: c_uint,
    w: i32,
    h: i32,
};

/// Image texture cache: decoded+downscaled RGBA GL textures keyed by
/// FNV-1a(path, max_dim). Same LRU discipline as the text cache.
/// Exe-only (tests prune GL).
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

/// Pure: downscaled dims preserving aspect so the longest side is at
/// most max_dim. Never upscales. Returns [w, h] (min 1).
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

/// Pure: cover-fit UV crop (u0, v0, u1, v1 fractions of the source) so
/// the image fills a bw×bh box with no distortion. v=0 is the top row
/// (matches the unflipped upload + unit-quad VBO convention).
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

/// Pure: contain-fit inner box (x, y, w, h relative to the bw×bh box)
/// so the whole image shows letterboxed. Never upscales beyond the box.
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
    \\  return clamp(0.5 - d, 0.0, 1.0);
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

// Pango path: color is baked into the cairo image, so the shader outputs
// the texture directly (keeps subpixel AA + correct premultiplied alpha
// after our CPU un-premultiply to straight RGBA).
const pango_frag_src: [:0]const u8 =
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
        var log: [512]u8 = undefined;
        var len: c_int = 0;
        gl.glGetShaderInfoLog(sh, 512, &len, @ptrCast(&log));
        const n: usize = @intCast(@max(len, 0));
        std.log.err("shader compile failed: {s}", .{log[0..@min(n, log.len)]});
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
        var log: [512]u8 = undefined;
        var len: c_int = 0;
        gl.glGetProgramInfoLog(prog, 512, &len, @ptrCast(&log));
        const n: usize = @intCast(@max(len, 0));
        std.log.err("program link failed: {s}", .{log[0..@min(n, log.len)]});
        return error.ProgramLinkFailed;
    }
    return prog;
}

/// Load an entire file via libc fopen/fread (no Io needed in run()).
fn loadFileC(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len + 1 > path_buf.len) return error.NameTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const cpath: [*:0]const u8 = @ptrCast(&path_buf);
    const f = std.c.fopen(cpath, "rb") orelse return error.FileNotFound;
    defer _ = std.c.fclose(f);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var chunk: [8192]u8 = undefined;
    while (true) {
        const n = std.c.fread(@ptrCast(&chunk), 1, chunk.len, f);
        if (n == 0) break;
        try out.appendSlice(allocator, chunk[0..n]);
        if (n < chunk.len) break;
    }
    if (out.items.len == 0) return error.EmptyFile;
    return out.toOwnedSlice(allocator);
}

pub const Renderer = struct {
    alloc: std.mem.Allocator,
    prog_rect: c_uint = 0,
    prog_text: c_uint = 0,
    prog_pango: c_uint = 0,
    vao: c_uint = 0,
    vbo: c_uint = 0,
    atlas_tex: c_uint = 0,
    has_atlas: bool = false,
    baked: [96]stb.stbtt_bakedchar = undefined,
    font_data: []u8 = &.{},
    font_info: stb.stbtt_fontinfo = std.mem.zeroes(stb.stbtt_fontinfo),
    has_font: bool = false,
    /// Cached uniform locations (queried once at init, reused per quad).
    /// glGetUniformLocation does a string lookup per call — at ~200 quads
    /// per frame that is ~800 strcmp-style lookups/frame of pure overhead.
    /// -1 means unqueried/unavailable (skip the uniform upload).
    loc_rect_res: c_int = -1,
    loc_rect_pos: c_int = -1,
    loc_rect_size: c_int = -1,
    loc_rect_col: c_int = -1,
    loc_rect_rad: c_int = -1,
    loc_rect_mode: c_int = -1,
    loc_rect_border: c_int = -1,
    loc_pango_res: c_int = -1,
    loc_pango_pos: c_int = -1,
    loc_pango_size: c_int = -1,
    loc_pango_tex: c_int = -1,
    loc_text_res: c_int = -1,
    loc_text_pos: c_int = -1,
    loc_text_size: c_int = -1,
    loc_text_col: c_int = -1,
    loc_text_tex: c_int = -1,
    /// Pango texture LRU (see text_cache_size docs). Owned GL textures —
    /// deleted on eviction + deinit. Exe-only (tests prune GL).
    text_cache: [text_cache_size]TextCacheEntry = [_]TextCacheEntry{.{}} ** text_cache_size,
    text_cache_clock: u64 = 0,
    text_cache_hits: u64 = 0,
    text_cache_misses: u64 = 0,
    /// Image texture LRU (wallpaper thumbnails/preview). Owned GL
    /// textures — deleted on eviction + deinit. Exe-only.
    img_cache: [img_cache_size]ImgCacheEntry = [_]ImgCacheEntry{.{}} ** img_cache_size,
    img_cache_clock: u64 = 0,
    img_cache_hits: u64 = 0,
    img_cache_misses: u64 = 0,
    /// Decodes performed this frame (budget: at most img_decode_budget
    /// misses decode per frame so opening a full gallery never stalls;
    /// the rest keep their placeholder until the next frame).
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

        // Pango RGBA program shares the text vertex shader.
        const vs_pango = try compileShader(gl.GL_VERTEX_SHADER, text_vert_src);
        defer gl.glDeleteShader(vs_pango);
        const fs_pango = try compileShader(gl.GL_FRAGMENT_SHADER, pango_frag_src);
        defer gl.glDeleteShader(fs_pango);
        self.prog_pango = try linkProgram(vs_pango, fs_pango);

        // Cache uniform locations once (per-quad string lookups are pure
        // overhead — see struct docs). Missing (<0) means skip the upload.
        self.loc_rect_res = gl.glGetUniformLocation(self.prog_rect, "u_res");
        self.loc_rect_pos = gl.glGetUniformLocation(self.prog_rect, "u_pos");
        self.loc_rect_size = gl.glGetUniformLocation(self.prog_rect, "u_size");
        self.loc_rect_col = gl.glGetUniformLocation(self.prog_rect, "u_color");
        self.loc_rect_rad = gl.glGetUniformLocation(self.prog_rect, "u_radius");
        self.loc_rect_mode = gl.glGetUniformLocation(self.prog_rect, "u_mode");
        self.loc_rect_border = gl.glGetUniformLocation(self.prog_rect, "u_border");
        self.loc_pango_res = gl.glGetUniformLocation(self.prog_pango, "u_res");
        self.loc_pango_pos = gl.glGetUniformLocation(self.prog_pango, "u_pos");
        self.loc_pango_size = gl.glGetUniformLocation(self.prog_pango, "u_size");
        self.loc_pango_tex = gl.glGetUniformLocation(self.prog_pango, "u_tex");
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

        // stb fallback atlas (ASCII 32..126 at 18px). Failure is fine:
        // drawTextCmd falls back to rects. Primary Pango path needs no atlas.
        self.initAtlas() catch |err| {
            std.log.warn("glyph atlas unavailable ({s}); stb fallback uses rects, pango primary unaffected", .{@errorName(err)});
            self.has_atlas = false;
            self.atlas_tex = 0;
        };
        return self;
    }

    fn initAtlas(self: *Renderer) !void {
        const font_path = text.resolveFont() catch return error.FontNotFound;
        const data = try loadFileC(self.alloc, font_path);
        errdefer self.alloc.free(data);
        var info: stb.stbtt_fontinfo = undefined;
        if (stb.stbtt_InitFont(&info, data.ptr, 0) == 0) return error.FontInitFailed;
        var bitmap: [atlas_w * atlas_h]u8 = undefined;
        @memset(&bitmap, 0);
        const baked_n = stb.stbtt_BakeFontBitmap(data.ptr, 0, atlas_font_px, &bitmap, atlas_w, atlas_h, 32, 96, &self.baked);
        if (baked_n <= 0) return error.BakeFailed;
        var tex: c_uint = 0;
        gl.glGenTextures(1, @ptrCast(&tex));
        gl.glBindTexture(gl.GL_TEXTURE_2D, tex);
        gl.glPixelStorei(gl.GL_UNPACK_ALIGNMENT, 1);
        gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_R8, atlas_w, atlas_h, 0, gl.GL_RED, gl.GL_UNSIGNED_BYTE, @ptrCast(&bitmap));
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);
        gl.glBindTexture(gl.GL_TEXTURE_2D, 0);
        self.atlas_tex = tex;
        self.has_atlas = true;
        self.font_data = data;
        self.font_info = info;
        self.has_font = true;
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
        if (self.atlas_tex != 0) {
            var t = self.atlas_tex;
            gl.glDeleteTextures(1, @ptrCast(&t));
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
        if (self.prog_pango != 0) gl.glDeleteProgram(self.prog_pango);
        if (self.font_data.len != 0) self.alloc.free(self.font_data);
        self.* = undefined;
    }

    fn setRectUniforms(self: *Renderer, win_w: i32, win_h: i32, x: f32, y: f32, w: f32, h: f32, color: [4]f32) void {
        _ = self;
        const res_w: f32 = @floatFromInt(win_w);
        const res_h: f32 = @floatFromInt(win_h);
        const prog: c_uint = 0; // placeholder to keep helper shape; real binds happen in callers
        _ = prog;
        _ = res_w;
        _ = res_h;
        _ = x;
        _ = y;
        _ = w;
        _ = h;
        _ = color;
    }

    fn drawQuad(self: *Renderer, prog: c_uint, win_w: i32, win_h: i32, x: f32, y: f32, w: f32, h: f32, color: [4]f32) void {
        if (w <= 0 or h <= 0) return;
        gl.glUseProgram(prog);
        gl.glBindVertexArray(self.vao);
        const rw: f32 = @floatFromInt(win_w);
        const rh: f32 = @floatFromInt(win_h);
        // Cached locations (queried once at init). prog_rect is the only
        // drawQuad caller today; fall back to a lookup for unknown progs.
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
            // u32ToGLColor callers pass 0-255 Clay colors; normalized
            // u32ToGLColor output (0-1) also works: values < 1 stay dim
            // but visible. Detect range: if max <= 1.0 use directly.
            const mx = @max(@max(color[0], color[1]), @max(color[2], color[3]));
            if (mx <= 1.0) {
                gl.glUniform4f(loc_col, color[0], color[1], color[2], color[3]);
            } else {
                gl.glUniform4f(loc_col, r, g, b, a);
            }
        }
        // Reset the rounded path: drawQuad is the square fast path sharing
        // prog_rect, so a stale u_radius/u_mode from drawRoundBox would
        // otherwise leak into these quads (mixed-width border fallback).
        if (prog == self.prog_rect) {
            if (self.loc_rect_rad >= 0) gl.glUniform4f(self.loc_rect_rad, 0, 0, 0, 0);
            if (self.loc_rect_mode >= 0) gl.glUniform1i(self.loc_rect_mode, 0);
            if (self.loc_rect_border >= 0) gl.glUniform1f(self.loc_rect_border, 0);
        }
        gl.glDrawArrays(gl.GL_TRIANGLE_STRIP, 0, 4);
        gl.glBindVertexArray(0);
    }

    /// Pure helper: Clay CornerRadius -> rect-shader u_radius vec4
    /// (TL, TR, BL, BR in px), clamped at zero (the shader additionally
    /// clamps to half the box size). Headless-testable.
    pub fn cornerRadiusVec4(r: cl.CornerRadius) [4]f32 {
        return .{ @max(r.top_left, 0), @max(r.top_right, 0), @max(r.bottom_left, 0), @max(r.bottom_right, 0) };
    }

    /// Rounded-rect draw over the unit-quad VBO: like drawQuad plus the
    /// u_radius/u_mode/u_border uniforms (mode 0 = fill, 1 = border
    /// outline of width `border_w`). Radius 0 renders exactly the old
    /// square quad (SDF degenerates to the box), so square callers are
    /// pixel-identical.
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

    /// Draw a Clay BORDER command as a rounded inset outline (single
    /// quad, shader mode 1) when all four widths match (the `.outside()`
    /// shape every component emits); mixed widths fall back to 4 square
    /// quads. Follows the border's own corner_radius so outlines track
    /// rounded fills.
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

    /// Draw a straight-RGBA texture (Pango run) with the unit-quad VBO.
    fn drawRgbaQuad(self: *Renderer, tex: c_uint, win_w: i32, win_h: i32, x: f32, y: f32, w: f32, h: f32) void {
        if (w <= 0 or h <= 0 or tex == 0) return;
        const prog = self.prog_pango;
        gl.glUseProgram(prog);
        gl.glActiveTexture(gl.GL_TEXTURE0);
        gl.glBindTexture(gl.GL_TEXTURE_2D, tex);
        // Unit-quad VBO already bound via VAO (pos + uv 0..1).
        gl.glBindVertexArray(self.vao);
        gl.glBindBuffer(gl.GL_ARRAY_BUFFER, self.vbo);
        gl.glEnableVertexAttribArray(0);
        gl.glVertexAttribPointer(0, 2, gl.GL_FLOAT, gl.GL_FALSE, 4 * @sizeOf(f32), @ptrFromInt(0));
        gl.glEnableVertexAttribArray(1);
        gl.glVertexAttribPointer(1, 2, gl.GL_FLOAT, gl.GL_FALSE, 4 * @sizeOf(f32), @ptrFromInt(2 * @sizeOf(f32)));
        const rw: f32 = @floatFromInt(win_w);
        const rh: f32 = @floatFromInt(win_h);
        const loc_res = self.loc_pango_res;
        const loc_pos = self.loc_pango_pos;
        const loc_size = self.loc_pango_size;
        const loc_tex = self.loc_pango_tex;
        if (loc_res >= 0) gl.glUniform2f(loc_res, rw, rh);
        if (loc_pos >= 0) gl.glUniform2f(loc_pos, x, y);
        if (loc_size >= 0) gl.glUniform2f(loc_size, w, h);
        if (loc_tex >= 0) gl.glUniform1i(loc_tex, 0);
        gl.glDrawArrays(gl.GL_TRIANGLE_STRIP, 0, 4);
        gl.glBindVertexArray(0);
        gl.glBindTexture(gl.GL_TEXTURE_2D, 0);
    }

    fn drawGlyph(self: *Renderer, win_w: i32, win_h: i32, x: f32, y: f32, w: f32, h: f32, uu0: f32, vv0: f32, uu1: f32, vv1: f32, clay_color: [4]f32) void {
        if (w <= 0 or h <= 0) return;
        const prog = self.prog_text;
        gl.glUseProgram(prog);
        gl.glActiveTexture(gl.GL_TEXTURE0);
        gl.glBindTexture(gl.GL_TEXTURE_2D, self.atlas_tex);
        const loc_tex = self.loc_text_tex;
        if (loc_tex >= 0) gl.glUniform1i(loc_tex, 0);
        // Custom UV path: bind a temp VBO with this glyph's UVs.
        // Simpler: reuse unit-quad VBO but override UV via uniforms?
        // Our text vertex shader takes UV from the VBO, so for per-glyph
        // UVs we upload a 4-vertex temp buffer each glyph (few hundred
        // glyphs/frame max — fine for v1).
        var verts: [4][4]f32 = .{
            .{ 0, 0, uu0, vv0 },
            .{ 1, 0, uu1, vv0 },
            .{ 0, 1, uu0, vv1 },
            .{ 1, 1, uu1, vv1 },
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
        const loc_res = self.loc_text_res;
        const loc_pos = self.loc_text_pos;
        const loc_size = self.loc_text_size;
        const loc_col = self.loc_text_col;
        if (loc_res >= 0) gl.glUniform2f(loc_res, rw, rh);
        if (loc_pos >= 0) gl.glUniform2f(loc_pos, x, y);
        if (loc_size >= 0) gl.glUniform2f(loc_size, w, h);
        if (loc_col >= 0) {
            const mx = @max(@max(clay_color[0], clay_color[1]), @max(clay_color[2], clay_color[3]));
            if (mx <= 1.0) {
                gl.glUniform4f(loc_col, clay_color[0], clay_color[1], clay_color[2], clay_color[3]);
            } else {
                gl.glUniform4f(loc_col, clay_color[0] / 255.0, clay_color[1] / 255.0, clay_color[2] / 255.0, clay_color[3] / 255.0);
            }
        }
        gl.glDrawArrays(gl.GL_TRIANGLE_STRIP, 0, 4);
        gl.glBindVertexArray(0);
        gl.glDeleteBuffers(1, @ptrCast(&tmp));
        // Restore unit-quad VBO binding for rect path.
        gl.glBindVertexArray(self.vao);
        gl.glBindBuffer(gl.GL_ARRAY_BUFFER, self.vbo);
        gl.glEnableVertexAttribArray(0);
        gl.glVertexAttribPointer(0, 2, gl.GL_FLOAT, gl.GL_FALSE, 4 * @sizeOf(f32), @ptrFromInt(0));
        gl.glEnableVertexAttribArray(1);
        gl.glVertexAttribPointer(1, 2, gl.GL_FLOAT, gl.GL_FALSE, 4 * @sizeOf(f32), @ptrFromInt(2 * @sizeOf(f32)));
        gl.glBindVertexArray(0);
        gl.glBindTexture(gl.GL_TEXTURE_2D, 0);
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

    /// Primary text path: PangoLayout -> cairo ARGB32 -> RGBA GL texture.
    /// Never crashes: any C null / oversized run / test mode falls back to
    /// stb atlas (drawTextStb) or rects. LRU-cached (text_cache): static
    /// labels hit the cache and become GPU blits — no Pango, no alloc, no
    /// upload. Misses render once, store, then draw (cache owns the tex).
    fn drawTextPango(self: *Renderer, win_w: i32, win_h: i32, bbox_x: f32, bbox_y: f32, text_bytes: []const u8, font_size: u16, clay_color: [4]f32) bool {
        if (comptime builtin.is_test) return false;
        if (text_bytes.len == 0 or text_bytes.len > pango_max_bytes) return false;
        const fs: u16 = if (font_size == 0) 16 else font_size;

        // Cheap pure hash first — hits skip Pango measure + render entirely.
        const key = hashTextKey(text_bytes, fs, clay_color);
        self.text_cache_clock += 1;
        for (&self.text_cache) |*e| {
            if (e.valid and e.hash == key and e.tex != 0) {
                e.last_used = self.text_cache_clock;
                self.text_cache_hits += 1;
                self.drawRgbaQuad(e.tex, win_w, win_h, bbox_x, bbox_y, @floatFromInt(e.w), @floatFromInt(e.h));
                gl.glBindTexture(gl.GL_TEXTURE_2D, 0);
                return true;
            }
        }
        self.text_cache_misses += 1;

        const ext = text.measureText(text_bytes, fs);
        var iw: i32 = @intFromFloat(@ceil(ext.w));
        var ih: i32 = @intFromFloat(@ceil(ext.h));
        if (iw <= 0 or ih <= 0) return true; // empty but measured — nothing to draw
        if (iw > pango_max_w or ih > pango_max_h) return false;
        iw = @max(iw, 1);
        ih = @max(ih, 1);

        var desc_buf: [128]u8 = undefined;
        const desc_str = text.pangoDescInto(&desc_buf, fs) orelse return false;
        const rgba = clayToCairo(clay_color);

        var stride: c_int = 0;
        const surface = shim.glinlandui_text_render(iw, ih, @ptrCast(text_bytes.ptr), @intCast(text_bytes.len), desc_str, rgba[0], rgba[1], rgba[2], rgba[3], &stride) orelse return false;
        defer shim.glinlandui_surface_destroy(surface);
        if (stride < iw * 4) return false;
        const src_ptr = shim.glinlandui_surface_data(surface) orelse return false;
        const src: [*]const u8 = @ptrCast(src_ptr);
        const src_len: usize = @intCast(stride * ih);

        // Un-premultiply BGRA (cairo native LE) -> straight RGBA for GL.
        const out = self.alloc.alloc(u8, src_len) catch return false;
        defer self.alloc.free(out);
        var y: i32 = 0;
        while (y < ih) : (y += 1) {
            const row: usize = @intCast(y * stride);
            var x: i32 = 0;
            while (x < iw) : (x += 1) {
                const o: usize = row + @as(usize, @intCast(x * 4));
                const b = src[o + 0];
                const g = src[o + 1];
                const r = src[o + 2];
                const a = src[o + 3];
                if (a == 0) {
                    out[o + 0] = 0;
                    out[o + 1] = 0;
                    out[o + 2] = 0;
                    out[o + 3] = 0;
                } else if (a == 255) {
                    out[o + 0] = r;
                    out[o + 1] = g;
                    out[o + 2] = b;
                    out[o + 3] = 255;
                } else {
                    const af: f32 = @as(f32, @floatFromInt(a)) / 255.0;
                    out[o + 0] = @intFromFloat(@min(@as(f32, @floatFromInt(r)) / af, 255.0));
                    out[o + 1] = @intFromFloat(@min(@as(f32, @floatFromInt(g)) / af, 255.0));
                    out[o + 2] = @intFromFloat(@min(@as(f32, @floatFromInt(b)) / af, 255.0));
                    out[o + 3] = a;
                }
            }
        }

        var tex: c_uint = 0;
        gl.glGenTextures(1, @ptrCast(&tex));
        if (tex == 0) return false;
        gl.glBindTexture(gl.GL_TEXTURE_2D, tex);
        gl.glPixelStorei(gl.GL_UNPACK_ALIGNMENT, 4);
        gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA, iw, ih, 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, @ptrCast(out.ptr));
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);
        // Store in LRU (evict oldest, deleting its GL texture), then draw.
        // Cache owns tex from here — no delete-after-draw.
        if (lruVictim(&self.text_cache)) |idx| {
            const ev = &self.text_cache[idx];
            if (ev.valid and ev.tex != 0) {
                var old = ev.tex;
                gl.glDeleteTextures(1, @ptrCast(&old));
            }
            ev.* = .{ .hash = key, .tex = tex, .w = iw, .h = ih, .valid = true, .last_used = self.text_cache_clock };
        } else {
            var t = tex;
            gl.glDeleteTextures(1, @ptrCast(&t));
            return false;
        }
        self.drawRgbaQuad(tex, win_w, win_h, bbox_x, bbox_y, @floatFromInt(iw), @floatFromInt(ih));
        gl.glBindTexture(gl.GL_TEXTURE_2D, 0);
        return true;
    }

    /// Max source side accepted for decode (refuse absurd headers before
    /// allocating).
    const img_max_side: c_int = 8192;
    /// Per-frame decode budget (see img_decodes_this_frame).
    const img_decode_budget: u32 = 2;
    /// Placeholder fill while an image loads/fails (neutral dark).
    const img_placeholder: u32 = 0x1a1a1a;

    /// Decode path (NUL-terminated) via stb, downscale to max_dim, upload
    /// as an RGBA GL texture. Returns tex + decoded dims. Exe-only (the
    /// stb TU links into the module, not standalone test roots — callers
    /// never reach here in tests).
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

    /// Lookup-or-decode an image texture (LRU). Misses beyond the
    /// per-frame budget return null so the caller keeps the placeholder
    /// until the next frame.
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

    /// Draw an RGBA texture with custom UVs (temp VBO, prog_pango —
    /// same pattern as drawGlyph's per-glyph UV path).
    fn drawImageQuad(self: *Renderer, tex: c_uint, win_w: i32, win_h: i32, x: f32, y: f32, w: f32, h: f32, uv: [4]f32) void {
        if (w <= 0 or h <= 0 or tex == 0) return;
        const prog = self.prog_pango;
        gl.glUseProgram(prog);
        gl.glActiveTexture(gl.GL_TEXTURE0);
        gl.glBindTexture(gl.GL_TEXTURE_2D, tex);
        if (self.loc_pango_tex >= 0) gl.glUniform1i(self.loc_pango_tex, 0);
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
        if (self.loc_pango_res >= 0) gl.glUniform2f(self.loc_pango_res, rw, rh);
        if (self.loc_pango_pos >= 0) gl.glUniform2f(self.loc_pango_pos, x, y);
        if (self.loc_pango_size >= 0) gl.glUniform2f(self.loc_pango_size, w, h);
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

    /// Draw one Clay IMAGE command: cache lookup, fit-mapped blit, or a
    /// placeholder rect while loading/failed. Tests return early (no GL).
    fn drawImageCmd(self: *Renderer, win_w: i32, win_h: i32, bb_x: f32, bb_y: f32, bb_w: f32, bb_h: f32, ref: *const ImageRef) void {
        if (comptime builtin.is_test) return;
        if (bb_w <= 0 or bb_h <= 0) return;
        const path = ref.path_ptr[0..ref.path_len];
        const max_dim: u16 = if (ref.max_dim == 0) 256 else ref.max_dim;
        const t = self.imageTexture(path, max_dim) orelse {
            self.drawRectCmd(win_w, win_h, bb_x, bb_y, bb_w, bb_h, u32ToClayColor(img_placeholder), .{});
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
                self.drawRectCmd(win_w, win_h, bb_x, bb_y, bb_w, bb_h, u32ToClayColor(img_placeholder), .{});
                const b = containBox(iw, ih, bb_w, bb_h);
                self.drawImageQuad(t.tex, win_w, win_h, bb_x + b[0], bb_y + b[1], b[2], b[3], .{ 0, 0, 1, 1 });
            },
            .stretch => {
                self.drawImageQuad(t.tex, win_w, win_h, bb_x, bb_y, bb_w, bb_h, .{ 0, 0, 1, 1 });
            },
        }
    }

    /// stb fallback: fixed-advance atlas blits (ASCII 32..126).
    fn drawTextStb(self: *Renderer, win_w: i32, win_h: i32, bbox_x: f32, bbox_y: f32, text_bytes: []const u8, font_size: u16, clay_color: [4]f32) void {
        if (text_bytes.len == 0) return;
        if (!self.has_atlas or !self.has_font) {
            self.drawTextFallback(win_w, win_h, bbox_x, bbox_y, text_bytes, font_size, clay_color);
            return;
        }
        const fs: f32 = @floatFromInt(if (font_size == 0) 16 else font_size);
        const scale = stb.stbtt_ScaleForPixelHeight(&self.font_info, fs);
        var ascent: c_int = 0;
        var descent: c_int = 0;
        var line_gap: c_int = 0;
        stb.stbtt_GetFontVMetrics(&self.font_info, &ascent, &descent, &line_gap);
        const baseline = bbox_y + @as(f32, @floatFromInt(ascent)) * scale;
        const adv = estimatorAdvance(if (font_size == 0) 16 else font_size);
        var cursor: f32 = 0;
        const aw: f32 = @floatFromInt(atlas_w);
        const ah: f32 = @floatFromInt(atlas_h);
        for (text_bytes) |ch| {
            if (ch < 32 or ch > 126) {
                cursor += adv;
                continue;
            }
            const bc = self.baked[ch - 32];
            const gw: f32 = @floatFromInt(bc.x1 - bc.x0);
            const gh: f32 = @floatFromInt(bc.y1 - bc.y0);
            if (gw > 0 and gh > 0) {
                const dx = bbox_x + cursor + @as(f32, bc.xoff);
                const dy = baseline + @as(f32, bc.yoff);
                self.drawGlyph(win_w, win_h, dx, dy, gw, gh, @as(f32, @floatFromInt(bc.x0)) / aw, @as(f32, @floatFromInt(bc.y0)) / ah, @as(f32, @floatFromInt(bc.x1)) / aw, @as(f32, @floatFromInt(bc.y1)) / ah, clay_color);
            }
            cursor += adv;
        }
    }

    fn drawTextCmd(self: *Renderer, win_w: i32, win_h: i32, bbox_x: f32, bbox_y: f32, text_bytes: []const u8, font_size: u16, clay_color: [4]f32) void {
        if (text_bytes.len == 0) return;
        // Primary: pangocairo. Falls back to stb atlas, then rects.
        if (self.drawTextPango(win_w, win_h, bbox_x, bbox_y, text_bytes, font_size, clay_color)) return;
        // drawTextPango returns false in tests / on C failure — but it
        // returns true for empty-after-measure (nothing to draw). Only
        // reach stb when Pango genuinely declined.
        if (comptime builtin.is_test) {
            self.drawTextFallback(win_w, win_h, bbox_x, bbox_y, text_bytes, font_size, clay_color);
            return;
        }
        // If Pango declined because the run was empty-but-measured, don't
        // double-draw via stb: re-check measured width.
        const ext = text.measureText(text_bytes, if (font_size == 0) 16 else font_size);
        if (ext.w <= 0) return;
        self.drawTextStb(win_w, win_h, bbox_x, bbox_y, text_bytes, font_size, clay_color);
    }

    /// Draw a full Clay render-command list. Handles .rectangle, .border,
    /// .text, .image, .scissor_start/.scissor_end; ignores .custom/.none.
    pub fn drawCommands(self: *Renderer, commands: []cl.RenderCommand, win_w: i32, win_h: i32) void {
        gl.glViewport(0, 0, win_w, win_h);
        gl.glDisable(gl.GL_SCISSOR_TEST);
        gl.glEnable(gl.GL_BLEND);
        // Separate alpha factors: the window is opaque (glClear alpha 1.0),
        // so keep the destination alpha saturated. With the plain
        // glBlendFunc the alpha of partially covered (AA) pixels fell
        // below 1.0 and the compositor blended the wallpaper through
        // them -> 1px borders/dividers picked up the backdrop's color.
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
                    self.drawTextCmd(win_w, win_h, bb.x, bb.y, bytes, td.font_size, td.text_color);
                },
                .scissor_start => {
                    const bb = cmd.bounding_box;
                    gl.glEnable(gl.GL_SCISSOR_TEST);
                    const sx: c_int = @intFromFloat(@max(bb.x, 0));
                    const sw: c_int = @intFromFloat(@max(bb.width, 0));
                    // GL origin is bottom-left; Clay is top-left.
                    const top: f32 = bb.y + bb.height;
                    const sy: c_int = @intFromFloat(@max(@as(f32, @floatFromInt(win_h)) - top, 0));
                    const sh: c_int = @intFromFloat(@max(bb.height, 0));
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

test "clayToCairo normalizes 0-255 and passes through 0-1" {
    const c255 = clayToCairo(.{ 255, 128, 0, 255 });
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), c255[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 128.0 / 255.0), c255[1], 1e-6);
    const c1 = clayToCairo(.{ 1, 1, 1, 1 });
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), c1[0], 1e-6);
}

test "hashTextKey differs by bytes/size/color" {
    const a = hashTextKey("Settings", 18, .{ 232, 232, 232, 255 });
    try std.testing.expectEqual(a, hashTextKey("Settings", 18, .{ 232, 232, 232, 255 }));
    try std.testing.expect(hashTextKey("Settings", 16, .{ 232, 232, 232, 255 }) != a);
    try std.testing.expect(hashTextKey("Setting", 18, .{ 232, 232, 232, 255 }) != a);
    try std.testing.expect(hashTextKey("Settings", 18, .{ 255, 0, 0, 255 }) != a);
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
    // Regression: the 2px smoothstep(-1,1,d) band spread a 1px border over
    // two pixels (~0.7 + ~0.16 alpha) and eroded rounded corners, so row
    // outlines looked washed out and the radius felt off. Coverage is now
    // the 1px box-filter clamp: a 1px border lands on exactly one fully
    // opaque pixel and corners keep their nominal radius.
    try std.testing.expect(std.mem.indexOf(u8, rect_frag_src, "clamp(0.5 - d, 0.0, 1.0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, rect_frag_src, "smoothstep(-1.0, 1.0,") == null);
    // Both the outer shape and the border's inner cut use it.
    try std.testing.expect(std.mem.indexOf(u8, rect_frag_src, "float a = cov(d);") != null);
    try std.testing.expect(std.mem.indexOf(u8, rect_frag_src, "float a2 = cov(d2);") != null);
}
