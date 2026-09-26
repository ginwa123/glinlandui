const std = @import("std");

// glinlandui: platform-agnostic Clay GUI library.
//
// Layout (see REFACTOR_PLAN.md §4 and §14):
//   src/core/     platform-agnostic: components, host, frame, renderer
//                 contract + CPU rasterizer, text estimator, window contract,
//                 and the two vendored stb implementation TUs. Compiles
//                 identically on every OS; no platform @cImport.
//   src/linux/    the Wayland/EGL/GLES3/pangocairo backend.
//   src/mac/      the Cocoa/CoreGraphics backend.
//   src/platform.zig  the ONLY file that branches on builtin.os.tag.
//
// The two platform folders are a 1:1 ROLE MIRROR — same nine file names, so
// they can be read side by side:
//
//   window.zig   bootstrap, event loop, frame loop
//   input.zig    native events -> the Delegate's input contract
//   keymap.zig   native keycode -> evdev
//   adapter.zig  coords / scroll / resize / quit
//   present.zig  finished frame -> screen
//   renderer.zig renderer for this OS   (GPU on Linux, CPU on macOS)
//   text.zig     text engine for this OS (pangocairo on Linux, shared on macOS)
//   shim.h       this platform's C shim header
//   shim.c/.m    this platform's C shim TU (ObjC requires .m)
//
// "Mirror" means the same roles at the same paths, NOT the same functions: each
// file documents what the other platform has that it does not, and why.
//
// Owns: wayland-scanner codegen, protocol + stb + pango-shim C sources,
// clay static lib + zclay wiring, system links, and `zig build test` for the
// parity suite. ZERO ui/* imports by design.
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
// Text engine: pangocairo via src/linux/shim.h/.c shim.
// Zig @cImport parses ONLY the shim header (plain C types) — real
// pango/cairo/glib headers stay inside the .c TU (system compiler) so we
// never hit G_GNUC_BEGIN_IGNORE_DEPRECATIONS translation failures.
// linux/text.zig measures via shim, linux/renderer.zig renders
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
    const is_macos = target.result.os.tag == .macos;

    // Hosts the calculator example is wired for: a real native windowing
    // runtime (Linux) or the portable CPU backend (macOS). Windows is
    // intentionally NOT listed — see the example block below for why.
    const calc_supported = is_linux or target.result.os.tag == .macos;

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
    // Vendored-library implementation TUs, both unconditional and both in
    // core/: exactly one TU may define each STB_*_IMPLEMENTATION macro, and
    // neither is platform-specific — the CPU software renderer needs
    // stb_truetype on EVERY host (that is what makes the macOS build look like
    // the GLES3 one instead of drawing a bar per byte), and stb_image is the
    // image decoder the image widget uses. They live in core/ rather than in a
    // platform folder for the same reason: they are third-party TUs, not
    // platform shims. Each platform folder owns exactly ONE C TU — its shim.
    mod.addCSourceFile(.{ .file = b.path("src/core/stb_truetype_impl.c") });
    mod.addCSourceFile(.{ .file = b.path("src/core/stb_image_impl.c") });

    // ---- macOS-only native windowing graph ----
    //
    // The Cocoa shim: one Objective-C translation unit plus the frameworks it
    // needs. `linkFramework` is required, NOT `linkSystemLibrary` — the SDK
    // keeps AppKit & co. in `System/Library/Frameworks`, and `linkSystemLibrary`
    // only searches `usr/lib`, where there is no libAppKit.tbd.
    //
    // The shim is deliberately the only untestable part of the macOS backend.
    // Every decision it would otherwise make (keycodes, the y-axis flip, the
    // BGRA byte order, resize coalescing) lives in `src/mac/` as pure,
    // cross-platform, unit-tested Zig.
    //
    // The include path is GATED, not unconditional. Both platform folders now
    // expose a header called `shim.h` with different contents, so leaving
    // src/mac on Linux's include path would let linux/text.zig's
    // @cInclude("shim.h") resolve to the COCOA header. One platform's include
    // path is on at a time, which is what makes the shared header name safe.
    if (is_macos) {
        mod.addIncludePath(b.path("src/mac"));
        mod.addCSourceFile(.{ .file = b.path("src/mac/shim.m") });
        mod.linkFramework("AppKit", .{});
        mod.linkFramework("Foundation", .{});
        mod.linkFramework("CoreGraphics", .{});
    }

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
        // linux/window.zig; C sources propagate to every consumer via the module
        // link chain, including the parent qs-settings-zig test binaries).
        // get_tablet_tool_v2 is never called, so the empty table stays dead.
        addTabletToolStub(b, mod);

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

    // ---- Example app: the calculator ----
    //
    // The example drives the toolkit through its PUBLIC surface (`Window`,
    // `host.Host`, `components.*`), so it is NOT Linux-only any more: on
    // Linux `Window` is the real Wayland/EGL/GLES3/pangocairo runtime and a
    // window opens, and on macOS it is the portable backend, which renders a
    // real headless frame and reports the painted pixel count.
    //
    // `calc_supported` is the explicit list of hosts with a window backend the
    // example has actually been exercised on. Windows deliberately stays off
    // it: it would resolve the same portable module, but nothing has verified
    // that path and the CI `calculator` matrix still asserts the example is
    // ABSENT there. Promoting Windows is a one-line change to this list plus
    // flipping that matrix leg from `absent` to `present` — do not widen this
    // gate casually.
    //
    // `calc_test` is hoisted out of the block so the parity `test` step below
    // can depend on it: the example's tests are portable, so they belong in
    // the cross-platform count, not in the Linux-only `native-test` step.
    var calc_test: ?*std.Build.Step.Compile = null;
    if (calc_supported) {
        const calc_mod = b.createModule(.{
            .root_source_file = b.path("examples/calculator.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "glinlandui", .module = mod },
            },
        });
        const calc = b.addExecutable(.{
            .name = "glinlandui-calculator",
            .root_module = calc_mod,
        });
        b.installArtifact(calc);

        const run_calc_step = b.step("run-calculator", "Run the calculator example");
        const run_calc = b.addRunArtifact(calc);
        run_calc_step.dependOn(&run_calc.step);
        run_calc.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_calc.addArgs(args);
        }

        // A separate test root over the same file: `b.addTest` compiles the
        // root as a test binary, so `pub fn main` is never an entry point
        // and the example's tests run headless (no window opens).
        calc_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/calculator.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "glinlandui", .module = mod },
                },
            }),
        });
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
    //
    // The calculator example's own test root is wired in here too, and that is
    // a parity statement, not a convenience: the example is written against the
    // public surface, its `Machine` is pure Zig, its view assertions read the
    // software rasterizer's command stream, and the text backend resolves to
    // the deterministic estimator in EVERY test build. So it must report the
    // same count on both platforms — which is what makes it a useful guard.
    const test_step = b.step("test", "Run the cross-platform test suite (identical on every OS)");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    if (calc_test) |calc| {
        test_step.dependOn(&b.addRunArtifact(calc).step);
    }

    // `native-test` runs the Linux-only Wayland/EGL/GLES3/Pango tests. These
    // are a superset and deliberately excluded from the parity count; CI runs
    // them on Linux as an extra job, never in place of the portable suite.
    const native_test_step = b.step("native-test", "Run the Linux-only native (Wayland/EGL/GLES3/Pango) tests");
    if (native_protocols) |protocols| {
        native_test_step.dependOn(makeNativeTestStep(b, target, zclay_mod, protocols));
    }
    // The calculator example's tests are NOT here: they are portable and run
    // in the parity `test` step above on every platform. `native-test` is now
    // purely the native-backend superset, and is empty off Linux.
    // Components are not standalone test roots: they import the shared
    // renderer contract relatively, which escapes a standalone root module.
    // They are covered by src/root.zig's aggregate test on every platform.
}

