//! Shared pixel-assertion suite — runs identically on Linux and macOS.
//!
//! Every test here inspects REAL BYTES in a software framebuffer produced by
//! `render_software.zig`. This is the suite that proves the renderer draws
//! the pixels the design intends, on both platforms, with the same expected
//! values. It is the reason the test counts can be equal across OSes: the
//! rendering being tested has no platform-specific code path.
//!
//! Convention: integer-aligned geometry + radius 0 => bit-exact 8-bit results
//! (the 1px coverage band yields cov=1.0 inside and 0.0 outside). Fractional
//! geometry lands mid-ramp and is asserted with a tolerance.
const std = @import("std");
const cl = @import("zclay");
const soft = @import("render_software.zig");

const Surface = soft.Surface;
const noRadius = [4]f32{ 0, 0, 0, 0 };

fn rectCmd(x: f32, y: f32, w: f32, h: f32, color: [4]f32) cl.RenderCommand {
    return .{
        .bounding_box = .{ .x = x, .y = y, .width = w, .height = h },
        .render_data = .{ .rectangle = .{ .background_color = color, .corner_radius = .{} } },
        .user_data = null,
        .id = 0,
        .z_index = 0,
        .command_type = .rectangle,
    };
}

fn roundRectCmd(
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    radius: cl.CornerRadius,
    color: [4]f32,
) cl.RenderCommand {
    var c = rectCmd(x, y, w, h, color);
    c.render_data.rectangle.corner_radius = radius;
    return c;
}

fn borderCmd(
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    width: cl.BorderWidth,
    color: [4]f32,
) cl.RenderCommand {
    return .{
        .bounding_box = .{ .x = x, .y = y, .width = w, .height = h },
        .render_data = .{ .border = .{
            .color = color,
            .corner_radius = .{},
            .width = width,
        } },
        .user_data = null,
        .id = 0,
        .z_index = 0,
        .command_type = .border,
    };
}

fn scissorCmd(x: f32, y: f32, w: f32, h: f32, start: bool) cl.RenderCommand {
    return .{
        .bounding_box = .{ .x = x, .y = y, .width = w, .height = h },
        .render_data = .{ .scroll = .{ .horizontal = true, .vertical = true } },
        .user_data = null,
        .id = 0,
        .z_index = 0,
        .command_type = if (start) .scissor_start else .scissor_end,
    };
}

fn surface(w: u32, h: u32) !Surface {
    var s = try Surface.init(std.testing.allocator, w, h);
    s.setClearColor(.{ 0, 0, 0, 255 });
    s.clear();
    return s;
}

fn expectPx(s: Surface, x: i64, y: i64, expect: [4]u8) !void {
    const got = s.px(x, y);
    try std.testing.expectEqualDeep(expect, got);
}

fn expectPxNear(s: Surface, x: i64, y: i64, expect: [4]u8, tol: i32) !void {
    const got = s.px(x, y);
    for (0..4) |c| {
        try std.testing.expect(@abs(@as(i32, got[c]) - @as(i32, expect[c])) <= tol);
    }
}

// ---- rectangle fill ----

test "pixel: integer rect fills exactly its pixel box, zero AA leakage" {
    var s = try surface(32, 32);
    defer s.deinit();
    var cmds = [_]cl.RenderCommand{rectCmd(10, 10, 4, 4, .{ 255, 0, 0, 255 })};
    s.renderCommands(&cmds);

    // Every interior pixel is the exact source color.
    try expectPx(s, 10, 10, .{ 255, 0, 0, 255 });
    try expectPx(s, 13, 13, .{ 255, 0, 0, 255 });
    try expectPx(s, 11, 12, .{ 255, 0, 0, 255 });
    // Just outside on all four sides is untouched.
    try expectPx(s, 9, 10, .{ 0, 0, 0, 255 });
    try expectPx(s, 14, 10, .{ 0, 0, 0, 255 });
    try expectPx(s, 10, 9, .{ 0, 0, 0, 255 });
    try expectPx(s, 10, 14, .{ 0, 0, 0, 255 });
    // The four diagonal corners are also untouched.
    try expectPx(s, 9, 9, .{ 0, 0, 0, 255 });
    try expectPx(s, 14, 14, .{ 0, 0, 0, 255 });
}

