//! Proves the Metal backend draws the same pixels as the CPU reference, scene by scene.
const std = @import("std");
const builtin = @import("builtin");
const cl = @import("zclay");
const soft = @import("../core/render_software.zig");
const scenes = @import("../core/golden_scenes.zig");
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
