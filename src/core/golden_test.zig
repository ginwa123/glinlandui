//! Whole-scene golden images: one fixed command list must rasterize to the same bytes on every platform, so the CPU surface is the reference a GPU backend must match.
const std = @import("std");
const cl = @import("zclay");
const soft = @import("render_software.zig");
const expected = @import("golden_expected.zig");

const w: u32 = 200;
const h: u32 = 120;

fn rect(x: f32, y: f32, rw: f32, rh: f32, color: [4]f32) cl.RenderCommand {
    return .{
        .bounding_box = .{ .x = x, .y = y, .width = rw, .height = rh },
        .render_data = .{ .rectangle = .{ .background_color = color, .corner_radius = .{} } },
        .user_data = null,
        .id = 0,
        .z_index = 0,
        .command_type = .rectangle,
    };
}

fn roundRect(x: f32, y: f32, rw: f32, rh: f32, radius: f32, color: [4]f32) cl.RenderCommand {
    var c = rect(x, y, rw, rh, color);
    c.render_data.rectangle.corner_radius = .{
        .top_left = radius,
        .top_right = radius,
        .bottom_left = radius,
        .bottom_right = radius,
    };
    return c;
}

fn border(x: f32, y: f32, rw: f32, rh: f32, width: f32, color: [4]f32) cl.RenderCommand {
    return .{
        .bounding_box = .{ .x = x, .y = y, .width = rw, .height = rh },
        .render_data = .{ .border = .{
            .color = color,
            .corner_radius = .{},
            .width = .outside(@intFromFloat(width)),
        } },
        .user_data = null,
        .id = 0,
        .z_index = 0,
        .command_type = .border,
    };
}

fn text(x: f32, y: f32, rw: f32, rh: f32, s: [:0]const u8, size: u16, color: [4]f32) cl.RenderCommand {
    return .{
        .bounding_box = .{ .x = x, .y = y, .width = rw, .height = rh },
        .render_data = .{ .text = .{
            .string_contents = .{ .chars = s.ptr, .base_chars = s.ptr, .length = @intCast(s.len) },
            .text_color = color,
            .font_size = size,
            .font_id = 0,
            .letter_spacing = 0,
            .line_height = 0,
        } },
        .user_data = null,
        .id = 0,
        .z_index = 0,
        .command_type = .text,
    };
}

// Render a command list at 1x into a fresh surface and return the SHA-256 of its pixels.
fn sceneHash(commands: []const cl.RenderCommand) [32]u8 {
    soft.setRenderScale(1.0);
    var s = soft.Surface.init(std.testing.allocator, w, h) catch @panic("surface");
    defer s.deinit();
    s.setClearColor(.{ 18, 18, 22, 255 });
    s.clear();
    s.renderCommands(commands);
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(s.pixels, &out, .{});
    return out;
}

// Compare a scene against its committed hash, and print the actual one so a deliberate change is easy to re-record.
fn expectGolden(actual: [32]u8, want: []const u8, name: []const u8) !void {
    var hex: [64]u8 = undefined;
    const got = std.fmt.bufPrint(&hex, "{x}", .{&actual}) catch @panic("hex buffer is 64 bytes for a 32-byte digest");
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("\ngolden '{s}' changed\n  expected {s}\n  actual   {s}\n  re-record it in src/core/golden_expected.zig if the change is intended\n", .{ name, want, got });
        return error.GoldenMismatch;
    }
}

const scene_rects = [_]cl.RenderCommand{
    rect(0, 0, 200, 40, .{ 30, 30, 36, 255 }),
    rect(10, 50, 80, 30, .{ 200, 80, 60, 255 }),
    rect(60, 60, 80, 30, .{ 60, 200, 120, 128 }),
    rect(100, 50, 90, 40, .{ 80, 120, 240, 255 }),
};

const scene_rounded = [_]cl.RenderCommand{
    roundRect(10, 10, 90, 50, 8, .{ 210, 210, 220, 255 }),
    roundRect(30, 40, 90, 50, 12, .{ 40, 60, 90, 200 }),
    border(10, 80, 100, 30, 2, .{ 240, 200, 80, 255 }),
};

const scene_text = [_]cl.RenderCommand{
    rect(0, 0, 200, 120, .{ 24, 24, 28, 255 }),
    text(8, 8, 180, 18, "Hello, glinlandui", 14, .{ 230, 230, 235, 255 }),
    text(8, 34, 180, 24, "0123456789", 20, .{ 140, 200, 255, 255 }),
    text(8, 66, 180, 16, "{}[]()<>*&^%$#@", 12, .{ 200, 200, 200, 255 }),
};

const scene_composite = [_]cl.RenderCommand{
    rect(0, 0, 200, 120, .{ 20, 20, 24, 255 }),
    roundRect(6, 6, 188, 30, 6, .{ 38, 38, 46, 255 }),
    text(12, 10, 170, 16, "toolbar", 13, .{ 232, 232, 236, 255 }),
    roundRect(6, 44, 90, 40, 4, .{ 52, 90, 140, 255 }),
    border(6, 44, 90, 40, 1, .{ 120, 160, 220, 255 }),
    text(12, 56, 78, 16, "ok", 14, .{ 255, 255, 255, 255 }),
    rect(110, 44, 84, 40, .{ 60, 60, 70, 128 }),
};

test "golden: flat rectangles" {
    try expectGolden(sceneHash(&scene_rects), expected.rects, "rects");
}

test "golden: rounded corners and borders" {
    try expectGolden(sceneHash(&scene_rounded), expected.rounded, "rounded");
}

test "golden: text in the bundled face" {
    try expectGolden(sceneHash(&scene_text), expected.text, "text");
}

test "golden: a composite screen" {
    try expectGolden(sceneHash(&scene_composite), expected.composite, "composite");
}