test "pixel: degenerate rect (zero w or h) draws nothing" {
    var s = try surface(16, 16);
    defer s.deinit();
    var cmds = [_]cl.RenderCommand{
        rectCmd(4, 4, 0, 6, .{ 255, 0, 0, 255 }),
        rectCmd(4, 4, 6, 0, .{ 255, 0, 0, 255 }),
    };
    s.renderCommands(&cmds);
    for (0..16) |y| {
        for (0..16) |x| {
            try expectPx(s, @intCast(x), @intCast(y), .{ 0, 0, 0, 255 });
        }
    }
}

test "pixel: rect alpha blends straight-alpha over the clear color" {
    var s = try surface(8, 8);
    defer s.deinit();
    // 50% white over opaque black => ~128, 128, 128.
    var cmds = [_]cl.RenderCommand{rectCmd(0, 0, 8, 8, .{ 255, 255, 255, 128 })};
    s.renderCommands(&cmds);
    const p = s.px(4, 4);
    try std.testing.expectEqual(@as(u8, 128), p[0]);
    try std.testing.expectEqual(@as(u8, 128), p[1]);
    try std.testing.expectEqual(@as(u8, 128), p[2]);
    try std.testing.expectEqual(@as(u8, 255), p[3]);
}

test "pixel: later commands paint over earlier ones in slice order" {
    var s = try surface(16, 16);
    defer s.deinit();
    var cmds = [_]cl.RenderCommand{
        rectCmd(0, 0, 16, 16, .{ 255, 0, 0, 255 }),
        rectCmd(4, 4, 8, 8, .{ 0, 0, 255, 255 }),
    };
    s.renderCommands(&cmds);
    try expectPx(s, 1, 1, .{ 255, 0, 0, 255 });
    try expectPx(s, 8, 8, .{ 0, 0, 255, 255 });
}

// ---- corner radius ----

test "pixel: rounded rect leaves the extreme corner transparent and fills the centre" {
    var s = try surface(16, 16);
    defer s.deinit();
    var cmds = [_]cl.RenderCommand{
        roundRectCmd(0, 0, 8, 8, .all(4), .{ 0, 255, 0, 255 }),
    };
    s.renderCommands(&cmds);
    // The very corner of a radius-4 box is outside the rounded shape.
    try expectPx(s, 0, 0, .{ 0, 0, 0, 255 });
    // The centre is solid.
    try expectPx(s, 4, 4, .{ 0, 255, 0, 255 });
    try expectPx(s, 3, 4, .{ 0, 255, 0, 255 });
}

test "pixel: corner radius clamps to half the smallest side (pill, not ellipse)" {
    // An oversized radius (999) on a 20x8 box clamps to min(20,8)/2 = 4.
    var s = try surface(24, 16);
    defer s.deinit();
    var cmds = [_]cl.RenderCommand{
        roundRectCmd(2, 4, 20, 8, .all(999), .{ 0, 0, 255, 255 }),
    };
    s.renderCommands(&cmds);
    // The top-left extreme corner is cut away (radius clamped to 4).
    try expectPx(s, 2, 4, .{ 0, 0, 0, 255 });
    // A solidly-interior pixel is fully opaque. (The single pixel at the exact
    // vertical centre of the left edge is a partial-coverage arc pixel, so we
    // assert well inside the shape rather than on its 1px antialiased rim.)
    try expectPx(s, 12, 8, .{ 0, 0, 255, 255 });
    try expectPx(s, 8, 8, .{ 0, 0, 255, 255 });
}

// ---- border ----

test "pixel: uniform 2px border is a solid ring with a transparent interior" {
    var s = try surface(32, 32);
    defer s.deinit();
    var cmds = [_]cl.RenderCommand{
        borderCmd(8, 8, 16, 16, .outside(2), .{ 255, 255, 0, 255 }),
    };
    s.renderCommands(&cmds);
    // The ring.
    try expectPx(s, 8, 8, .{ 255, 255, 0, 255 });
    try expectPx(s, 23, 8, .{ 255, 255, 0, 255 });
    try expectPx(s, 8, 23, .{ 255, 255, 0, 255 });
    try expectPx(s, 23, 23, .{ 255, 255, 0, 255 });
    try expectPx(s, 16, 8, .{ 255, 255, 0, 255 });
    // The interior is NOT painted (alpha 0 => discarded), so the clear shows.
    try expectPx(s, 16, 16, .{ 0, 0, 0, 255 });
    try expectPx(s, 10, 16, .{ 0, 0, 0, 255 });
    // Just outside the outer edge is untouched.
    try expectPx(s, 7, 8, .{ 0, 0, 0, 255 });
    try expectPx(s, 24, 8, .{ 0, 0, 0, 255 });
}

