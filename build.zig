const std = @import("std");

// glinlandui: agnostic Wayland GUI library (moved from qs-settings-zig
// src/wayland.zig + src/wayland/ + protocols/*.xml + stb impl).
// Owns: wayland-scanner codegen, protocol + stb + pango-shim C sources,
// clay static lib + zclay wiring, system links, and `zig build test` for
// the moved wayland tests. ZERO ui/* imports by design.
//
// zclay wiring: build.zig.zon declares `.zclay = .{ .path =
// "vendor/clay-zig-bindings" }` (path dependency, no network). The module
// itself is wired via relative path
// (`vendor/clay-zig-bindings/src/root.zig`, same pattern qs-settings-zig
// used before the move) with the clay C library built from vendored
// `vendor/clay` — this is the documented fallback: it avoids any network
// fetch (zclay's own build.zig would fetch clay from a URL dep) and
// keeps the vendored clay.h source identical to pre-move behavior.
//
// Text engine: pangocairo via src/pango_text.h/.c shim.
// Zig @cImport parses ONLY the shim header (plain C types) — real
// pango/cairo/glib headers stay inside the .c TU (system compiler) so we
// never hit G_GNUC_BEGIN_IGNORE_DEPRECATIONS translation failures.
// wayland/text.zig measures via shim, wayland/render_gles3.zig renders
// via shim ARGB32 image -> GL_RGBA texture. stb TU kept as fallback.

