const std = @import("std");
const support = @import("build_support");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const gl = b.dependency("glinlandui", .{ .target = target, .optimize = optimize });
    support.app(b, .{
        .name = "demo",
        .id = "demo",
        .label = "demo",
        .port = 8090,
        .gl = gl,
        .target = target,
        .optimize = optimize,
        .demo_app = true,
        .wasm_name = "glinlandui",
    });
}
