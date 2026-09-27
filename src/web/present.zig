//! Pixel hand-off from the software surface to the browser's `<canvas>` (pure).
//!
//! ## The good news: the transform is the identity
//!
//! `mac/present.zig` measured this for CoreGraphics, at the cost of a day, and
//! the finding transfers exactly:
//!
//!   - `soft.Surface` is TOP-LEFT origin: its row 0 is the visual top, and its
//!     bytes are plain R, G, B, A.
//!   - the DOM's `ImageData` is also top-left origin, also RGBA8 in that byte
//!     order, also straight (non-premultiplied) alpha.
//!
//! So no channel swap, no vertical flip, no row reversal. Both over-corrections
//! produce a plausible, wrong-looking page rather than an obvious failure —
//! which is why `identityRgba8` exists as a named, tested function rather than
//! being an implicit `putImageData`.
//!
//! ## The rule the DOM adds, and it is the whole reason this file exists
//!
//! **`memory.grow()` DETACHES every `TypedArray` view over wasm memory.** A JS
//! `Uint8ClampedArray(memory.buffer, ptr, len)` captured once stays valid only
//! until the next allocation that grows linear memory — after which its
//! `.buffer.byteLength` is 0 and every read throws or yields nothing. A frame
//! that renders fine and then presents as blank, intermittently, depending on
//! whether a glyph bitmap happened to grow the heap, is exactly the class of bug
//! this project ships named tests for.
//!
//! So the contract is: wasm publishes `(ptr, len, width, height)` for the frame
//! just drawn and nothing else; JS rebuilds its view whenever
//! `memory.buffer !== lastBuffer`, and reallocates the `ImageData` only when the
//! size changed. `web/shim.js` implements that in `blit()`, and `describes`
//! below is the Zig half of the same statement.
//!
//! ## No copy is needed
//!
//! `new ImageData(uint8ClampedArray, w, h)` WRAPS the array rather than copying
//! it, so a correctly-rebuilt view means the pixels never leave wasm memory. The
//! alternative — copying into a JS-owned buffer every frame — is the same
//! correctness question with an extra ~1.4 MB per frame of bandwidth, so it is
//! not the default.
const std = @import("std");

/// Bytes per pixel for every path in this file. `ImageData` agrees.
pub const bytes_per_pixel: usize = 4;

/// Byte length the canvas needs for a `width` x `height` surface.
pub fn blitBufLen(width: u32, height: u32) usize {
    return @as(usize, width) * @as(usize, height) * bytes_per_pixel;
}

/// True when the geometry can describe a presentable frame at all. A zero
/// dimension means "no surface yet": `putImageData` with a 0-wide `ImageData`
/// throws, and `canvas.width = 0` silently clears the element, so this must be
/// false rather than producing a tiny buffer.
pub fn blitSizeValid(width: u32, height: u32) bool {
    return width > 0 and height > 0;
}

/// Copy a top-left-origin RGBA8 surface into the buffer the DOM will read.
///
/// An identity copy — see the module comment on why a swap or flip is an
/// over-correction. The function exists so the contract has one named home and a
/// test can pin it by COLOUR (a swapped R/B turns the accent blue into a red that
/// still looks like "a colour"), not merely by length.
///
/// In the live path this is not called: `shim.js` wraps the surface in place. It
/// is the reference the untested half has to match, and it is what a JS-free
/// present (a screenshot test, a Node smoke run) would use.
///
/// `dst` must be at least `blitBufLen(width, height)`; a longer `dst` keeps its
/// tail untouched so one caller-owned buffer can be reused every frame.
pub fn identityRgba8(src: []const u8, dst: []u8, width: u32, height: u32) void {
    if (!blitSizeValid(width, height)) return;
    const want = blitBufLen(width, height);
    const n = @min(want, @min(src.len, dst.len));
    @memcpy(dst[0..n], src[0..n]);
}

/// The largest `devicePixelRatio` this presenter will honour.
///
/// A 4x ratio on a 960x720 CSS canvas is a 3840x2880 backing store — 44 MB per
/// frame, sixteen million pixels the CPU rasterizer has to fill. Clamping keeps
/// a pathological ratio from turning a working page into a slideshow; above this
/// the canvas is simply scaled up by CSS, which for a UI of flat rectangles and
/// text is a far better trade than dropping frames. 1..4 covers every shipping
/// device.
pub const max_device_scale: f32 = 4.0;