/// Keep the stb implementation headers identical on every Linux runner and
/// independent of the host distribution's stb package version.
fn addVendoredStbInclude(b: *std.Build, m: *std.Build.Module) void {
    m.addIncludePath(b.path("vendor/stb"));
}

/// Pangocairo shim: compiles src/linux/shim.c (real pango/cairo includes)
/// and exposes src/linux/ for @cImport("shim.h"). Include flags mirror
/// `pkg-config --cflags pangocairo pango cairo fontconfig freetype2
/// harfbuzz` on Arch (verified 2026-09-06). Zig @cImport only ever sees
/// the shim header, never glib headers directly.
fn addPangoShim(b: *std.Build, m: *std.Build.Module) void {
    // src/linux, not src/: the shim header moved into the Linux backend folder
    // with its TU, and @cInclude("shim.h") from linux/text.zig and
    // linux/renderer.zig must resolve to it.
    m.addIncludePath(b.path("src/linux"));
    m.addCSourceFile(.{
        .file = b.path("src/linux/shim.c"),
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

/// The single root for the Linux-only `native-test` step.
///
/// It is rooted at `src/native_test.zig` — one level ABOVE the backends — for a
/// concrete reason, not for tidiness: Zig rejects an `@import` that escapes the
/// module's root DIRECTORY ("import of file outside module path"), and the
/// native backends import the shared `core/` modules (render_common,
/// window_contract). A module rooted at src/linux/ cannot see src/core/, so
/// the root has to sit at src/ — the same place (and the same reason) the
/// parity root `src/root.zig` sits.
///
/// That is also why this replaced THREE steps (text, renderer, window):
/// they were only separable while every native file shared one directory. The
/// union of their link flags is what this one step links.
fn makeNativeTestStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    zclay: *std.Build.Module,
    protocols: NativeProtocols,
) *std.Build.Step {
    const m = b.createModule(.{
        .root_source_file = b.path("src/native_test.zig"),
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