test "pixel: 1px border is crisp (the regression the 1px coverage band exists for)" {
    var s = try surface(20, 20);
    defer s.deinit();
    var cmds = [_]cl.RenderCommand{
        borderCmd(4, 4, 12, 12, .outside(1), .{ 0, 255, 255, 255 }),
    };
    s.renderCommands(&cmds);
    // Exactly one fully-opaque pixel ring.
    try expectPx(s, 4, 4, .{ 0, 255, 255, 255 });
    try expectPx(s, 4, 5, .{ 0, 255, 255, 255 });
    // Second ring inward is interior (not painted).
    try expectPx(s, 5, 5, .{ 0, 0, 0, 255 });
    try expectPx(s, 10, 10, .{ 0, 0, 0, 255 });
}

test "pixel: border with mixed widths draws the top bar only when sides collapse" {
    var s = try surface(16, 16);
    defer s.deinit();
    // top=2, bottom=0, left=0, right=0 — not uniform, so the square-quad path
    // is used and only the top bar is drawn.
    var cmds = [_]cl.RenderCommand{
        borderCmd(2, 2, 12, 12, .{ .top = 2, .bottom = 0, .left = 0, .right = 0 }, .{ 255, 0, 255, 255 }),
    };
    s.renderCommands(&cmds);
    try expectPx(s, 8, 3, .{ 255, 0, 255, 255 }); // inside the top bar
    try expectPx(s, 8, 8, .{ 0, 0, 0, 255 }); // interior, no bottom/side bars
    try expectPx(s, 2, 8, .{ 0, 0, 0, 255 });
}

test "pixel: zero-width uniform border draws nothing" {
    var s = try surface(16, 16);
    defer s.deinit();
    var cmds = [_]cl.RenderCommand{
        borderCmd(2, 2, 12, 12, .outside(0), .{ 255, 0, 255, 255 }),
    };
    s.renderCommands(&cmds);
    try expectPx(s, 8, 8, .{ 0, 0, 0, 255 });
}

// ---- scissor ----

test "pixel: scissor_start clips drawing to its region" {
    var s = try surface(32, 32);
    defer s.deinit();
    var cmds = [_]cl.RenderCommand{
        scissorCmd(8, 8, 8, 8, true),
        rectCmd(0, 0, 32, 32, .{ 255, 0, 0, 255 }),
        scissorCmd(0, 0, 0, 0, false),
    };
    s.renderCommands(&cmds);
    // Inside the scissor: painted.
    try expectPx(s, 10, 10, .{ 255, 0, 0, 255 });
    try expectPx(s, 15, 15, .{ 255, 0, 0, 255 });
    // Outside the scissor: not painted.
    try expectPx(s, 7, 10, .{ 0, 0, 0, 255 });
    try expectPx(s, 16, 10, .{ 0, 0, 0, 255 });
    try expectPx(s, 10, 7, .{ 0, 0, 0, 255 });
}

test "pixel: a second scissor_start replaces (does not intersect) the region" {
    var s = try surface(32, 32);
    defer s.deinit();
    var cmds = [_]cl.RenderCommand{
        scissorCmd(0, 0, 16, 32, true),
        scissorCmd(16, 0, 16, 32, true), // replaces the first
        rectCmd(0, 0, 32, 32, .{ 255, 0, 0, 255 }),
    };
    s.renderCommands(&cmds);
    // Only the right half is painted.
    try expectPx(s, 20, 10, .{ 255, 0, 0, 255 });
    try expectPx(s, 5, 10, .{ 0, 0, 0, 255 });
}