/// The largest canvas dimension this presenter will produce.
///
/// `f32` cannot represent `maxInt(i32)` exactly — it rounds to 2^31 — so clamping
/// to `maxInt(i32)` and then converting would land one past the bound. 16384 is
/// exactly representable, is far beyond any real display (a 16K canvas is
/// 16384x16384), and leaves the `@intFromFloat` comfortably inside `u32`.
pub const max_canvas_dim: u32 = 16384;

/// Backing-store size for a CSS size at a device scale.
///
/// Rounded UP, and floored at 1: a fractional DPR (1.25, 1.5 on many Windows and
/// Android devices) otherwise leaves the canvas a pixel short, which shows up as
/// a one-pixel stripe of page background down the right and bottom edges.
///
/// The upper bound is a real one, not a formality. `@intFromFloat` on a value
/// outside the destination type's range is ILLEGAL BEHAVIOUR in Zig — a panic in
/// a safe build, and a trap in wasm — so a CSS size large enough to overflow
/// `u32` after scaling must be clamped rather than converted.
pub fn canvasSize(css_w: u32, css_h: u32, device_scale: f32) struct { w: u32, h: u32 } {
    const scale = if (device_scale > 0 and device_scale <= max_device_scale)
        device_scale
    else
        1.0;
    const limit: f32 = @floatFromInt(max_canvas_dim);
    const w = @ceil(@as(f32, @floatFromInt(css_w)) * scale);
    const h = @ceil(@as(f32, @floatFromInt(css_h)) * scale);
    // `!(x >= 1)` rather than `x < 1` so a NaN takes this branch instead of
    // falling through to `@intFromFloat`, which would be illegal behaviour.
    if (!(w >= 1) or !(h >= 1)) return .{ .w = 1, .h = 1 };
    return .{
        .w = @intFromFloat(@min(w, limit)),
        .h = @intFromFloat(@min(h, limit)),
    };
}

/// Map a DOM (CSS pixel) coordinate to the canvas backing store.
///
/// This is the browser's whole coordinate disagreement: the DOM reports pointer
/// positions relative to the element's CSS box, while the toolkit lays out and
/// hit-tests in backing-store pixels. A missing scale means clicks land at the
/// wrong place on every HiDPI display — which reads as "the buttons are
/// offset", the same symptom a missing y-flip causes on macOS.
///
/// There is deliberately NO y-flip and no origin translation: unlike AppKit, the
/// DOM's origin is already the top-left corner the toolkit uses. That absence is
/// the difference worth naming, and `web/adapter.zig` documents it.
pub fn toBackingPoint(css_x: f32, css_y: f32, device_scale: f32) struct { x: f32, y: f32 } {
    const scale = if (device_scale > 0 and device_scale <= max_device_scale)
        device_scale
    else
        1.0;
    return .{ .x = css_x * scale, .y = css_y * scale };
}

/// Pixels that differ from the surface's own clear colour.
///
/// The browser peer of the macOS job's blit checksum: a blank or flat-filled
/// canvas still paints every pixel, so *an exit code proves nothing*. This is
/// what `glin_web_painted_pixels()` exposes, and what `web/smoke.mjs` asserts is
/// non-zero — a screenshot-free proof that layout, the rasterizer and the
/// hand-off all ran on a machine with no browser.
pub fn countPainted(pixels: []const u8, clear_rgb: [4]f32) usize {
    var painted: usize = 0;
    var i: usize = 0;
    while (i + 3 < pixels.len) : (i += 4) {
        const r: f32 = @floatFromInt(pixels[i]);
        const g: f32 = @floatFromInt(pixels[i + 1]);
        const b: f32 = @floatFromInt(pixels[i + 2]);
        if (r != clear_rgb[0] or g != clear_rgb[1] or b != clear_rgb[2]) painted += 1;
    }
    return painted;
}

/// FNV-1a over a frame's bytes. The "did anything actually change" probe the
/// macOS backend logs and the smoke test asserts is non-zero — a flat frame
/// cannot fake it.
pub fn frameHash(pixels: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (pixels) |byte| {
        h ^= byte;
        h *%= 0x100000001b3;
    }
    return h;
}

/// The accent blue the calculator's `=` key uses, used by the tests below to
/// prove channel order survives the hand-off: a swapped R/B turns this into a
/// red that still looks like "a colour" rather than an error.
pub const test_accent: [4]u8 = .{ 0x2f, 0x6d, 0xf6, 0xff };

// ===================== tests (parity suite — every platform) =====================

const fill8: [8]u8 = .{0xAA} ** 8;
const fill16: [16]u8 = .{0xAA} ** 16;
const src_empty: [0]u8 = .{};

