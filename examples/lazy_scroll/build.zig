const std = @import("std");
const support = @import("build_support");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const gl = b.dependency("glinlandui", .{ .target = target, .optimize = optimize });
    support.app(b, .{
        .name = "lazy_scroll",
        .id = "lazy-scroll",
        .label = "10,000 rows",
        .port = 8095,
        .gl = gl,
        .target = target,
        .optimize = optimize,
    });
}
