const std = @import("std");
const support = @import("build_support");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const gl = b.dependency("glinlandui", .{ .target = target, .optimize = optimize });
    support.app(b, .{
        .name = "file_dialog",
        .id = "file-dialog",
        .label = "file dialog",
        .port = 8094,
        .gl = gl,
        .target = target,
        .optimize = optimize,
    });
}
