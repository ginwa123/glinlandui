const std = @import("std");
const support = @import("build_support");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const gl = b.dependency("glinlandui", .{ .target = target, .optimize = optimize });
    support.app(b, .{
        .name = "todo",
        .id = "todo",
        .label = "todo (MVVM)",
        .port = 8092,
        .gl = gl,
        .target = target,
        .optimize = optimize,
        .e2e = true,
    });
}
