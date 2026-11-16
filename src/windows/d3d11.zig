//! The one Windows file that `@cImport`s the D3D11 shim header. It exists so `src/windows/renderer.zig` can stay pure Zig: that file is on `ci/check_layering.sh`'s pure list and `src/root.zig` compiles it on EVERY platform, so a `@cImport` there would make a macOS or Linux build parse the Windows SDK. On a host without the shim the surface below is a STUB with the same shapes, not a missing module: every `gpu.c.…` reference in the renderer then still type-checks, which is what keeps a Linux or macOS build from ever depending on "this branch is dead so it is not analysed". `usable` is the single switch, and the stub never draws anything.
const builtin = @import("builtin");

/// True only where the shim can exist: the D3D11 half of the toolkit.
pub const usable = builtin.os.tag == .windows;

/// The plain-C surface of `shim.h` (vertices, segments, the GPU entry points).
pub const c = if (usable) @cImport({
    @cInclude("shim.h");
}) else Stub;

/// The same decls as `shim.h`, doing nothing. Signatures must stay in step with the C prototypes: a call that compiles here must compile there.
const Stub = struct {
    pub const GlinWinGpu = opaque {};
    pub const GlinVertex = extern struct { pos: [2]f32, local: [2]f32, size: [2]f32, radius: [4]f32, color: [4]f32, mode: f32, border: f32, kind: f32 };
    pub const GlinSegment = extern struct { start: c_int, count: c_int, has_scissor: c_int, sx: c_int, sy: c_int, sw: c_int, sh: c_int, texture_id: c_int };

    pub fn glin_win_gpu_create(_: ?*anyopaque) ?*GlinWinGpu {
        return null;
    }
    pub fn glin_win_gpu_destroy(_: ?*GlinWinGpu) void {}
    pub fn glin_win_gpu_active(_: ?*GlinWinGpu) c_int {
        return 0;
    }
    pub fn glin_win_gpu_presented_frames(_: ?*GlinWinGpu) c_int {
        return 0;
    }
    pub fn glin_win_gpu_set_atlas(_: ?*GlinWinGpu, _: ?[*]const u8, _: c_int, _: c_int) void {}
    pub fn glin_win_gpu_set_image(_: ?*GlinWinGpu, _: c_int, _: ?[*]const u8, _: c_int, _: c_int) void {}
    pub fn glin_win_gpu_draw(_: ?*GlinWinGpu, _: [*c]const GlinVertex, _: c_int, _: [*c]const GlinSegment, _: c_int, _: f32, _: f32, _: f32, _: f32) c_int {
        return 0;
    }
    pub fn glin_win_gpu_offscreen(_: [*c]const GlinVertex, _: c_int, _: [*c]const GlinSegment, _: c_int, _: c_int, _: c_int, _: f32, _: f32, _: f32, _: f32, _: ?[*]const u8, _: c_int, _: c_int) ?[*]u8 {
        return null;
    }
    pub fn glin_win_gpu_free(_: ?*anyopaque) void {}
};
