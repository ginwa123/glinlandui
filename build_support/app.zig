const std = @import("std");

pub const Options = struct {
    name: []const u8,
    id: []const u8,
    label: []const u8,
    port: u16,
    gl: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    e2e: bool = false,
    assets: bool = false,
    demo_app: bool = false,
    wasm_name: ?[]const u8 = null,
};

pub fn app(b: *std.Build, o: Options) void {
    const native = nativeModule(b, o);
    const app_mod = exampleModule(b, o, native, o.target);

    const exe = b.addExecutable(.{
        .name = o.name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = o.target,
            .optimize = o.optimize,
            .imports = &.{
                .{ .name = "glinlandui", .module = native },
                .{ .name = o.name, .module = app_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run this example's desktop executable (args forwarded)");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run this example's own tests through its own build graph");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = app_mod })).step);
    if (o.e2e) {
        const e2e = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("{s}_test.zig", .{o.name})),
                .target = o.target,
                .optimize = o.optimize,
                .imports = &.{
                    .{ .name = "glinlandui", .module = native },
                    .{ .name = o.name, .module = app_mod },
                },
            }),
        });
        test_step.dependOn(&b.addRunArtifact(e2e).step);
    }

    const web_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const web_lib = webModule(b, web_target, o.optimize, o.gl);
    web_lib.addImport("font_data", fontModule(b, o.gl.path("src/assets/IBMPlexMono-Regular.ttf").getPath(b)));
    const web_app = exampleModule(b, o, web_lib, web_target);

    const wasm_name = o.wasm_name orelse b.fmt("glinlandui-{s}", .{dashed(b, o.id)});
    const web_exe = b.addExecutable(.{
        .name = wasm_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("web.zig"),
            .target = web_target,
            .optimize = o.optimize,
            .imports = &.{
                .{ .name = "glinlandui", .module = web_lib },
                .{ .name = o.name, .module = web_app },
            },
        }),
    });
    if (o.assets) web_exe.root_module.addImport("asset_data", assetsModule(b, o));
    web_exe.entry = .disabled;
    web_exe.rdynamic = true;
    web_exe.stack_size = 1024 * 1024;
    web_exe.initial_memory = 16 * 1024 * 1024;
    web_exe.max_memory = 256 * 1024 * 1024;

    const install_wasm = b.addInstallArtifact(web_exe, .{ .dest_dir = .{ .override = .{ .custom = "web" } } });
    const install_page = b.addInstallDirectory(.{
        .source_dir = o.gl.path("web"),
        .install_dir = .prefix,
        .install_subdir = "web",
    });
    const install_apps = b.addInstallFile(b.path("web/apps.json"), "web/apps.json");

    const web_step = b.step("web", "Build this example's wasm module and install the page beside it");
    web_step.dependOn(&install_wasm.step);
    web_step.dependOn(&install_page.step);
    web_step.dependOn(&install_apps.step);

    const serve_step = b.step("serve", b.fmt("Serve zig-out/web on http://localhost:{d}", .{o.port}));
    serve_step.dependOn(&install_wasm.step);
    serve_step.dependOn(&install_page.step);
    serve_step.dependOn(&install_apps.step);
    serve_step.dependOn(&serveCommand(b, o).step);
}

// The dev server for `zig-out/web`: bash runs python3 on a POSIX host, and Windows gets its own form because it has neither.
fn serveCommand(b: *std.Build, o: Options) *std.Build.Step.Run {
    const url = b.fmt("http://localhost:{d}/?app={s}", .{ o.port, o.id });
    if (b.graph.host.result.os.tag == .windows) return serveWindows(b, o, url);
    const cmd = b.addSystemCommand(&.{ "bash", "-c" });
    cmd.addArg(b.fmt(
        \\echo "{s}: serving zig-out/web on http://localhost:{d}"
        \\echo "{s}: open {s}"
        \\exec python3 -m http.server {d} --directory zig-out/web
    , .{ o.label, o.port, o.label, url, o.port }));
    return cmd;
}

// Windows has no bash to `exec` in, and `python3` is the POSIX spelling: resolve the interpreter on PATH and let Python print the URL it serves.
fn serveWindows(b: *std.Build, o: Options, url: []const u8) *std.Build.Step.Run {
    const python = b.findProgram(&.{ "py.exe", "python3.exe", "python.exe" }, &.{}) catch @panic("serve needs Python 3 on PATH (py, python3 or python)");
    const cmd = b.addSystemCommand(&.{ python, "-c" });
    cmd.addArg(b.fmt(
        \\import functools, http.server, socketserver
        \\print("{s}: serving zig-out/web on http://localhost:{d}", flush=True)
        \\print("{s}: open {s}", flush=True)
        \\handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory="zig-out/web")
        \\socketserver.TCPServer(("127.0.0.1", {d}), handler).serve_forever()
    , .{ o.label, o.port, o.label, url, o.port }));
    return cmd;
}

