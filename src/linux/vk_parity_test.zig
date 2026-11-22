//! Proves the Vulkan backend draws the same pixels as the CPU reference, scene by scene.
const std = @import("std");
const builtin = @import("builtin");
const cl = @import("zclay");
const soft = @import("../core/render_software.zig");
const scenes = @import("../core/golden_scenes.zig");
const common = @import("../core/render_common.zig");
const renderer = @import("renderer.zig");

const w: u32 = 200;
const h: u32 = 120;

fn diff(a: u8, b: u8) i32 {
    const x = @as(i32, a) - @as(i32, b);
    return if (x < 0) -x else x;
}

// Text is deliberately out of scope: Linux rasterises pango runs while the CPU reference draws stb glyphs, so the two cannot agree.
fn hasText(commands: []const cl.RenderCommand) bool {
    for (commands) |*cmd| {
        if (cmd.command_type == .text) return true;
    }
    return false;
}

fn cpuPixels(commands: []const cl.RenderCommand, alloc: std.mem.Allocator) ![]u8 {
    soft.setRenderScale(1.0);
    var s = try soft.Surface.init(alloc, w, h);
    defer s.deinit();
    // The software surface takes 0-255 (its clear clamps to a byte) while the Vulkan clear value is 0-1.
    const cc = renderer.clearColor();
    s.setClearColor(.{ cc[0] * 255.0, cc[1] * 255.0, cc[2] * 255.0, 255 });
    s.clear();
    s.renderCommands(commands);
    return alloc.dupe(u8, s.pixels);
}

const Worst = struct { d: i32 = 0, x: i32 = 0, y: i32 = 0, cpu: [3]u8 = .{ 0, 0, 0 }, gpu: [3]u8 = .{ 0, 0, 0 } };

fn worstChannel(cpu: []const u8, gpu: []const u8, width: i32) Worst {
    var worst = Worst{};
    var i: usize = 0;
    while (i + 3 < @min(cpu.len, gpu.len)) : (i += 4) {
        const d = @max(diff(cpu[i], gpu[i]), @max(diff(cpu[i + 1], gpu[i + 1]), diff(cpu[i + 2], gpu[i + 2])));
        if (d > worst.d) {
            const p: i32 = @intCast(i / 4);
            worst = .{
                .d = d,
                .x = @mod(p, width),
                .y = @divTrunc(p, width),
                .cpu = .{ cpu[i], cpu[i + 1], cpu[i + 2] },
                .gpu = .{ gpu[i], gpu[i + 1], gpu[i + 2] },
            };
        }
    }
    return worst;
}

test "Vulkan matches the CPU reference on every text-free golden scene" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var r = try renderer.Renderer.init(std.testing.allocator);
    defer r.deinit();
    // A machine with no Vulkan device (or no lavapipe) is not a failure: the gate is meaningless there.
    if (!r.attachOffscreen()) return error.SkipZigTest;

    for (scenes.all) |scene| {
        if (hasText(scene.cmds)) continue;
        const cpu = try cpuPixels(scene.cmds, std.testing.allocator);
        defer std.testing.allocator.free(cpu);
        // A device exists, so a failed offscreen render is a real failure, not a reason to skip.
        const gpu = r.renderOffscreen(scene.cmds, w, h) orelse {
            std.debug.print("vulkan offscreen failed on '{s}': {s}\n", .{ scene.name, r.lastError() });
            return error.VulkanOffscreenFailed;
        };
        defer std.testing.allocator.free(gpu);

        const worst = worstChannel(cpu, gpu, @intCast(w));
        // One unit of slack: the CPU blends in f32 per channel, the GPU in the shader's precision.
        if (worst.d > 1) {
            std.debug.print("vulkan vs cpu '{s}': worst channel diff {d} at ({d},{d}) cpu={any} gpu={any}\n", .{ scene.name, worst.d, worst.x, worst.y, worst.cpu, worst.gpu });
            return error.VulkanMismatch;
        }
        std.debug.print("vulkan vs cpu '{s}': worst channel diff {d}\n", .{ scene.name, worst.d });
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
    var i: usize = 0;
    while (i < rgba.len) : (i += 4) {
        try f.writeStreamingAll(io, &[_]u8{ rgba[i + 2], rgba[i + 1], rgba[i], rgba[i + 3] });
    }
}

test "Vulkan matches the CPU on an image quad" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
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
    const path = "/tmp/glin_vk_parity_image.tga";
    try writeTestTga(path, iw, ih, src);

    const max_dim: u16 = 256;
    var ref = common.ImageRef{ .path_ptr = path.ptr, .path_len = path.len, .fit = .stretch, .max_dim = max_dim };
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
    const cc = renderer.clearColor();
    s.setClearColor(.{ cc[0] * 255.0, cc[1] * 255.0, cc[2] * 255.0, 255 });
    s.clear();
    try s.putImage(common.hashImageKey(path, max_dim), .{ .width = iw, .height = ih, .pixels = src });
    s.renderCommands(&commands);
    const cpu = try std.testing.allocator.dupe(u8, s.pixels);
    defer std.testing.allocator.free(cpu);

    const gpu = r.renderOffscreen(&commands, w, h) orelse {
        std.debug.print("vulkan offscreen failed on the image quad: {s}\n", .{r.lastError()});
        return error.VulkanOffscreenFailed;
    };
    defer std.testing.allocator.free(gpu);

    const worst = worstChannel(cpu, gpu, @intCast(w));
    // Bilinear sampling is float math on both sides; a couple of units is rounding, not a different picture.
    if (worst.d > 2) {
        std.debug.print("vulkan vs cpu 'image': worst channel diff {d} at ({d},{d}) cpu={any} gpu={any}\n", .{ worst.d, worst.x, worst.y, worst.cpu, worst.gpu });
        return error.VulkanMismatch;
    }
    std.debug.print("vulkan vs cpu 'image': worst channel diff {d}\n", .{worst.d});
}
