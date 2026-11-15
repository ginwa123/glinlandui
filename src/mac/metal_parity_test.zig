//! Proves the Metal backend draws the same pixels as the CPU reference, scene by scene.
const std = @import("std");
const builtin = @import("builtin");
const cl = @import("zclay");
const soft = @import("../core/render_software.zig");
const scenes = @import("../core/golden_scenes.zig");
const glyphs = @import("../core/glyphs.zig");
const text_face = @import("../core/text_face.zig");
const renderer = @import("renderer.zig");

const w: u32 = 200;
const h: u32 = 120;

fn diff(a: u8, b: u8) i32 {
    const x = @as(i32, a) - @as(i32, b);
    return if (x < 0) -x else x;
}

fn cpuPixels(commands: []const cl.RenderCommand, alloc: std.mem.Allocator) ![]u8 {
    soft.setRenderScale(1.0);
    var s = try soft.Surface.init(alloc, w, h);
    defer s.deinit();
    // Also publishes the clear colour a GPU backend reads.
    s.setClearColor(scenes.clear);
    s.clear();
    s.renderCommands(commands);
    return alloc.dupe(u8, s.pixels);
}

test "Metal matches the CPU reference on every golden scene" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    // In the app `Host.init` installs the face; a standalone test root has no Host, and without it the CPU draws glyphs the atlas never packed.
    text_face.setAllocator(std.heap.page_allocator);
    glyphs.initCache(std.heap.page_allocator);
    if (text_face.font() == null) return error.NoFontFace;
    var r = try renderer.Renderer.init(std.testing.allocator);
    defer r.deinit();
    // A CI runner with no Metal device is not a failure; the gate is meaningless there.
    if (!r.attachOffscreen()) return error.SkipZigTest;

    for (scenes.all) |scene| {
        const cpu = try cpuPixels(scene.cmds, std.testing.allocator);
        defer std.testing.allocator.free(cpu);
        const gpu = r.renderOffscreen(scene.cmds, w, h) orelse return error.SkipZigTest;
        defer std.testing.allocator.free(gpu);

        // The layer is BGRA and the CPU surface is RGBA, so red and blue are compared swapped.
        var worst: i32 = 0;
        var i: usize = 0;
        while (i < cpu.len) : (i += 4) {
            worst = @max(worst, @max(diff(cpu[i], gpu[i + 2]), @max(diff(cpu[i + 1], gpu[i + 1]), diff(cpu[i + 2], gpu[i]))));
        }
        // One unit of slack: the CPU blends in f32 per channel, the GPU in the shader's precision.
        if (worst > 1) {
            std.debug.print("metal vs cpu '{s}': worst channel diff {d} (allowed 1)\n", .{ scene.name, worst });
            return error.MetalMismatch;
        }
        std.debug.print("metal vs cpu '{s}': worst channel diff {d}\n", .{ scene.name, worst });
    }
}

// Write a 32-bit uncompressed TGA so the test needs no image asset in the repo; stb_image reads it.
fn writeTestTga(path: [:0]const u8, tw: u16, th: u16, rgba: []const u8) !void {
    var hdr = [_]u8{0} ** 18;
    hdr[2] = 2; // uncompressed true-colour
    std.mem.writeInt(u16, hdr[12..14], tw, .little);
    std.mem.writeInt(u16, hdr[14..16], th, .little);
    hdr[16] = 32; // RGBA
    hdr[17] = 0x28; // 8 alpha bits, top-left origin
    const io = std.Io.Threaded.global_single_threaded.io();
    const f = try std.Io.Dir.createFileAbsolute(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, &hdr);
    // TGA stores BGRA.
    var i: usize = 0;
    while (i < rgba.len) : (i += 4) {
        try f.writeStreamingAll(io, &[_]u8{ rgba[i + 2], rgba[i + 1], rgba[i], rgba[i + 3] });
    }
}

test "Metal matches the CPU on an image quad" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    text_face.setAllocator(std.heap.page_allocator);
    var r = try renderer.Renderer.init(std.testing.allocator);
    defer r.deinit();
    if (!r.attachOffscreen()) return error.SkipZigTest;

    const iw: u16 = 16;
    const ih: u16 = 16;
    const src = try std.testing.allocator.alloc(u8, @as(usize, iw) * ih * 4);
    defer std.testing.allocator.free(src);
    var y: u16 = 0;
    while (y < ih) : (y += 1) {
        var x: u16 = 0;
        while (x < iw) : (x += 1) {
            const i = (@as(usize, y) * iw + x) * 4;
            src[i] = @intCast(@as(u32, x) * 16);
            src[i + 1] = @intCast(@as(u32, y) * 16);
            src[i + 2] = 200;
            src[i + 3] = 255;
        }
    }
    const path = "/tmp/glin_parity_image.tga";
    try writeTestTga(path, iw, ih, src);

    const max_dim: u16 = 256;
    var ref = @import("../core/render_common.zig").ImageRef{
        .path_ptr = path.ptr,
        .path_len = path.len,
        .fit = .stretch,
        .max_dim = max_dim,
    };
    const commands = [_]cl.RenderCommand{.{
        .bounding_box = .{ .x = 20, .y = 10, .width = 160, .height = 100 },
        .render_data = .{ .image = .{ .image_data = @ptrCast(&ref), .background_color = .{ 0, 0, 0, 0 }, .corner_radius = .{} } },
        .user_data = null,
        .id = 0,
        .z_index = 0,
        .command_type = .image,
    }};

    // The CPU surface never decodes; it draws from its cache, so register the same bytes under the same key.
    soft.setRenderScale(1.0);
    var s = try soft.Surface.init(std.testing.allocator, w, h);
    defer s.deinit();
    s.setClearColor(scenes.clear);
    s.clear();
    try s.putImage(@import("../core/render_common.zig").hashImageKey(path, max_dim), .{ .width = iw, .height = ih, .pixels = src });
    s.renderCommands(&commands);
    const cpu = try std.testing.allocator.dupe(u8, s.pixels);
    defer std.testing.allocator.free(cpu);

    const gpu = r.renderOffscreen(&commands, w, h) orelse return error.SkipZigTest;
    defer std.testing.allocator.free(gpu);

    var worst: i32 = 0;
    var i: usize = 0;
    while (i < cpu.len) : (i += 4) {
        worst = @max(worst, @max(diff(cpu[i], gpu[i + 2]), @max(diff(cpu[i + 1], gpu[i + 1]), diff(cpu[i + 2], gpu[i]))));
    }
    // Bilinear sampling is float math on both sides; a couple of units is rounding, not a different picture.
    if (worst > 2) {
        std.debug.print("metal vs cpu 'image': worst channel diff {d} (allowed 2)\n", .{worst});
        return error.MetalMismatch;
    }
    std.debug.print("metal vs cpu 'image': worst channel diff {d}\n", .{worst});
}
