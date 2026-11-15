//! Whole-scene golden images: one fixed command list must rasterize to the same bytes on every platform, so the CPU surface is the reference a GPU backend must match.
const std = @import("std");
const cl = @import("zclay");
const soft = @import("render_software.zig");
const expected = @import("golden_expected.zig");
const scenes = @import("golden_scenes.zig");

const w: u32 = 200;
const h: u32 = 120;

// Render a command list at 1x into a fresh surface and return the SHA-256 of its pixels.
fn sceneHash(commands: []const cl.RenderCommand) [32]u8 {
    soft.setRenderScale(1.0);
    var s = soft.Surface.init(std.testing.allocator, w, h) catch @panic("surface");
    defer s.deinit();
    s.setClearColor(scenes.clear);
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

test "golden: flat rectangles" {
    try expectGolden(sceneHash(&scenes.rects), expected.rects, "rects");
}

test "golden: rounded corners and borders" {
    try expectGolden(sceneHash(&scenes.rounded), expected.rounded, "rounded");
}

test "golden: text in the bundled face" {
    try expectGolden(sceneHash(&scenes.text), expected.text, "text");
}

test "golden: a composite screen" {
    try expectGolden(sceneHash(&scenes.composite), expected.composite, "composite");
}