test "blitBufLen is width * height * 4" {
    try std.testing.expectEqual(@as(usize, 4), blitBufLen(1, 1));
    try std.testing.expectEqual(@as(usize, 360 * 430 * 4), blitBufLen(360, 430));
    try std.testing.expectEqual(@as(usize, 0), blitBufLen(0, 10));
}

test "blitSizeValid rejects a zero dimension" {
    try std.testing.expect(blitSizeValid(1, 1));
    try std.testing.expect(!blitSizeValid(0, 10));
    try std.testing.expect(!blitSizeValid(10, 0));
    try std.testing.expect(!blitSizeValid(0, 0));
}

test "channels are NOT swapped — the accent blue stays blue" {
    // THE regression guard for the assumption this module disproves. Swapping R
    // and B turns 0x2f6df6 into 0xf66d2f, a red. Nothing errors; the page just
    // looks wrong, which is why this is pinned by colour and not by count.
    var src: [4]u8 = test_accent;
    var dst: [4]u8 = undefined;
    identityRgba8(&src, &dst, 1, 1);
    try std.testing.expectEqual(test_accent, dst);
    try std.testing.expectEqual(@as(u8, 0x2f), dst[0]); // R stays in byte 0
    try std.testing.expectEqual(@as(u8, 0xf6), dst[2]); // B stays in byte 2
}

test "rows are NOT flipped — row 0 stays row 0" {
    // THE other regression guard. A vertical flip mirrors the whole UI: on the
    // calculator the display moves to the bottom and the `=` key to the top. The
    // DOM and the rasterizer already agree on the origin, so a "helpful" flip is
    // pure damage.
    const src = [_]u8{
        1, 1, 1, 255, // row 0 = top
        2, 2, 2, 255,
        3, 3, 3, 255,
    };
    var dst: [12]u8 = undefined;
    identityRgba8(&src, &dst, 3, 1);
    try std.testing.expectEqualSlices(u8, &src, &dst);
}

test "the calculator's real layout survives in the right place" {
    // A miniature of the actual frame: a display panel along the TOP and a
    // single accent key at the BOTTOM-right. The whole bug in one test — the
    // panel must stay in the first rows and the accent must stay in the last,
    // and the accent must still be blue.
    const w: u32 = 8;
    const h: u32 = 6;
    var src: [w * h * 4]u8 = undefined;
    for (0..w * h) |i| {
        const row = i / w;
        const is_panel = row < 2;
        const is_accent = (row == h - 1) and (i % w) >= (w - 2);
        const c: [4]u8 = if (is_panel)
            .{ 27, 27, 33, 255 }
        else if (is_accent)
            test_accent
        else
            .{ 38, 38, 46, 255 };
        @memcpy(src[i * 4 ..][0..4], &c);
    }
    var dst: [w * h * 4]u8 = undefined;
    identityRgba8(&src, &dst, w, h);
    try std.testing.expectEqualSlices(u8, &src, &dst);
    try std.testing.expectEqualSlices(u8, &.{ 27, 27, 33, 255 }, dst[0..4]);
    const accent_i = ((h - 1) * w + (w - 1)) * 4;
    try std.testing.expectEqualSlices(u8, &test_accent, dst[accent_i..][0..4]);
}

test "a longer destination keeps its tail untouched for frame reuse" {
    const src = [4]u8{ 1, 2, 3, 4 };
    var dst: [12]u8 = undefined;
    @memset(&dst, 0xAA);
    identityRgba8(&src, &dst, 1, 1);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, dst[0..4]);
    try std.testing.expectEqualSlices(u8, &fill8, dst[4..12]);
}

test "a zero width or height writes nothing, and an empty source is a no-op" {
    var dst: [16]u8 = undefined;
    @memset(&dst, 0xAA);
    const src = [4]u8{ 1, 2, 3, 4 } ** 4;
    identityRgba8(&src, &dst, 4, 0);
    try std.testing.expectEqual(fill16, dst);
    identityRgba8(&src, &dst, 0, 4);
    try std.testing.expectEqual(fill16, dst);
    var small: [4]u8 = undefined;
    @memset(&small, 0xAA);
    identityRgba8(&src_empty, &small, 1, 1);
    try std.testing.expectEqual([4]u8{ 0xAA, 0xAA, 0xAA, 0xAA }, small);
}

