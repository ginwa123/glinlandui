//! Proves the D3D11 renderer draws the CPU reference's pixels, scene by scene. The Windows mirror of `src/mac/metal_parity_test.zig`, with one deliberate difference: the target is R8G8B8A8_UNORM, the same byte order the CPU Surface holds, so the comparison is channel for channel and NOT with red and blue swapped. Metal's layer is BGRA, which is why that test swaps.
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
    // Also publishes the clear colour the GPU path reads.
    s.setClearColor(scenes.clear);
    s.clear();
    s.renderCommands(commands);
    return alloc.dupe(u8, s.pixels);
}

test "D3D11 matches the CPU reference on every golden scene" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    // In the app `Host.init` installs the face; a standalone test root has no Host, and without it the CPU draws glyphs the atlas never packed.
    text_face.setAllocator(std.heap.page_allocator);
    glyphs.initCache(std.heap.page_allocator);
    if (text_face.font() == null) return error.NoFontFace;

    var r = try renderer.Renderer.init(std.testing.allocator);
    defer r.deinit();
    // A host with no D3D11 device at all is not a failure: WARP ships with Windows, so this is rare, and when it happens the gate is meaningless.
    if (!r.attachOffscreen()) return error.SkipZigTest;

    for (scenes.all) |scene| {
        const cpu = try cpuPixels(scene.cmds, std.testing.allocator);
        defer std.testing.allocator.free(cpu);
        const gpu = r.renderOffscreen(scene.cmds, w, h) orelse return error.SkipZigTest;
        defer std.testing.allocator.free(gpu);

        var worst: i32 = 0;
        var i: usize = 0;
        while (i < cpu.len) : (i += 4) {
            worst = @max(worst, @max(diff(cpu[i], gpu[i]), @max(diff(cpu[i + 1], gpu[i + 1]), diff(cpu[i + 2], gpu[i + 2]))));
        }
        // One unit of slack: the CPU blends in f32 per channel and rounds once, the GPU blends in the target's own precision.
        if (worst > 1) {
            std.debug.print("d3d11 vs cpu '{s}': worst channel diff {d} (allowed 1)\n", .{ scene.name, worst });
            std.debug.print("  clear={any} cpu[0..8]={any} cpu[mid..mid+4]={any}\n", .{ soft.currentClearColor(), cpu[0..8], cpu[(cpu.len / 2) .. (cpu.len / 2) + 4] });
            std.debug.print("  gpu[0..8]={any} gpu[mid..mid+4]={any}\n", .{ gpu[0..8], gpu[(gpu.len / 2) .. (gpu.len / 2) + 4] });
            return error.D3d11Mismatch;
        }
        std.debug.print("d3d11 vs cpu '{s}': worst channel diff {d}\n", .{ scene.name, worst });
    }
}