fn dashed(b: *std.Build, id: []const u8) []const u8 {
    return std.mem.replaceOwned(u8, b.allocator, id, "_", "-") catch @panic("OOM");
}

fn exampleModule(b: *std.Build, o: Options, lib: *std.Build.Module, target: std.Build.ResolvedTarget) *std.Build.Module {
    const m = b.createModule(.{
        .root_source_file = b.path("root.zig"),
        .target = target,
        .optimize = o.optimize,
        .imports = &.{.{ .name = "glinlandui", .module = lib }},
    });
    if (o.demo_app) m.addImport("demo_app", b.createModule(.{
        .root_source_file = o.gl.path("src/demo_app.zig"),
        .target = target,
        .optimize = o.optimize,
        .imports = &.{.{ .name = "glinlandui", .module = lib }},
    }));
    return m;
}

fn nativeModule(b: *std.Build, o: Options) *std.Build.Module {
    const target = o.target;
    const optimize = o.optimize;
    const gl = o.gl;
    const is_linux = target.result.os.tag == .linux;
    const is_macos = target.result.os.tag == .macos;
    const is_windows = target.result.os.tag == .windows;
    const is_wasm = target.result.cpu.arch.isWasm();

    const zclay = b.createModule(.{
        .root_source_file = gl.path("vendor/clay-zig-bindings/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const clay_lib = makeClay(b, target, .ReleaseFast, gl);
    zclay.linkLibrary(clay_lib);

    const m = b.createModule(.{
        .root_source_file = gl.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    m.addImport("zclay", zclay);
    const cfg = b.addOptions();
    cfg.addOption(bool, "tui", false);
    m.addOptions("glinconfig", cfg);
    addVendoredStbInclude(m, gl);
    m.addCSourceFile(.{ .file = gl.path("src/core/stb_truetype_impl.c"), .flags = stbFlags(is_wasm) });
    m.addCSourceFile(.{ .file = gl.path("src/core/stb_image_impl.c"), .flags = stbFlags(is_wasm) });

    if (is_macos) {
        m.addIncludePath(gl.path("src/mac"));
        m.addCSourceFile(.{ .file = gl.path("src/mac/shim.m"), .flags = &.{"-Werror"} });
        m.addCSourceFile(.{ .file = gl.path("src/mac/metal.m"), .flags = &.{"-Werror"} });
        m.linkFramework("Metal", .{});
        m.linkFramework("QuartzCore", .{});
        m.linkFramework("AppKit", .{});
        m.linkFramework("Foundation", .{});
        m.linkFramework("CoreGraphics", .{});
        m.linkFramework("UniformTypeIdentifiers", .{});
    }

    if (is_linux) {
        const xdg = genWaylandProtocol(b, gl, "protocols/xdg-shell.xml", "xdg-shell-client-protocol.h", "xdg-shell-protocol.c");
        const layer_shell = genWaylandProtocol(b, gl, "protocols/wlr-layer-shell-unstable-v1.xml", "wlr-layer-shell-unstable-v1-client-protocol.h", "wlr-layer-shell-unstable-v1-protocol.c");
        const cursor_shape = genWaylandProtocol(b, gl, "protocols/cursor-shape-v1.xml", "cursor-shape-v1-client-protocol.h", "cursor-shape-v1-protocol.c");
        m.addIncludePath(xdg.header.dirname());
        m.addIncludePath(layer_shell.header.dirname());
        m.addIncludePath(cursor_shape.header.dirname());
        m.addCSourceFile(.{ .file = xdg.code });
        m.addCSourceFile(.{ .file = layer_shell.code });
        m.addCSourceFile(.{ .file = cursor_shape.code });
        addTabletToolStub(b, m);
        m.linkSystemLibrary("wayland-client", .{});
        m.linkSystemLibrary("vulkan", .{});
        m.addIncludePath(gl.path("src/linux"));
        m.addCSourceFile(.{ .file = gl.path("src/linux/vk.c"), .flags = &.{"-Werror"} });
    }

    if (is_wasm) {
        m.addIncludePath(gl.path("src/web/compat"));
    } else {
        m.linkSystemLibrary("c", .{});
    }

    if (is_windows) addWindowsShim(m, gl);

    m.linkLibrary(clay_lib);
    return m;
}

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
    zclay.linkLibrary(makeClay(b, target, optimize, gl));
    m.addImport("zclay", zclay);
    const cfg = b.addOptions();
    cfg.addOption(bool, "tui", false);
    m.addOptions("glinconfig", cfg);
    addVendoredStbInclude(m, gl);
    m.addCSourceFile(.{ .file = gl.path("src/core/stb_truetype_impl.c"), .flags = stbFlags(true) });
    m.addCSourceFile(.{ .file = gl.path("src/core/stb_image_impl.c"), .flags = stbFlags(true) });
    m.addIncludePath(gl.path("src/web/compat"));
    return m;
}

fn makeClay(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, gl: *std.Build.Dependency) *std.Build.Step.Compile {
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

fn addVendoredStbInclude(m: *std.Build.Module, gl: *std.Build.Dependency) void {
    m.addIncludePath(gl.path("vendor/stb"));
}

fn stbFlags(is_wasm: bool) []const []const u8 {
    return if (is_wasm) &.{ "-DSTBI_NO_STDIO=1", "-DSTBIR_NO_SIMD=1" } else &.{};
}

const WaylandProtocol = struct {
    header: std.Build.LazyPath,
    code: std.Build.LazyPath,
};

fn genWaylandProtocol(b: *std.Build, gl: *std.Build.Dependency, xml: []const u8, header_name: []const u8, code_name: []const u8) WaylandProtocol {
    const gen_header = b.addSystemCommand(&.{ "/usr/sbin/wayland-scanner", "client-header" });
    gen_header.addFileArg(gl.path(xml));
    const header = gen_header.addOutputFileArg(header_name);
    const gen_code = b.addSystemCommand(&.{ "/usr/sbin/wayland-scanner", "private-code" });
    gen_code.addFileArg(gl.path(xml));
    return .{ .header = header, .code = gen_code.addOutputFileArg(code_name) };
}

fn addTabletToolStub(b: *std.Build, m: *std.Build.Module) void {
    m.addCSourceFile(.{ .file = b.addWriteFiles().add("tablet_tool_stub.c",
        \\struct wl_interface {
        \\    const char *name;
        \\    int version;
        \\    int method_count;
        \\    const void *methods;
        \\    int event_count;
        \\    const void *events;
        \\};
        \\const struct wl_interface zwp_tablet_tool_v2_interface = {
        \\    "zwp_tablet_tool_v2", 1, 0, 0, 0, 0,
        \\};
        \\
    ) });
}

fn addWindowsShim(m: *std.Build.Module, gl: *std.Build.Dependency) void {
    m.addIncludePath(gl.path("src/windows"));
    m.addCSourceFile(.{ .file = gl.path("src/windows/shim.c") });
    m.linkSystemLibrary("d3d11", .{});
    m.linkSystemLibrary("dxgi", .{});
    m.linkSystemLibrary("d3dcompiler_47", .{});
    m.linkSystemLibrary("user32", .{});
    m.linkSystemLibrary("gdi32", .{});
    m.linkSystemLibrary("shell32", .{});
    m.linkSystemLibrary("ole32", .{});
}

fn fontModule(b: *std.Build, path: []const u8) *std.Build.Module {
    const io = std.Io.Threaded.global_single_threaded.io();
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, b.allocator, .limited(8 << 20)) catch @panic("cannot read font");
    var out = std.array_list.Managed(u8).init(b.allocator);
    out.appendSlice("pub const bytes: []const u8 = \"") catch @panic("OOM");
    for (data) |byte| out.print("\\x{x:0>2}", .{byte}) catch @panic("OOM");
    out.appendSlice("\";\n") catch @panic("OOM");
    return b.createModule(.{ .root_source_file = b.addWriteFiles().add("font_data.zig", out.items) });
}

fn assetsModule(b: *std.Build, o: Options) *std.Build.Module {
    const dir_path = b.path("assets").getPath(b);
    const prefix = b.fmt("examples/{s}/assets", .{o.name});
    const io = std.Io.Threaded.global_single_threaded.io();
    var out = std.array_list.Managed(u8).init(b.allocator);
    out.appendSlice(
        \\pub const Asset = struct { path: []const u8, bytes: []const u8 };
        \\pub const files = [_]Asset{
        \\
    ) catch @panic("OOM");
    var count: usize = 0;
    if (std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true })) |opened| {
        var dir = opened;
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            const data = std.Io.Dir.cwd().readFileAlloc(io, b.fmt("{s}/{s}", .{ dir_path, entry.name }), b.allocator, .limited(16 << 20)) catch continue;
            out.print("    .{{ .path = \"{s}/{s}\", .bytes = \"", .{ prefix, entry.name }) catch @panic("OOM");
            for (data) |byte| out.print("\\x{x:0>2}", .{byte}) catch @panic("OOM");
            out.appendSlice("\" },\n") catch @panic("OOM");
            count += 1;
        }
    } else |_| {}
    out.appendSlice("};\n") catch @panic("OOM");
    if (count == 0) @panic("catalog package has no assets");
    return b.createModule(.{ .root_source_file = b.addWriteFiles().add("asset_data.zig", out.items) });
}