// ---- text ----
//
// `drawTextRun` draws REAL glyphs when the host has a font it can parse, and
// falls back to one box per byte when it does not. Both paths are covered
// here: the fallback is deterministic and font-independent, so its pixel
// expectations are exact; the glyph path can only be asserted where a font
// exists, so it checks shape (ink present, above the baseline, none below) and
// lets the glyph unit tests in glyphs.zig pin the exact metrics.

test "pixel: the fallback path draws one deterministic box per byte" {
    var s = try surface(64, 32);
    defer s.deinit();
    // Calls the fallback DIRECTLY so these exact expectations hold whether or
    // not this host has a font — that is what keeps the pixel suite portable.
    // "OK" is 2 bytes => 2 boxes. font_size 18 => adv 10.8, box 7.56 wide.
    s.drawTextRunFallback(10, 10, "OK", 18, .{ 255, 255, 255, 255 });
    // First box spans x in [10, 17.56) and y in [10, 28) (height min(18,24)).
    try expectPx(s, 12, 15, .{ 255, 255, 255, 255 });
    try expectPx(s, 10, 12, .{ 255, 255, 255, 255 });
    // The gap between boxes (advance 10.8, width 7.56 => gap ~3.2px) is empty.
    try expectPx(s, 18, 15, .{ 0, 0, 0, 255 });
    // Second box starts at x = 10 + 10.8 = 20.8.
    try expectPx(s, 22, 15, .{ 255, 255, 255, 255 });
}

test "pixel: the fallback caps box height at 24 even for large font sizes" {
    var s = try surface(64, 64);
    defer s.deinit();
    // font_size 40 => box height min(40,24) = 24, so the box occupies y in
    // [10, 34) and nothing below it is painted.
    s.drawTextRunFallback(4, 10, "I", 40, .{ 255, 255, 255, 255 });
    try expectPx(s, 6, 20, .{ 255, 255, 255, 255 });
    try expectPx(s, 6, 40, .{ 0, 0, 0, 255 });
}

test "pixel: the real glyph path paints ink above the baseline and none below" {
    if (!soft.hasGlyphFont()) return error.SkipZigTest;
    var s = try surface(96, 64);
    defer s.deinit();
    s.drawTextRun(4, 4, 40, "8", 32, .{ 255, 255, 255, 255 });

    var inked: usize = 0;
    var below_baseline: usize = 0;
    for (0..64) |y| {
        for (0..96) |x| {
            const p = s.px(@intCast(x), @intCast(y));
            if (p[0] == 255 and p[1] == 255 and p[2] == 255) {
                inked += 1;
                // The run is vertically centred in the 40px box it was
                // given, so ink must not spill past the box's lower edge
                // (4 + 40 = 44).
                if (y >= 44) below_baseline += 1;
            }
        }
    }
    // A glyph-free bar is a solid block; a real glyph has holes and a much
    // lower ink ratio, so require a plausible amount rather than "any".
    try std.testing.expect(inked > 0);
    try std.testing.expect(inked < 96 * 24);
    // And it must stay inside the vertical band the layout reserved.
    try std.testing.expect(below_baseline == 0);
}

test "pixel: glyph text respects the text colour, not a hard-coded white" {
    if (!soft.hasGlyphFont()) return error.SkipZigTest;
    var s = try surface(96, 64);
    defer s.deinit();
    s.drawTextRun(4, 4, 40, "8", 32, .{ 255, 0, 0, 255 });
    var red: usize = 0;
    var wrong: usize = 0;
    for (0..64) |y| {
        for (0..96) |x| {
            const p = s.px(@intCast(x), @intCast(y));
            if (p[0] == 255 and p[1] == 0 and p[2] == 0) red += 1;
            if (p[0] == 255 and p[1] == 255 and p[2] == 255) wrong += 1;
        }
    }
    try std.testing.expect(red > 0);
    try std.testing.expectEqual(@as(usize, 0), wrong);
}

