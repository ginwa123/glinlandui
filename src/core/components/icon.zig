// Agnostic reusable Clay icon widget (toolkit-style, library only).
// Nerd Font glyphs rendered as text: Pango + fontconfig fallback resolve
// the private-use codepoints (FiraCode Nerd Font preferred — see
// wayland.text.resolveFont), so no renderer image support is needed.
// The GLES3 renderer draws icons like any label (textured quad via the
// Pango cache); the stb fallback (ASCII-only atlas) degrades to rects.
// Imports: std + zclay + core/color + core/render_common ONLY.
// Never: app/theme/layout/views/content/sidebar.
const std = @import("std");
const cl = @import("zclay");
const Color = @import("../color.zig").Color;

// ---- Glyph table (Font Awesome codepoints, present in Nerd Fonts) ----
// Drill-in / expand affordances (replace the ASCII ">" chevron).
pub const chevron_right: []const u8 = "\u{F054}";
pub const chevron_down: []const u8 = "\u{F078}";
// Sidebar navigation (one per Page, same order as sidebar_items).
pub const gear: []const u8 = "\u{F013}";
pub const wifi: []const u8 = "\u{F1EB}";
pub const bluetooth: []const u8 = "\u{F293}";
pub const power: []const u8 = "\u{F011}";
pub const bars: []const u8 = "\u{F0C9}";
pub const grid: []const u8 = "\u{F00A}";
pub const image: []const u8 = "\u{F03E}";
// Search field prompt (replaces the ASCII ">" prompt).
pub const search: []const u8 = "\u{F002}";
// Status affordances (wifi settings rows: connected check, secured lock).
pub const check: []const u8 = "\u{F00C}";
pub const lock: []const u8 = "\u{F023}";

/// Icon props. All styling via props with neutral defaults.
/// `glyph` is a UTF-8 slice (one of the table entries above); `icon()`
/// is a declare-only leaf like label() — no hover, no selection.
pub const IconProps = struct {
    glyph: []const u8,
    font_size: u16 = 14,
    color: Color = Color.rgb(0xe8, 0xe8, 0xe8),
    disabled: bool = false,
    disabled_color: Color = Color.rgb(0x77, 0x77, 0x77),
};

/// Declare a single icon element. Declare-only leaf: no hover, no
/// selection — those stay caller-side.
pub fn icon(props: IconProps) void {
    cl.text(props.glyph, .{
        .font_size = props.font_size,
        .color = (if (props.disabled) props.disabled_color else props.color).toClay(),
    });
}

// Stub text estimator for headless tests (no font backend needed).
fn stubMeasure(s: []const u8, cfg: *cl.TextElementConfig, _: void) cl.Dimensions {
    return .{
        .w = @as(f32, @floatFromInt(s.len)) * @as(f32, @floatFromInt(cfg.font_size)) * 0.6,
        .h = @as(f32, @floatFromInt(cfg.font_size)),
    };
}

fn declareIcon() void {
    icon(.{ .glyph = chevron_right });
}

/// Run one headless Clay frame around `declare_fn`, counting rectangle
/// and text render commands.
fn countCommands(declare_fn: *const fn () void, rects: *usize, texts: *usize) !void {
    const mem_size = cl.minMemorySize();
    // NOTE: intentionally leaked (page_allocator, never freed). Clay keeps
    // a global currentContext pointer inside this arena, so freeing it
    // would dangle the *next* test's minMemorySize/initialize (segfault).
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declare_fn();
    const cmds = cl.endLayout();
    var r: usize = 0;
    var t: usize = 0;
    for (cmds) |c| switch (c.command_type) {
        .rectangle => r += 1,
        .text => t += 1,
        else => {},
    };
    rects.* = r;
    texts.* = t;
}

test "icon emits exactly one text command, no rectangles" {
    var rects: usize = 0;
    var texts: usize = 0;
    try countCommands(declareIcon, &rects, &texts);
    try std.testing.expectEqual(@as(usize, 0), rects);
    try std.testing.expectEqual(@as(usize, 1), texts);
}

test "IconProps carries neutral defaults" {
    const p = IconProps{ .glyph = chevron_right };
    try std.testing.expectEqual(@as(u16, 14), p.font_size);
    try std.testing.expectEqual(Color.rgb(0xe8, 0xe8, 0xe8), p.color);
    try std.testing.expect(!p.disabled);
    try std.testing.expectEqual(Color.rgb(0x77, 0x77, 0x77), p.disabled_color);
}

fn declareDisabledIcon() void {
    icon(.{ .glyph = chevron_right, .disabled = true });
}

test "disabled icon emits one text with the disabled color" {
    const mem_size = cl.minMemorySize();
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declareDisabledIcon();
    const cmds = cl.endLayout();
    var texts: usize = 0;
    for (cmds) |c| {
        if (c.command_type == .text) {
            texts += 1;
            try std.testing.expectEqual(Color.rgb(0x77, 0x77, 0x77).toClay(), c.render_data.text.text_color);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), texts);
}

test "glyph table entries are non-empty UTF-8" {
    const glyphs = [_][]const u8{ chevron_right, chevron_down, gear, wifi, bluetooth, power, bars, grid, image, search };
    for (glyphs) |g| {
        try std.testing.expect(g.len > 0);
        // All table entries are 3-byte UTF-8 (U+F000-U+FFFF private use).
        try std.testing.expectEqual(@as(usize, 3), g.len);
    }
}

test "status glyphs are non-empty UTF-8 slices" {
    try std.testing.expect(check.len > 0);
    try std.testing.expect(lock.len > 0);
    try std.testing.expect(check.ptr != lock.ptr);
}
