//! Browser renderer — the dispatcher: WebGPU if the page has it, else WebGL2, else the CPU rasterizer.
const std = @import("std");
const cl = @import("zclay");
const soft = @import("../core/render_software.zig");
const gpu = @import("gpu.zig");

/// The CPU surface type, still exported because `window.surfaceInfo` and the contract test name it on every backend.
pub const Surface = soft.Surface;

/// What the page created: `none` is the CPU rasterizer, not an error.
pub const Kind = gpu.Kind;

/// Which GPU API the page reported, as a number (0 none, 1 WebGPU, 2 WebGL2).
pub fn backendKind() u32 {
    return gpu.backendKind();
}

/// The page's answer, from `glin_web_gpu_ready`. 0 hands the frame back to the CPU rasterizer.
pub fn setBackendKind(k: u32) void {
    gpu.setBackendKind(k);
}

/// True when the GPU is driving the screen, so the window offers the page no CPU surface to blit.
pub fn gpuActive() bool {
    return gpu.active();
}

/// The renderer `core/frame.zig` drives: one `drawCommands` entry, and the GPU decision made per frame.
pub const Renderer = struct {
    alloc: std.mem.Allocator,
    /// Built on the first CPU frame and kept, so switching back from a lost GPU context costs no allocation.
    cpu: ?soft.Renderer = null,

    pub fn init(alloc: std.mem.Allocator) !Renderer {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Renderer) void {
        if (self.cpu) |*r| r.deinit();
        self.cpu = null;
        gpu.deinit();
    }

    /// Build one frame. With a GPU the work is geometry only — the page uploads and draws it; without one it is the same software rasterizer as before.
    pub fn drawCommands(self: *Renderer, commands: []const cl.RenderCommand, win_w: i32, win_h: i32) void {
        if (gpu.active()) {
            gpu.build(commands, win_w, win_h);
            return;
        }
        if (self.cpu == null) self.cpu = soft.Renderer.init(self.alloc) catch return;
        self.cpu.?.drawCommands(commands, win_w, win_h);
    }
};