test "pixel: a longer run paints more ink than a single glyph" {
    if (!soft.hasGlyphFont()) return error.SkipZigTest;
    var one = try surface(96, 64);
    defer one.deinit();
    one.drawTextRun(4, 4, 40, "8", 32, .{ 255, 255, 255, 255 });
    var two = try surface(96, 64);
    defer two.deinit();
    two.drawTextRun(4, 4, 40, "88", 32, .{ 255, 255, 255, 255 });

    const ink = struct {
        fn count(s2: *soft.Surface) usize {
            var n: usize = 0;
            for (0..64) |y| {
                for (0..96) |x| {
                    const p = s2.px(@intCast(x), @intCast(y));
                    if (p[0] == 255 and p[1] == 255 and p[2] == 255) n += 1;
                }
            }
            return n;
        }
    }.count;
    // Proves the pen actually advances per codepoint: if every glyph drew at
    // the same x, both counts would be equal and labels would overlap.
    try std.testing.expect(ink(&two) > ink(&one));
}

/// The ink's vertical span: the first and last row holding a pixel that is at
/// least 40% of the way from the black background to the white text. A
/// threshold rather than exact white because a single glyph's stroke at UI
/// sizes never fills a whole pixel, so its peak coverage is below 1.0 — the
/// span is still within a pixel of the true ink box.
fn inkRows(s: *const Surface) struct { first: i64, last: i64 } {
    const ink_level: u8 = 100;
    var first: i64 = std.math.maxInt(i64);
    var last: i64 = -1;
    var y: i64 = 0;
    while (y < @as(i64, @intCast(s.height))) : (y += 1) {
        var x: i64 = 0;
        while (x < @as(i64, @intCast(s.width))) : (x += 1) {
            const p = s.px(x, y);
            if (p[0] >= ink_level and p[1] >= ink_level and p[2] >= ink_level) {
                if (y < first) first = y;
                if (y > last) last = y;
            }
        }
    }
    return .{ .first = first, .last = last };
}

test "pixel: a glyph run is centred in the box the layout gave it" {
    // THE regression guard for the macOS "font is not in centre like Linux"
    // report. The renderer used to ignore the box height the layout handed it
    // and place the baseline from a guessed box plus a misread stb `yoff`,
    // which lifted every run by a full ascent: on the calculator's keycaps the
    // ink sat against the TOP edge (top gap 5px, bottom gap 36px) instead of in
    // the middle.
    //
    // This is asserted on the INK, not on the code path, and runs on both
    // platforms: the box is what the layout reserved, so the ink's centre must
    // land on the box's centre wherever the font's own metrics put it.
    if (!soft.hasGlyphFont()) return error.SkipZigTest;
    var s = try surface(64, 96);
    defer s.deinit();

    const box_y: f32 = 20;
    const box_h: f32 = 40;
    s.drawTextRun(8, box_y, box_h, "8", 18, .{ 255, 255, 255, 255 });

    const ink = inkRows(&s);
    try std.testing.expect(ink.last >= ink.first); // something was painted
    const mid = (@as(f32, @floatFromInt(ink.first)) + @as(f32, @floatFromInt(ink.last))) * 0.5;
    // Centred: the cap-height box of a digit sits slightly above the true
    // vertical centre of the line box, so allow 2px of optical slack.
    try std.testing.expectApproxEqAbs(box_y + box_h * 0.5, mid, 2.0);
    // And confined: no ink outside the box the layout reserved.
    try std.testing.expect(@as(f32, @floatFromInt(ink.first)) >= box_y - 1);
    try std.testing.expect(@as(f32, @floatFromInt(ink.last)) <= box_y + box_h);
}

test "pixel: a taller box moves the ink down, a shorter one up" {
    // The same run in two boxes of different heights must follow the box: this
    // is what makes `bbox_h` load-bearing rather than decorative.
    if (!soft.hasGlyphFont()) return error.SkipZigTest;
    var tall = try surface(64, 128);
    defer tall.deinit();
    var short = try surface(64, 128);
    defer short.deinit();

    tall.drawTextRun(8, 0, 80, "8", 18, .{ 255, 255, 255, 255 });
    short.drawTextRun(8, 0, 24, "8", 18, .{ 255, 255, 255, 255 });

    const a = inkRows(&tall);
    const b = inkRows(&short);
    try std.testing.expect(a.first > b.first);
    try std.testing.expect(a.last > b.last);
}

test "pixel: empty text draws nothing" {
    var s = try surface(16, 16);
    defer s.deinit();
    s.drawTextRun(4, 4, 22, "", 18, .{ 255, 255, 255, 255 });
    for (0..16) |y| {
        for (0..16) |x| {
            try expectPx(s, @intCast(x), @intCast(y), .{ 0, 0, 0, 255 });
        }
    }
}

