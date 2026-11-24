const std = @import("std");

/// One example, built as its own package against the toolkit: `cd examples/todo && zig build test|web|serve`.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const gl = b.dependency("glinlandui", .{ .target = target, .optimize = optimize });

    const app_mod = b.createModule(.{
        .root_source_file = b.path("root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "glinlandui", .module = gl.module("glinlandui") }},
    });

    const test_step = b.step("test", "Run the todo example's behaviour tests, headless");
    const unit = b.addTest(.{ .root_module = app_mod });
    test_step.dependOn(&b.addRunArtifact(unit).step);
    const e2e = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("todo_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "glinlandui", .module = gl.module("glinlandui") },
                .{ .name = "todo", .module = app_mod },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(e2e).step);

    const web_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const web_lib = webModule(b, web_target, optimize, gl);
    web_lib.addImport("font_data", fontModule(b, gl.path("src/assets/IBMPlexMono-Regular.ttf").getPath(b)));

    const web_app = b.createModule(.{
        .root_source_file = b.path("root.zig"),
        .target = web_target,
        .optimize = optimize,
        .imports = &.{.{ .name = "glinlandui", .module = web_lib }},
    });
    const web_exe = b.addExecutable(.{
        .name = "glinlandui-todo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("web.zig"),
            .target = web_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "glinlandui", .module = web_lib },
                .{ .name = "todo", .module = web_app },
            },
        }),
    });
    web_exe.entry = .disabled;
    web_exe.rdynamic = true;
    web_exe.stack_size = 1024 * 1024;
    web_exe.initial_memory = 16 * 1024 * 1024;
    web_exe.max_memory = 256 * 1024 * 1024;

    const install_wasm = b.addInstallArtifact(web_exe, .{
        .dest_dir = .{ .override = .{ .custom = "web" } },
    });
    const install_page = b.addInstallDirectory(.{
        .source_dir = gl.path("web"),
        .install_dir = .prefix,
        .install_subdir = "web",
    });
    const install_apps = b.addInstallFile(b.path("web/apps.json"), "web/apps.json");

    const web_step = b.step("web", "Build this app's wasm module and install the page beside it");
    web_step.dependOn(&install_wasm.step);
    web_step.dependOn(&install_page.step);
    web_step.dependOn(&install_apps.step);

    const serve = b.addSystemCommand(&.{ "bash", "-c" });
    serve.addArg(
        \\echo "glinlandui todo: serving zig-out/web on http://localhost:8091"
        \\echo "glinlandui todo: open http://localhost:8091/?app=todo"
        \\exec python3 -m http.server 8091 --directory zig-out/web
    );
    const serve_step = b.step("serve", "Serve zig-out/web on http://localhost:8091");
    serve_step.dependOn(&install_wasm.step);
    serve_step.dependOn(&install_page.step);
    serve_step.dependOn(&install_apps.step);
    serve_step.dependOn(&serve.step);
}

/// The library, compiled for the browser with everything a freestanding wasm module needs.
fn webModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, gl: *std.Build.Dependency) *std.Build.Module {
    const m = b.createModule(.{
        .root_source_file = gl.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const zclay = b.createModule(.{
        .root_source_file = gl.path("vendor/clay-zig-bindings/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    zclay.linkLibrary(clay(b, target, optimize, gl));
    m.addImport("zclay", zclay);
    const cfg = b.addOptions();
    cfg.addOption(bool, "tui", false);
    m.addOptions("glinconfig", cfg);
    m.addIncludePath(gl.path("vendor/stb"));
    m.addCSourceFile(.{ .file = gl.path("src/core/stb_truetype_impl.c"), .flags = stbFlags() });
    m.addCSourceFile(.{ .file = gl.path("src/core/stb_image_impl.c"), .flags = stbFlags() });
    m.addIncludePath(gl.path("src/web/compat"));
    return m;
}

fn clay(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, gl: *std.Build.Dependency) *std.Build.Step.Compile {
    const m = b.createModule(.{ .target = target, .optimize = optimize });
    m.addIncludePath(gl.path("vendor/clay"));
    m.addCSourceFile(.{
        .file = b.addWriteFiles().add("clay.c",
            \\#define CLAY_IMPLEMENTATION
            \\#include <clay.h>
            \\
            \\bool glin_clay_elements_exceeded(void) {
            \\    Clay_Context *c = Clay_GetCurrentContext();
            \\    return c != 0 && c->booleanWarnings.maxElementsExceeded;
            \\}
            \\
            \\int32_t glin_clay_element_count(void) {
            \\    Clay_Context *c = Clay_GetCurrentContext();
            \\    return c != 0 ? c->layoutElements.length : 0;
            \\}
            \\
        ),
        .flags = &.{ "-ffreestanding", "-fno-sanitize=undefined" },
    });
    return b.addLibrary(.{ .name = "clay", .linkage = .static, .root_module = m });
}

fn stbFlags() []const []const u8 {
    return &.{ "-DSTBI_NO_STDIO=1", "-DSTBIR_NO_SIMD=1" };
}

/// The face the module draws with, hex-escaped into a generated module: a browser has no font paths.
fn fontModule(b: *std.Build, path: []const u8) *std.Build.Module {
    const io = std.Io.Threaded.global_single_threaded.io();
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, b.allocator, .limited(8 << 20)) catch @panic("cannot read font");
    var out = std.array_list.Managed(u8).init(b.allocator);
    out.appendSlice("pub const bytes: []const u8 = \"") catch @panic("OOM");
    for (data) |byte| out.print("\\x{x:0>2}", .{byte}) catch @panic("OOM");
    out.appendSlice("\";\n") catch @panic("OOM");
    return b.createModule(.{ .root_source_file = b.addWriteFiles().add("font_data.zig", out.items) });
}