/// Generated Wayland protocol artifacts (client header + private-code TU).
/// Passed whole to the wayland test step: the test module needs BOTH the
/// include paths (to @cImport the headers) and the C sources (to link the
/// wl_interface symbols the listener fields reference).
const NativeProtocols = struct {
    xdg: WaylandProtocol,
    layer_shell: WaylandProtocol,
    cursor_shape: WaylandProtocol,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // The GLES3/Pango/Wayland runtime is native to Linux today. Other
    // platforms build the CPU-only Clay surface, which keeps macOS CI
    // honest: it verifies portable behavior without inventing a windowing
    // backend that the project does not yet have.
    const is_linux = target.result.os.tag == .linux;

    // ---- vendored zclay Zig bindings (moved from qs build.zig) ----
    const zclay_mod = b.createModule(.{
        .root_source_file = b.path("vendor/clay-zig-bindings/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ---- vendored clay C library (moved from qs build.zig) ----
    // clay.h is header-only: exactly one TU must define CLAY_IMPLEMENTATION.
    const clay_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });
    clay_mod.addIncludePath(b.path("vendor/clay"));
    clay_mod.addCSourceFile(.{
        .file = b.addWriteFiles().add("clay.c",
            \\#define CLAY_IMPLEMENTATION
            \\#include <clay.h>
            \\
        ),
        .flags = &.{"-ffreestanding"},
    });
    const clay_lib = b.addLibrary(.{
        .name = "clay",
        .linkage = .static,
        .root_module = clay_mod,
    });
    zclay_mod.linkLibrary(clay_lib);

    const mod = b.addModule("glinlandui", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    mod.addImport("zclay", zclay_mod);
    addVendoredStbInclude(b, mod);

    // ---- Linux-only native windowing and rendering graph ----
    var native_protocols: ?NativeProtocols = null;
    if (is_linux) {
        // ---- wayland protocol codegen (moved from qs build.zig) ----
        const xdg = genWaylandProtocol(
            b,
            b.path("protocols/xdg-shell.xml"),
            "xdg-shell-client-protocol.h",
            "xdg-shell-protocol.c",
        );
        const layer_shell = genWaylandProtocol(
            b,
            b.path("protocols/wlr-layer-shell-unstable-v1.xml"),
            "wlr-layer-shell-unstable-v1-client-protocol.h",
            "wlr-layer-shell-unstable-v1-protocol.c",
        );
        const cursor_shape = genWaylandProtocol(
            b,
            b.path("protocols/cursor-shape-v1.xml"),
            "cursor-shape-v1-client-protocol.h",
            "cursor-shape-v1-protocol.c",
        );
        native_protocols = .{
            .xdg = xdg,
            .layer_shell = layer_shell,
            .cursor_shape = cursor_shape,
        };
        mod.addIncludePath(xdg.header.dirname());
        mod.addIncludePath(layer_shell.header.dirname());
        mod.addIncludePath(cursor_shape.header.dirname());
        mod.addCSourceFile(.{ .file = xdg.code });
        mod.addCSourceFile(.{ .file = layer_shell.code });
        mod.addCSourceFile(.{ .file = cursor_shape.code });
        // Linker stub: cursor-shape-v1-protocol.c references
        // zwp_tablet_tool_v2_interface (its get_tablet_tool_v2 request takes
        // a tablet-tool object) but tablet input is never bound or used, so
        // no tablet protocol TU is generated. A generated C TU provides the
        // symbol (a Zig `export` would only land in binaries that analyze
        // wayland.zig; C sources propagate to every consumer via the module
        // link chain, including the parent qs-settings-zig test binaries).
        // get_tablet_tool_v2 is never called, so the empty table stays dead.
        addTabletToolStub(b, mod);
        // stb_truetype implementation TU kept as fallback (headless / NoDisplay).
        mod.addCSourceFile(.{ .file = b.path("src/stb_truetype_impl.c") });
        // stb_image + resize2 implementation TU (wallpaper thumbnails/preview).
        mod.addCSourceFile(.{ .file = b.path("src/stb_image_impl.c") });

        // Pangocairo shim TU + includes + system libs.
        addPangoShim(b, mod);

        // System libs propagate to consumers via linkLibrary chain.
        mod.linkSystemLibrary("wayland-client", .{});
        mod.linkSystemLibrary("wayland-egl", .{});
        mod.linkSystemLibrary("EGL", .{});
        mod.linkSystemLibrary("GLESv2", .{});
        linkTextEngine(mod);
    }
    // Clay is a portable C implementation and libc are required by every
    // host; all remaining native dependencies above are Linux-only.
    mod.linkSystemLibrary("c", .{});
    mod.linkLibrary(clay_lib);

    const exe = b.addExecutable(.{
        .name = "glinlandui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "glinlandui", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // `test` is the PARITY step. Its root module (src/root.zig) imports only
    // portable modules, so Linux and macOS compile and run the IDENTICAL set
    // of tests and report the IDENTICAL count. No OS branch lives in the
    // aggregate test block, and the native standalone roots are NOT wired in
    // here — that is what keeps the counts provably equal.
    const test_step = b.step("test", "Run the cross-platform test suite (identical on every OS)");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // `native-test` runs the Linux-only Wayland/EGL/GLES3/Pango tests. These
    // are a superset and deliberately excluded from the parity count; CI runs
    // them on Linux as an extra job, never in place of the portable suite.
    const native_test_step = b.step("native-test", "Run the Linux-only native (Wayland/EGL/GLES3/Pango) tests");
    if (native_protocols) |protocols| {
        native_test_step.dependOn(makeModuleTestStep(b, target, "src/wayland/text.zig", zclay_mod));
        native_test_step.dependOn(makeModuleTestStep(b, target, "src/wayland/render_gles3.zig", zclay_mod));
        native_test_step.dependOn(makeWaylandTestStep(b, target, zclay_mod, protocols));
    }
    // Components are not standalone test roots: they import the shared
    // renderer contract relatively, which escapes a standalone root module.
    // They are covered by src/root.zig's aggregate test on every platform.
}

/// Keep the stb implementation headers identical on every Linux runner and
/// independent of the host distribution's stb package version.
fn addVendoredStbInclude(b: *std.Build, m: *std.Build.Module) void {
    m.addIncludePath(b.path("vendor/stb"));
}

/// Pangocairo shim: compiles src/pango_text.c (real pango/cairo includes)
/// and exposes src/ for @cImport("pango_text.h"). Include flags mirror
/// `pkg-config --cflags pangocairo pango cairo fontconfig freetype2
/// harfbuzz` on Arch (verified 2026-09-06). Zig @cImport only ever sees
/// the shim header, never glib headers directly.
fn addPangoShim(b: *std.Build, m: *std.Build.Module) void {
    m.addIncludePath(b.path("src"));
    m.addCSourceFile(.{
        .file = b.path("src/pango_text.c"),
        .flags = &.{
            "-I/usr/include/pango-1.0",
            "-I/usr/include/cairo",
            "-I/usr/include/glib-2.0",
            "-I/usr/lib/glib-2.0/include",
            "-I/usr/include/harfbuzz",
            "-I/usr/include/freetype2",
            "-I/usr/include/fribidi",
            "-I/usr/include/pixman-1",
            "-I/usr/include/libpng16",
            "-I/usr/include/sysprof-6",
            "-D_GNU_SOURCE=1",
        },
    });
}

/// Text-engine system libs: pangocairo stack.
/// Names match /usr/lib .so names (pkg-config --libs pangocairo gives
/// -lpangocairo-1.0 -lpango-1.0 -lcairo -lharfbuzz -lgobject-2.0 -lglib-2.0,
/// plus fontconfig/freetype for Pango font resolution).
fn linkTextEngine(m: *std.Build.Module) void {
    m.linkSystemLibrary("cairo", .{});
    m.linkSystemLibrary("pango-1.0", .{});
    m.linkSystemLibrary("pangocairo-1.0", .{});
    m.linkSystemLibrary("fontconfig", .{});
    m.linkSystemLibrary("freetype", .{});
    m.linkSystemLibrary("harfbuzz", .{});
    m.linkSystemLibrary("gobject-2.0", .{});
    m.linkSystemLibrary("glib-2.0", .{});
}

const WaylandProtocol = struct {
    header: std.Build.LazyPath,
    code: std.Build.LazyPath,
};

fn genWaylandProtocol(
    b: *std.Build,
    xml: std.Build.LazyPath,
    header_name: []const u8,
    code_name: []const u8,
) WaylandProtocol {
    const gen_header = b.addSystemCommand(&.{ "/usr/sbin/wayland-scanner", "client-header" });
    gen_header.addFileArg(xml);
    const header = gen_header.addOutputFileArg(header_name);

    const gen_code = b.addSystemCommand(&.{ "/usr/sbin/wayland-scanner", "private-code" });
    gen_code.addFileArg(xml);
    const code = gen_code.addOutputFileArg(code_name);

    return .{ .header = header, .code = code };
}

fn makeModuleTestStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    path: []const u8,
    zclay: *std.Build.Module,
) *std.Build.Step {
    const m = b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
    });
    m.addImport("zclay", zclay);
    addVendoredStbInclude(b, m);
    addPangoShim(b, m);
    const test_exe = b.addTest(.{ .root_module = m });
    test_exe.root_module.linkSystemLibrary("c", .{});
    linkTextEngine(test_exe.root_module);
    return &b.addRunArtifact(test_exe).step;
}

/// Agnostic platform step: wayland.zig re-exports its own children
/// render_gles3.zig + text.zig. Needs zclay + generated protocol headers
/// plus libc; Renderer references GL symbols so link GLESv2.
fn makeWaylandTestStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    zclay: *std.Build.Module,
    protocols: NativeProtocols,
) *std.Build.Step {
    const m = b.createModule(.{
        .root_source_file = b.path("src/wayland.zig"),
        .target = target,
    });
    m.addImport("zclay", zclay);
    m.addIncludePath(protocols.xdg.header.dirname());
    m.addIncludePath(protocols.layer_shell.header.dirname());
    m.addIncludePath(protocols.cursor_shape.header.dirname());
    // The generated protocol C TUs supply the wl_interface symbols
    // (xdg_wm_base_interface, wp_cursor_shape_manager_v1_interface, ...).
    // This standalone module does not inherit `mod`'s C sources, and the
    // listener-ownership fields reference those interfaces at link time.
    m.addCSourceFile(.{ .file = protocols.xdg.code });
    m.addCSourceFile(.{ .file = protocols.layer_shell.code });
    m.addCSourceFile(.{ .file = protocols.cursor_shape.code });
    addTabletToolStub(b, m);
    addVendoredStbInclude(b, m);
    addPangoShim(b, m);
    const test_exe = b.addTest(.{ .root_module = m });
    test_exe.root_module.linkSystemLibrary("c", .{});
    test_exe.root_module.linkSystemLibrary("GLESv2", .{});
    // wayland-client is required at link time: Window owns the listener
    // structs as fields, so every wl_* symbol is referenced even though
    // run() itself is pruned under `builtin.is_test`. Without this the
    // test binary fails with "undefined symbol: wl_proxy_add_listener".
    test_exe.root_module.linkSystemLibrary("wayland-client", .{});
    test_exe.root_module.linkSystemLibrary("wayland-egl", .{});
    test_exe.root_module.linkSystemLibrary("EGL", .{});
    linkTextEngine(test_exe.root_module);
    return &b.addRunArtifact(test_exe).step;
}

/// Linker stub for the cursor-shape protocol's tablet-tool dependency.
/// Kept in one place so `mod` and the wayland test module cannot drift.
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