test "pixel: a space paints nothing" {
    if (!soft.hasGlyphFont()) return error.SkipZigTest;
    var s = try surface(64, 48);
    defer s.deinit();
    // A blank glyph must not draw ink even though it DOES advance the pen —
    // conflating the two would put a black box where a space belongs.
    s.drawTextRun(4, 4, 40, " ", 32, .{ 255, 255, 255, 255 });
    for (0..48) |y| {
        for (0..64) |x| {
            try expectPx(s, @intCast(x), @intCast(y), .{ 0, 0, 0, 255 });
        }
    }
}

// ---- images ----

fn solidImage(w: u32, h: u32, rgba: [4]u8) !soft.Image {
    const px = try std.testing.allocator.alloc(u8, @intCast(w * h * 4));
    for (0..w) |x| {
        for (0..h) |y| {
            const i = (y * w + x) * 4;
            px[i + 0] = rgba[0];
            px[i + 1] = rgba[1];
            px[i + 2] = rgba[2];
            px[i + 3] = rgba[3];
        }
    }
    return .{ .width = w, .height = h, .pixels = px };
}

test "pixel: stretch blit samples a solid image across the whole box" {
    var s = try surface(32, 32);
    defer s.deinit();
    const img = try solidImage(2, 2, .{ 255, 0, 0, 255 });
    defer std.testing.allocator.free(img.pixels);
    try s.putImage(soft.hashImageKey("/a", 256), img);

    const ref = soft.ImageRef{ .path_ptr = "/a", .path_len = 2, .fit = .stretch, .max_dim = 256 };
    var cmds = [_]cl.RenderCommand{.{
        .bounding_box = .{ .x = 4, .y = 4, .width = 16, .height = 16 },
        .render_data = .{ .image = .{
            .background_color = .{ 0, 0, 0, 0 },
            .corner_radius = .{},
            .image_data = @constCast(&ref),
        } },
        .user_data = null,
        .id = 0,
        .z_index = 0,
        .command_type = .image,
    }};
    s.renderCommands(&cmds);
    // The whole 16x16 box is the solid image color.
    try expectPx(s, 4, 4, .{ 255, 0, 0, 255 });
    try expectPx(s, 19, 19, .{ 255, 0, 0, 255 });
    try expectPx(s, 12, 8, .{ 255, 0, 0, 255 });
    // Outside the box is untouched.
    try expectPx(s, 3, 4, .{ 0, 0, 0, 255 });
    try expectPx(s, 20, 4, .{ 0, 0, 0, 255 });
}

test "pixel: contain letterboxes a solid image with the placeholder behind it" {
    var s = try surface(32, 32);
    defer s.deinit();
    // A 2:1 image in a 16x16 box => contained as 16x8 centred vertically.
    const img = try solidImage(4, 2, .{ 0, 255, 0, 255 });
    defer std.testing.allocator.free(img.pixels);
    try s.putImage(soft.hashImageKey("/b", 256), img);

    const ref = soft.ImageRef{ .path_ptr = "/b", .path_len = 2, .fit = .contain, .max_dim = 256 };
    var cmds = [_]cl.RenderCommand{.{
        .bounding_box = .{ .x = 0, .y = 0, .width = 16, .height = 16 },
        .render_data = .{ .image = .{
            .background_color = .{ 0, 0, 0, 0 },
            .corner_radius = .{},
            .image_data = @constCast(&ref),
        } },
        .user_data = null,
        .id = 0,
        .z_index = 0,
        .command_type = .image,
    }};
    s.renderCommands(&cmds);
    // Contained image occupies the vertical middle.
    try expectPx(s, 8, 8, .{ 0, 255, 0, 255 });
    // The letterbox bands above/below show the placeholder (0x1a1a1a).
    try expectPx(s, 8, 1, .{ 26, 26, 26, 255 });
    try expectPx(s, 8, 14, .{ 26, 26, 26, 255 });
}