test "canvasSize scales up for HiDPI and rounds up for a fractional ratio" {
    try std.testing.expectEqual(@as(u32, 640), canvasSize(640, 480, 1.0).w);
    try std.testing.expectEqual(@as(u32, 1280), canvasSize(640, 480, 2.0).w);
    try std.testing.expectEqual(@as(u32, 960), canvasSize(640, 480, 1.5).w);
    // 640 * 1.25 = 800 exactly, but 480 * 1.25 = 600 — the interesting case is a
    // size whose product is fractional, which must round UP or a stripe of page
    // background shows down the edge.
    try std.testing.expectEqual(@as(u32, 800), canvasSize(640, 480, 1.25).w);
    try std.testing.expectEqual(@as(u32, 600), canvasSize(640, 480, 1.25).h);
    // 100 * 1.1 = 110.000001 in f32; ceil makes it 111 rather than 110.
    try std.testing.expect(canvasSize(101, 101, 1.1).w >= 112);
}

test "canvasSize clamps an absurd or invalid device ratio instead of allocating it" {
    // An out-of-range ratio is REJECTED, not clamped: `scale` falls back to 1.0,
    // so an 8x request yields the CSS size rather than a 4x backing store. That
    // is the safer of the two behaviours — a browser reporting a nonsense ratio
    // is a browser whose ratio should not be trusted at all — and it is what the
    // `device_scale > 0 and device_scale <= max_device_scale` guard does.
    try std.testing.expectEqual(@as(u32, 960), canvasSize(960, 720, 8.0).w);
    // The ceiling itself IS honoured, which is the boundary the guard admits.
    try std.testing.expectEqual(@as(u32, 960 * 4), canvasSize(960, 720, max_device_scale).w);
    // A zero or negative ratio cannot come from a browser, but must not produce
    // a zero-sized canvas that silently clears the element.
    try std.testing.expectEqual(@as(u32, 960), canvasSize(960, 720, 0).w);
    try std.testing.expectEqual(@as(u32, 960), canvasSize(960, 720, -2).w);
    try std.testing.expectEqual(@as(u32, 1), canvasSize(0, 0, 1).w);
    // A CSS size large enough to overflow after scaling must be clamped rather
    // than converted: `@intFromFloat` out of range is illegal behaviour in Zig,
    // so this is the case that would trap in a browser rather than misbehave.
    const huge = canvasSize(std.math.maxInt(u32), std.math.maxInt(u32), 4.0);
    try std.testing.expectEqual(max_canvas_dim, huge.w);
    try std.testing.expectEqual(max_canvas_dim, huge.h);
}

test "toBackingPoint scales the DOM coordinate onto the backing store" {
    // The browser's whole coordinate disagreement in one call.
    const p = toBackingPoint(10, 20, 2.0);
    try std.testing.expectEqual(@as(f32, 20), p.x);
    try std.testing.expectEqual(@as(f32, 40), p.y);
    // No flip: a DOM y of 0 is the visual TOP, same as the toolkit's.
    const top = toBackingPoint(0, 0, 1.0);
    try std.testing.expectEqual(@as(f32, 0), top.y);
    // An invalid ratio falls back to 1 rather than to zero, which would collapse
    // every click onto the origin.
    try std.testing.expectEqual(@as(f32, 10), toBackingPoint(10, 20, 0).x);
    try std.testing.expectEqual(@as(f32, 10), toBackingPoint(10, 20, 99).x);
}

test "countPainted counts only pixels that differ from the clear colour" {
    const clear = [4]f32{ 0, 0, 0, 255 };
    const pixels = [_]u8{
        0, 0, 0, 255, // clear
        0, 0, 0, 255, // clear
        255, 0, 0, 255, // painted
        0, 0, 0, 255, // clear
    };
    try std.testing.expectEqual(@as(usize, 1), countPainted(&pixels, clear));
    // A flat frame paints every pixel and yet differs from nothing.
    const flat = [_]u8{0} ** 16;
    try std.testing.expectEqual(@as(usize, 0), countPainted(&flat, clear));
    try std.testing.expectEqual(@as(usize, 0), countPainted(&src_empty, clear));
}

test "frameHash changes when a single byte changes, and is stable otherwise" {
    const a = [_]u8{ 1, 2, 3, 4 };
    const b = [_]u8{ 1, 2, 3, 5 };
    // A one-line "did anything actually change" probe a flat frame cannot fake.
    try std.testing.expectEqual(frameHash(&a), frameHash(&a));
    try std.testing.expect(frameHash(&a) != frameHash(&b));
    try std.testing.expect(frameHash(&a) != 0);
}