test "pixel: a missing image draws the placeholder box" {
    var s = try surface(16, 16);
    defer s.deinit();
    // No image registered for this path.
    const ref = soft.ImageRef{ .path_ptr = "/nope", .path_len = 5, .fit = .cover, .max_dim = 256 };
    var cmds = [_]cl.RenderCommand{.{
        .bounding_box = .{ .x = 2, .y = 2, .width = 8, .height = 8 },
        .render_data = .{ .image = .{
            .background_color = .{ 0, 0, 0, 0 },
            .corner_radius = .{},
            .image_data = @constCast(&ref),
        } },
        .user_data = null,
        .id = 0,
        .z_index = 0,
        .command_type = .image,
    }};
    s.renderCommands(&cmds);
    try expectPx(s, 5, 5, .{ 26, 26, 26, 255 });
    // The box's own top-left pixel is inside the placeholder fill.
    try expectPx(s, 2, 2, .{ 26, 26, 26, 255 });
    // One pixel outside the box is untouched.
    try expectPx(s, 1, 1, .{ 0, 0, 0, 255 });
}

test "pixel: a null image_data pointer draws nothing" {
    var s = try surface(16, 16);
    defer s.deinit();
    var cmds = [_]cl.RenderCommand{.{
        .bounding_box = .{ .x = 2, .y = 2, .width = 8, .height = 8 },
        .render_data = .{ .image = .{
            .background_color = .{ 0, 0, 0, 0 },
            .corner_radius = .{},
            .image_data = null,
        } },
        .user_data = null,
        .id = 0,
        .z_index = 0,
        .command_type = .image,
    }};
    s.renderCommands(&cmds);
    for (0..16) |y| {
        for (0..16) |x| {
            try expectPx(s, @intCast(x), @intCast(y), .{ 0, 0, 0, 255 });
        }
    }
}

// ---- ignored command types ----

test "pixel: custom and none commands paint nothing" {
    var s = try surface(16, 16);
    defer s.deinit();
    var cmds = [_]cl.RenderCommand{
        .{
            .bounding_box = .{ .x = 0, .y = 0, .width = 16, .height = 16 },
            .render_data = .{ .custom = .{
                .background_color = .{ 255, 0, 0, 255 },
                .corner_radius = .{},
                .custom_data = null,
            } },
            .user_data = null,
            .id = 0,
            .z_index = 0,
            .command_type = .custom,
        },
        .{
            .bounding_box = .{ .x = 0, .y = 0, .width = 16, .height = 16 },
            .render_data = .{ .rectangle = .{
                .background_color = .{ 255, 0, 0, 255 },
                .corner_radius = .{},
            } },
            .user_data = null,
            .id = 0,
            .z_index = 0,
            .command_type = .none,
        },
    };
    s.renderCommands(&cmds);
    for (0..16) |y| {
        for (0..16) |x| {
            try expectPx(s, @intCast(x), @intCast(y), .{ 0, 0, 0, 255 });
        }
    }
}

// ---- whole-frame behaviour ----

test "pixel: clear resets the whole framebuffer to the opaque clear color" {
    var s = try Surface.init(std.testing.allocator, 8, 4);
    defer s.deinit();
    s.setClearColor(.{ 17, 17, 17, 255 });
    s.clear();
    for (0..4) |y| {
        for (0..8) |x| {
            try expectPx(s, @intCast(x), @intCast(y), .{ 17, 17, 17, 255 });
        }
    }
}

test "pixel: a leaked scissor does not affect the next renderCommands call" {
    var s = try surface(32, 32);
    defer s.deinit();
    // First frame leaves the scissor open.
    var first = [_]cl.RenderCommand{scissorCmd(0, 0, 4, 4, true)};
    s.renderCommands(&first);
    // Second frame paints the whole surface with no scissor commands at all.
    var second = [_]cl.RenderCommand{rectCmd(0, 0, 32, 32, .{ 0, 255, 0, 255 })};
    s.renderCommands(&second);
    try expectPx(s, 20, 20, .{ 0, 255, 0, 255 });
}

test "pixel: resize grows the framebuffer and clears it" {
    var s = try Surface.init(std.testing.allocator, 4, 4);
    defer s.deinit();
    try s.resize(8, 8);
    s.setClearColor(.{ 1, 2, 3, 255 });
    s.clear();
    try expectPx(s, 7, 7, .{ 1, 2, 3, 255 });
    try expectPx(s, 0, 0, .{ 1, 2, 3, 255 });
}
