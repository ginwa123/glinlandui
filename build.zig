const std = @import("std");

// glinlandui: platform-agnostic Clay GUI library.

// Generated Wayland protocol artifacts (client header + private-code TU).
const NativeProtocols = struct {
    xdg: WaylandProtocol,
    layer_shell: WaylandProtocol,
    cursor_shape: WaylandProtocol,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // ---- `-Dtui`: build the terminal backend instead of a desktop window ---- The same engine, the same components, drawn into a terminal.
    const tui_flag = b.option(bool, "tui", "Build the terminal (TUI) backend instead of the desktop window") orelse false;

    // `-Doptimize` still wins; without it a terminal build is ReleaseSafe, because a terminal frame does real per-pixel work and Debug is ~10x slower at it.
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size") orelse switch (b.release_mode) {
        .off => if (tui_flag) std.builtin.OptimizeMode.ReleaseSafe else std.builtin.OptimizeMode.Debug,
        .safe, .any => .ReleaseSafe,
        .fast => .ReleaseFast,
        .small => .ReleaseSmall,
    };

    // ---- the webapp's font ---- The browser build EMBEDS a font, so `zig build web` produces a webapp whose text is glyphs with no fetch, no `assets/`.
    const font_opt = b.option(
        []const u8,
        "font",
        "Font to embed in the webapp: a path, 'auto' (default), or 'none'",
    ) orelse "auto";
    const font_path: ?[]const u8 = if (std.mem.eql(u8, font_opt, "none"))
        null
    else if (std.mem.eql(u8, font_opt, "auto"))
        detectFont()
    else
        font_opt;

    const is_linux = target.result.os.tag == .linux;
    const is_macos = target.result.os.tag == .macos;
    // The third real backend.
    const is_wasm = target.result.cpu.arch.isWasm();

    // ---- `-Dweb`: build for the browser instead of the desktop ---- `zig build run-calculator -Dweb` builds the calculator for wasm, serves it, and.
    const web_flag = b.option(bool, "web", "Build for the browser (wasm) instead of the desktop") orelse false;

    // The target the web artifacts are built for.
    const web_target = if (is_wasm) target else b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    // Hosts the calculator example is wired for: a real native windowing runtime (Linux), the portable CPU backend behind a real window (macOS), that same.
    const is_windows = target.result.os.tag == .windows;
    const calc_supported = is_linux or is_macos or is_windows or is_wasm;

    // Hosts the file-dialog example is wired for.
    const dlg_supported = is_linux or is_macos or is_windows;

    // The lazy-scroll demo exists to show a frame budget, so it ships optimized by default (Debug is ~6x slower per frame and would report a number that no

    // user sees). Override with `-Dlazy-optimize=Debug` when profiling.
    const lazy_optimize = b.option(
        std.builtin.OptimizeMode,
        "lazy-optimize",
        "Optimize mode for the lazy-scroll example (default: ReleaseSafe)",
    ) orelse .ReleaseSafe;

    // ---- vendored zclay Zig bindings (moved from qs build.zig) ---- ONE `zclay` instance per TARGET, and the Clay archive it links must be built for that.
    const zclay_mod = b.createModule(.{
        .root_source_file = b.path("vendor/clay-zig-bindings/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ---- vendored clay C library: clay.h is header-only (one TU defines CLAY_IMPLEMENTATION) and C, so it is always optimised — Debug buys it nothing.
    const clay_lib = makeClay(b, target, .ReleaseFast);
    zclay_mod.linkLibrary(clay_lib);

    const mod = b.addModule("glinlandui", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    mod.addImport("zclay", zclay_mod);
    // The composition root reads this: `platform.zig` is the one file allowed to branch, so the flag arrives as a module, not an env var.
    const build_config = b.addOptions();
    build_config.addOption(bool, "tui", tui_flag);
    mod.addOptions("glinconfig", build_config);
    addVendoredStbInclude(b, mod);
    // Vendored-library implementation TUs, both unconditional and both in core/: exactly one TU may define each STB_*_IMPLEMENTATION macro, and neither is.
    mod.addCSourceFile(.{ .file = b.path("src/core/stb_truetype_impl.c"), .flags = stbFlags(is_wasm) });
    mod.addCSourceFile(.{ .file = b.path("src/core/stb_image_impl.c"), .flags = stbFlags(is_wasm) });

    // ---- macOS-only native windowing graph ---- The Cocoa shim: one Objective-C translation unit plus the frameworks it needs.
    if (is_macos) {
        mod.addIncludePath(b.path("src/mac"));
        mod.addCSourceFile(.{
            .file = b.path("src/mac/shim.m"),
            // `-Werror` is load-bearing, not style.
            .flags = &.{"-Werror"},
        });
        // The Metal renderer: one Objective-C TU plus the two frameworks it needs.
        mod.addCSourceFile(.{
            .file = b.path("src/mac/metal.m"),
            .flags = &.{"-Werror"},
        });
        mod.linkFramework("Metal", .{});
        mod.linkFramework("QuartzCore", .{});
        mod.linkFramework("AppKit", .{});
        mod.linkFramework("Foundation", .{});
        mod.linkFramework("CoreGraphics", .{});
        // `UniformTypeIdentifiers` is where `UTType` lives, and `UTType` is what `NSOpenPanel.allowedContentTypes` takes.
        mod.linkFramework("UniformTypeIdentifiers", .{});
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
        // Linker stub: cursor-shape-v1-protocol.c references zwp_tablet_tool_v2_interface (its get_tablet_tool_v2 request takes a tablet-tool object) but.
        addTabletToolStub(b, mod);

        // System libs propagate to consumers via linkLibrary chain.
        mod.linkSystemLibrary("wayland-client", .{});
        mod.linkSystemLibrary("vulkan", .{});
        // The Vulkan shim: one C TU, with its plain-C header in src/linux so @cImport never sees a Vulkan header.
        mod.addIncludePath(b.path("src/linux"));
        mod.addCSourceFile(.{ .file = b.path("src/linux/vk.c"), .flags = &.{"-Werror"} });
    }
    // Clay is a portable C implementation, and every NATIVE host needs libc alongside it; all remaining native dependencies above are platform-gated.
    if (is_wasm) {
        mod.addIncludePath(b.path("src/web/compat"));
    } else {
        mod.linkSystemLibrary("c", .{});
    }

    // ---- Windows-only native windowing and rendering graph ---- The Win32 + D3D11 shim: one C translation unit plus the import libraries its entry points.
    if (is_windows) {
        addWindowsShim(b, mod);
        // The VT console shim, and only on a terminal build: no other Windows target links it.
        if (tui_flag) {
            mod.addCSourceFile(.{ .file = b.path("src/terminal/console_win32.c"), .flags = &.{"-Werror"} });
        }
    }

    mod.linkLibrary(clay_lib);

    // ---- WebAssembly / browser webapp ---- Built BEFORE the native executable, because `zig build run --web` depends on these install steps and Zig.
    const web_lib = makeWebModule(b, web_target, optimize, makeWebZclay(b, web_target, .ReleaseFast));

    const web = b.addExecutable(.{
        .name = "glinlandui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = web_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "glinlandui", .module = web_lib },
            },
        }),
    });
    // No `_start`, no `main`: the module is a library the page drives.
    web.entry = .disabled;
    // Keep the `export fn` surface even though nothing inside the module calls it.
    web.rdynamic = true;
    // 1 MiB stack.
    web.stack_size = 1024 * 1024;
    // Start at 16 MiB — comfortably above the Clay arena plus a 480x360 RGBA8 surface — and cap at 256 MiB so a runaway allocation is a clean wasm.
    web.initial_memory = 16 * 1024 * 1024;
    web.max_memory = 256 * 1024 * 1024;

    // The embedded font, as a GENERATED MODULE, imported by the LIBRARY: `src/web/exports.zig` installs it, because a browser has no font paths and no application should have to declare a typeface.
    const font_module = makeFontModule(b, font_path);
    web_lib.addImport("font_data", font_module);

    const install_web = b.addInstallArtifact(web, .{
        .dest_dir = .{ .override = .{ .custom = "web" } },
    });

    // The static half: index.html, shim.js, style.css and (optionally) assets/.
    const install_assets = b.addInstallDirectory(.{
        .source_dir = b.path("web"),
        .install_dir = .prefix,
        .install_subdir = "web",
    });

    const web_step = b.step("web", "Build the browser webapp (wasm module + web/ assets)");
    web_step.dependOn(&install_web.step);
    web_step.dependOn(&install_assets.step);

    // ---- Native demo executable ---- Skipped entirely for a wasm target: `src/main.zig` is a native `pub fn main` that uses `std.debug.print` and.
    var exe_opt: ?*std.Build.Step.Compile = null;
    if (!is_wasm) {
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
        exe_opt = exe;
        b.installArtifact(exe);

        // `zig build run`, or `zig build -Dweb run`: the second builds every browser module, serves the page and prints the URL instead of opening a window.
        const run_step = b.step("run", "Run the app (-Dweb to build and serve the browser version)");
        if (web_flag) {
            // `-Dweb` builds THIS app's module and the page, never the other examples.
            run_step.dependOn(&install_web.step);
            run_step.dependOn(&install_assets.step);
            run_step.dependOn(&serve_and_print(b, "demo").step);
        } else {
            const run_cmd = b.addRunArtifact(exe);
            run_step.dependOn(&run_cmd.step);
            run_cmd.step.dependOn(b.getInstallStep());
            if (b.args) |args| {
                run_cmd.addArgs(args);
            }
        }
    }

    // ---- Example apps, each a MODULE ---- `examples/<name>/root.zig` is the surface, `main.zig` is the window, and the tests import the same module the binary runs.
    var calc_test: ?*std.Build.Step.Compile = null;
    var calc_e2e_test: ?*std.Build.Step.Compile = null;
    // The calculator's module, built for the WEB target too: the same source, a second artifact.
    var calc_mod_for_web: ?*std.Build.Module = null;
    if (calc_supported) {
        const calc_mod = exampleModule(b, "calculator", target, optimize, mod);
        const calc_web_mod = exampleModule(b, "calculator", web_target, optimize, web_lib);
        calc_mod_for_web = calc_web_mod;

        const calc = exampleExe(b, "calculator", target, optimize, mod, calc_mod);
        b.installArtifact(calc);
        // The window alone, so a change to `main.zig` is compiled without building the other examples.
        const build_calc_step = b.step("build-calculator", "Compile the calculator example (no window)");
        build_calc_step.dependOn(&calc.step);

        // ---- the calculator, for the browser ---- A SECOND wasm artifact from the same module, sharing the library and the page.
        const web_calc = exampleExe(b, "calculator", web_target, optimize, web_lib, calc_web_mod);
        web_calc.entry = .disabled;
        web_calc.rdynamic = true;
        web_calc.stack_size = 1024 * 1024;
        web_calc.initial_memory = 16 * 1024 * 1024;
        web_calc.max_memory = 256 * 1024 * 1024;

        const install_web_calc = b.addInstallArtifact(web_calc, .{
            .dest_dir = .{ .override = .{ .custom = "web" } },
        });

        const web_calc_step = b.step("web-calculator", "Build the calculator for the browser");
        web_calc_step.dependOn(&install_web_calc.step);
        web_calc_step.dependOn(&install_assets.step);
        // `zig build web` is the whole set, the calculator included.
        web_step.dependOn(&install_web_calc.step);

        const run_calc_step = b.step("run-calculator", "Run the calculator (-Dweb to build and serve the browser version)");
        if (web_flag) {
            // `-Dweb`: this app's own module and the page, served, with the URL printed.
            run_calc_step.dependOn(&install_web_calc.step);
            run_calc_step.dependOn(&install_assets.step);
            run_calc_step.dependOn(&serve_and_print(b, "calculator").step);
        } else {
            const run_calc = b.addRunArtifact(calc);
            run_calc_step.dependOn(&run_calc.step);
            run_calc.step.dependOn(b.getInstallStep());
            if (b.args) |args| {
                run_calc.addArgs(args);
            }
        }

        // A separate test root over the same module: `b.addTest` compiles it as a test binary, so `pub fn main` is never an entry point.
        calc_test = exampleTest(b, calc_mod);
        calc_e2e_test = exampleE2E(b, "calculator", target, optimize, mod, calc_mod);

        const calc_test_step = b.step("test-calculator", "Run the calculator example's tests only");
        calc_test_step.dependOn(&b.addRunArtifact(calc_test.?).step);
        calc_test_step.dependOn(&b.addRunArtifact(calc_e2e_test.?).step);
    }

    // ---- Example app: 10,000 rows, virtualised ---- The performance demo: the frame cost of a scroll must depend on the window, not on the data.
    var lazy_test: ?*std.Build.Step.Compile = null;
    if (calc_supported) {
        const lazy_mod = exampleModule(b, "lazy_scroll", target, lazy_optimize, mod);
        const lazy = exampleExe(b, "lazy_scroll", target, lazy_optimize, mod, lazy_mod);
        // The clay archive is built for the dependency's mode (Debug), and a Debug C build is instrumented with UBSan; a ReleaseSafe root must bundle the runtime that satisfies those references.
        lazy.bundle_compiler_rt = true;
        b.installArtifact(lazy);
        const build_lazy_step = b.step("build-lazy-scroll", "Compile the lazy-scroll example (no window)");
        build_lazy_step.dependOn(&lazy.step);

        // ---- the same example, for the browser ---- One wasm artifact from `examples/lazy_scroll/web.zig`, sharing this library and the page.
        const lazyscroll_web = exampleWebExe(b, "lazy_scroll", web_target, lazy_optimize, web_lib, exampleModule(b, "lazy_scroll", web_target, lazy_optimize, web_lib));
        const install_lazyscroll_web = b.addInstallArtifact(lazyscroll_web, .{ .dest_dir = .{ .override = .{ .custom = "web" } } });
        const step_lazy_scroll_web = b.step("web-lazy-scroll", "Build the lazy_scroll example for the browser");
        step_lazy_scroll_web.dependOn(&install_lazyscroll_web.step);
        step_lazy_scroll_web.dependOn(&install_assets.step);
        // `zig build web` builds the whole set, so one command produces every app the page can show.
        web_step.dependOn(&install_lazyscroll_web.step);

        const run_lazy_step = b.step("run-lazy-scroll", "Run the 10,000-row lazy-scroll example (-Dweb to build and serve the browser version)");
        if (web_flag) {
            // `-Dweb`: this app's own module and the page, never the other examples.
            run_lazy_step.dependOn(&install_lazyscroll_web.step);
            run_lazy_step.dependOn(&install_assets.step);
            run_lazy_step.dependOn(&serve_and_print(b, "lazy_scroll").step);
        } else {
            const run_lazy = b.addRunArtifact(lazy);
            run_lazy_step.dependOn(&run_lazy.step);
            run_lazy.step.dependOn(b.getInstallStep());
            if (b.args) |args| {
                run_lazy.addArgs(args);
            }
        }

        // The frame-time measurement: no window, no vsync, just the frame the toolkit produces.
        const bench_lazy_step = b.step("bench-lazy-scroll", "Measure the lazy-scroll frame times (headless)");
        const bench_lazy = b.addRunArtifact(lazy);
        bench_lazy.addArgs(&.{ "--bench", "600" });
        bench_lazy_step.dependOn(&bench_lazy.step);

        lazy_test = exampleTest(b, lazy_mod);

        // The example's own tests, alone: the CI bench legs assert these before they time anything, and the parity step is far too wide for that.
        const lazy_test_step = b.step("test-lazy-scroll", "Run the lazy-scroll example's tests only");
        lazy_test_step.dependOn(&b.addRunArtifact(lazy_test.?).step);
    }

    // ---- Example app: the file dialog ---- The "how to use" for `glinlandui.file_dialog`, and the only example in this repository whose subject is an API.
    var dlg_test: ?*std.Build.Step.Compile = null;
    if (dlg_supported) {
        const dlg_mod = exampleModule(b, "file_dialog", target, optimize, mod);
        const dlg = exampleExe(b, "file_dialog", target, optimize, mod, dlg_mod);
        b.installArtifact(dlg);
        const build_dlg_step = b.step("build-file-dialog", "Compile the file-dialog example (no window)");
        build_dlg_step.dependOn(&dlg.step);

        // ---- the same example, for the browser ---- One wasm artifact from `examples/file_dialog/web.zig`, sharing this library and the page.
        const filedialog_web = exampleWebExe(b, "file_dialog", web_target, optimize, web_lib, exampleModule(b, "file_dialog", web_target, optimize, web_lib));
        const install_filedialog_web = b.addInstallArtifact(filedialog_web, .{ .dest_dir = .{ .override = .{ .custom = "web" } } });
        const step_file_dialog_web = b.step("web-file-dialog", "Build the file_dialog example for the browser");
        step_file_dialog_web.dependOn(&install_filedialog_web.step);
        step_file_dialog_web.dependOn(&install_assets.step);
        // `zig build web` builds the whole set, so one command produces every app the page can show.
        web_step.dependOn(&install_filedialog_web.step);

        const run_dlg_step = b.step("run-file-dialog", "Run the file-dialog example (-Dweb to build and serve the browser version)");
        if (web_flag) {
            // `-Dweb`: this app's own module and the page, never the other examples.
            run_dlg_step.dependOn(&install_filedialog_web.step);
            run_dlg_step.dependOn(&install_assets.step);
            run_dlg_step.dependOn(&serve_and_print(b, "file_dialog").step);
        } else {
            const run_dlg = b.addRunArtifact(dlg);
            run_dlg_step.dependOn(&run_dlg.step);
            run_dlg.step.dependOn(b.getInstallStep());
            if (b.args) |args| {
                run_dlg.addArgs(args);
            }
        }

        dlg_test = exampleTest(b, dlg_mod);

        const dlg_test_step = b.step("test-file-dialog", "Run the file-dialog example's tests only");
        dlg_test_step.dependOn(&b.addRunArtifact(dlg_test.?).step);
    }

    // ---- Example app: the MVVM todo ---- The smallest app that still has the shape a real one has: state, a ViewModel, a view, and a store.
    var todo_test: ?*std.Build.Step.Compile = null;
    var todo_e2e_test: ?*std.Build.Step.Compile = null;
    if (calc_supported) {
        const todo_mod = exampleModule(b, "todo", target, optimize, mod);
        const todo = exampleExe(b, "todo", target, optimize, mod, todo_mod);
        b.installArtifact(todo);
        const build_todo_step = b.step("build-todo", "Compile the todo example (no window)");
        build_todo_step.dependOn(&todo.step);

        // ---- the same example, for the browser ---- One wasm artifact from `examples/todo/web.zig`, sharing this library and the page.
        const todo_web = exampleWebExe(b, "todo", web_target, optimize, web_lib, exampleModule(b, "todo", web_target, optimize, web_lib));
        const install_todo_web = b.addInstallArtifact(todo_web, .{ .dest_dir = .{ .override = .{ .custom = "web" } } });
        const step_todo_web = b.step("web-todo", "Build the todo example for the browser");
        step_todo_web.dependOn(&install_todo_web.step);
        step_todo_web.dependOn(&install_assets.step);
        // `zig build web` builds the whole set, so one command produces every app the page can show.
        web_step.dependOn(&install_todo_web.step);

        const run_todo_step = b.step("run-todo", "Run the MVVM todo example (-Dweb to build and serve the browser version)");
        if (web_flag) {
            // `-Dweb`: this app's own module and the page, never the other examples.
            run_todo_step.dependOn(&install_todo_web.step);
            run_todo_step.dependOn(&install_assets.step);
            run_todo_step.dependOn(&serve_and_print(b, "todo").step);
        } else {
            const run_todo = b.addRunArtifact(todo);
            run_todo_step.dependOn(&run_todo.step);
            run_todo.step.dependOn(b.getInstallStep());
            if (b.args) |args| {
                run_todo.addArgs(args);
            }
        }

        todo_test = exampleTest(b, todo_mod);
        // The E2E suite: the real App, driven by the headless driver.
        todo_e2e_test = exampleE2E(b, "todo", target, optimize, mod, todo_mod);

        // The example's own tests, alone: the CI legs assert these before they build anything else.
        const todo_test_step = b.step("test-todo", "Run the MVVM todo example's tests only");
        todo_test_step.dependOn(&b.addRunArtifact(todo_test.?).step);
        todo_test_step.dependOn(&b.addRunArtifact(todo_e2e_test.?).step);
    }

    // ---- Example app: the component catalog ---- Every widget the toolkit ships on one screen, in the kit's palette. It is the executable form of the UI.
    var catalog_test: ?*std.Build.Step.Compile = null;
    if (calc_supported) {
        const catalog_mod = exampleModule(b, "catalog", target, optimize, mod);
        const catalog = exampleExe(b, "catalog", target, optimize, mod, catalog_mod);
        b.installArtifact(catalog);
        const build_catalog_step = b.step("build-catalog", "Compile the catalog example (no window)");
        build_catalog_step.dependOn(&catalog.step);

        // ---- the same example, for the browser ---- One wasm artifact from `examples/catalog/web.zig`, sharing this library and the page.
        const catalog_web = exampleWebExe(b, "catalog", web_target, optimize, web_lib, exampleModule(b, "catalog", web_target, optimize, web_lib));
        // The catalog is the one example that draws images, so it is the one whose browser build carries them: `examples/catalog/web.zig` imports the generated module by this name.
        catalog_web.root_module.addImport("asset_data", makeAssetsModule(b, "catalog"));
        const install_catalog_web = b.addInstallArtifact(catalog_web, .{ .dest_dir = .{ .override = .{ .custom = "web" } } });
        const step_catalog_web = b.step("web-catalog", "Build the catalog example for the browser");
        step_catalog_web.dependOn(&install_catalog_web.step);
        step_catalog_web.dependOn(&install_assets.step);
        // `zig build web` builds the whole set, so one command produces every app the page can show.
        web_step.dependOn(&install_catalog_web.step);

        const run_catalog_step = b.step("run-catalog", "Run the component catalog example (-Dweb to build and serve the browser version)");
        if (web_flag) {
            // `-Dweb`: this app's own module and the page, never the other examples.
            run_catalog_step.dependOn(&install_catalog_web.step);
            run_catalog_step.dependOn(&install_assets.step);
            run_catalog_step.dependOn(&serve_and_print(b, "catalog").step);
        } else {
            const run_catalog = b.addRunArtifact(catalog);
            run_catalog_step.dependOn(&run_catalog.step);
            run_catalog.step.dependOn(b.getInstallStep());
            if (b.args) |args| {
                run_catalog.addArgs(args);
            }
        }

        catalog_test = exampleTest(b, catalog_mod);

        const catalog_test_step = b.step("test-catalog", "Run the component catalog's tests only");
        catalog_test_step.dependOn(&b.addRunArtifact(catalog_test.?).step);
    }

    // ---- The devtool ---- `glinlanduidp` (glinlandui debug process) is the adb of this toolkit: an INDEPENDENT client that speaks to a running app.
    if (!is_wasm) {
        const demo_mod = b.createModule(.{
            .root_source_file = b.path("src/demo_app.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "glinlandui", .module = mod }},
        });
        // The client imports nothing from the framework: no Clay, no examples, no library. It knows the socket and the protocol, like adb knows a phone.
        const dp = b.addExecutable(.{
            .name = "glinlanduidp",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/dp/main.zig"),
                .target = target,
                .optimize = optimize,
                // A client needs the C runtime for `getenv` and nothing else.
                .link_libc = true,
            }),
        });
        b.installArtifact(dp);
        const dp_test = b.addTest(.{ .root_module = dp.root_module });
        const test_dp_step = b.step("test-dp", "Run glinlanduidp's own tests (verb parsing, protocol spellings)");
        test_dp_step.dependOn(&b.addRunArtifact(dp_test).step);

        // The repo's own headless runner: it LINKS the examples so an agent can read a tree without an app running.
        const inspect = b.addExecutable(.{
            .name = "glinlandui-replay",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/inspect_main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "glinlandui", .module = mod },
                    .{ .name = "demo_app", .module = demo_mod },
                    .{ .name = "calculator", .module = exampleModule(b, "calculator", target, optimize, mod) },
                    .{ .name = "todo", .module = exampleModule(b, "todo", target, optimize, mod) },
                    .{ .name = "catalog", .module = exampleModule(b, "catalog", target, optimize, mod) },
                    .{ .name = "file_dialog", .module = exampleModule(b, "file_dialog", target, optimize, mod) },
                    .{ .name = "lazy_scroll", .module = exampleModule(b, "lazy_scroll", target, lazy_optimize, mod) },
                },
            }),
        });
        b.installArtifact(inspect);
        // `zig build build-dp` installs just the client, so a CI step can run it without building the apps it never touches.
        const build_dp_step = b.step("build-dp", "Compile and install glinlanduidp (a plain `zig build` does this too)");
        build_dp_step.dependOn(&b.addInstallArtifact(dp, .{}).step);
        const build_replay_step = b.step("build-replay", "Compile and install glinlandui-replay, the headless runner");
        build_replay_step.dependOn(&b.addInstallArtifact(inspect, .{}).step);

        // `zig build inspect -- --app=todo --json`: the same tree the in-app inspector draws, on stdout, for a script or an agent.
        const run_inspect = b.addRunArtifact(inspect);
        if (b.args) |args| run_inspect.addArgs(args);
        const inspect_step = b.step("inspect", "Run glinlanduidp headless (-- --app=todo --json)");
        inspect_step.dependOn(&run_inspect.step);
    }

    // The parity suite is a NATIVE concern: a wasm target has no test runner here, and `-Dtarget=wasm32-freestanding` is for shipping the webapp, not for.
    var run_mod_tests: ?*std.Build.Step.Run = null;
    var run_exe_tests: ?*std.Build.Step.Run = null;
    if (!is_wasm) {
        // ---- the calculator, for the browser ---- A SECOND wasm artifact, from a second entry point, sharing the library and the page.
        const mod_tests = b.addTest(.{
            .root_module = mod,
        });
        run_mod_tests = b.addRunArtifact(mod_tests);

        const exe_tests = b.addTest(.{
            .root_module = exe_opt.?.root_module,
        });
        run_exe_tests = b.addRunArtifact(exe_tests);
    }

    // `test` is the PARITY step.
    const check_colors_step = b.step("check-colors",
        \\Check the platform colour hand-off (displayed == written)
    );
    if (is_macos) {
        const check_colors = b.addSystemCommand(&.{"bash"});
        check_colors.addFileArg(b.path("ci/check_macos_colors.sh"));
        check_colors.setName("ci/check_macos_colors.sh");
        check_colors_step.dependOn(&check_colors.step);
    } else if (is_windows) {
        // Deliberately NOT `bash ci/check_windows_colors.sh` here, the way the macOS leg is.
        const probe = b.addSystemCommand(&.{ "zig", "cc", "-O1" });
        probe.addFileArg(b.path("ci/check_windows_colors.c"));
        probe.addFileArg(b.path("src/windows/shim.c"));
        // MUST stay the same set `addWindowsShim` links, and for the same reason the shim TU is compiled in rather than copied: the probe is only worth running.
        probe.addArgs(&.{
            "-ld3d11", "-ldxgi",    "-ld3dcompiler_47", "-luser32",
            "-lgdi32", "-lshell32", "-lole32",
        });

        const probe_dir = "zig-out/.ci";
        const probe_exe = b.path(probe_dir ++ "/check_windows_colors.exe");
        const mk = b.addSystemCommand(&.{ "cmd", "/c" });
        mk.addArg("if not exist zig-out\\.ci mkdir zig-out\\.ci");
        probe.step.dependOn(&mk.step);
        probe.addArgs(&.{"-o"});
        probe.addFileArg(probe_exe);

        const run_probe = b.addSystemCommand(&.{ "cmd", "/c" });
        run_probe.addArg("zig-out\\.ci\\check_windows_colors.exe");
        run_probe.setName("ci/check_windows_colors (D3D11 displayed == written)");
        // The run waits for the compile, and the step waits for the run.
        run_probe.step.dependOn(&probe.step);
        check_colors_step.dependOn(&run_probe.step);
        check_colors_step.dependOn(&probe.step);
    } else {
        // Not a failure on other hosts: the hand-off only exists on the platforms that have a native presenter.
        const skip = b.addSystemCommand(&.{ "cmd", "/c" });
        skip.addArg("echo check-colors: skipped (not a macOS or Windows build)");
        check_colors_step.dependOn(&skip.step);
    }

    const test_step = b.step("test", "Run the cross-platform test suite (identical on every OS)");
    if (run_mod_tests) |r| test_step.dependOn(&r.step);
    if (run_exe_tests) |r| test_step.dependOn(&r.step);
    if (calc_test) |calc| {
        test_step.dependOn(&b.addRunArtifact(calc).step);
    }
    if (calc_e2e_test) |e2e| {
        test_step.dependOn(&b.addRunArtifact(e2e).step);
    }
    if (lazy_test) |lazy| {
        test_step.dependOn(&b.addRunArtifact(lazy).step);
    }
    // The file-dialog example's tests, for the same reason and with the same caveat: they are portable because `platform.zig` picks the PORTABLE dialog.
    if (dlg_test) |dlg| {
        test_step.dependOn(&b.addRunArtifact(dlg).step);
    }
    if (todo_test) |t| {
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    if (catalog_test) |t| {
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
    if (todo_e2e_test) |t| {
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // The Metal-vs-CPU comparison needs a Metal device, so it is a macOS step of its own and NOT part of `test` — the parity suite's count has to match on every OS.
    const mac_gpu_test_step = b.step("test-macos-gpu", "Run the macOS-only Metal renderer tests (Metal draws the CPU reference's pixels)");
    if (is_macos) {
        const m = b.createModule(.{ // A root at src/, not src/mac/: the test imports ../core/*, which is outside the
            // package path when the root lives in src/mac/.
            .root_source_file = b.path("src/mac_gpu_test.zig"),
            .target = target,
        });
        m.addImport("zclay", zclay_mod);
        m.addOptions("glinconfig", build_config);
        m.addIncludePath(b.path("src/mac"));
        addVendoredStbInclude(b, m);
        m.addCSourceFile(.{ .file = b.path("src/core/stb_truetype_impl.c"), .flags = stbFlags(false) });
        m.addCSourceFile(.{ .file = b.path("src/core/stb_image_impl.c"), .flags = stbFlags(false) });
        // The same two Objective-C TUs and frameworks the library gets, so a test that links here links in the app.
        m.addCSourceFile(.{ .file = b.path("src/mac/shim.m"), .flags = &.{"-Werror"} });
        m.addCSourceFile(.{ .file = b.path("src/mac/metal.m"), .flags = &.{"-Werror"} });
        m.linkFramework("Metal", .{});
        m.linkFramework("QuartzCore", .{});
        m.linkFramework("AppKit", .{});
        m.linkFramework("Foundation", .{});
        m.linkFramework("CoreGraphics", .{});
        m.linkFramework("UniformTypeIdentifiers", .{});
        m.linkLibrary(clay_lib);
        const t = b.addTest(.{ .root_module = m });
        t.root_module.linkSystemLibrary("c", .{});
        mac_gpu_test_step.dependOn(&b.addRunArtifact(t).step);
    } else {
        const skip = b.addSystemCommand(&.{ "echo", "test-macos-gpu: skipped (no Metal on this host)" });
        mac_gpu_test_step.dependOn(&skip.step);
    }

    // The D3D11-vs-CPU comparison needs a device, so it is a Windows step of its own and NOT part of `test` — the parity suite's count has to match on every OS.
    const win_gpu_test_step = b.step("test-windows-gpu", "Run the Windows-only D3D11 renderer tests (D3D11 draws the CPU reference's pixels)");
    if (target.result.os.tag == .windows) {
        const m = b.createModule(.{ // A root at src/, not src/windows/: the test imports ../core/*, which is outside the
            // package path when the root lives in src/windows/.
            .root_source_file = b.path("src/windows_gpu_test.zig"),
            .target = target,
        });
        m.addImport("zclay", zclay_mod);
        m.addOptions("glinconfig", build_config);
        addVendoredStbInclude(b, m);
        m.addCSourceFile(.{ .file = b.path("src/core/stb_truetype_impl.c"), .flags = stbFlags(false) });
        m.addCSourceFile(.{ .file = b.path("src/core/stb_image_impl.c"), .flags = stbFlags(false) });
        // The same shim TU and import libraries the library gets, so a test that links here links in the app.
        addWindowsShim(b, m);
        m.linkLibrary(clay_lib);
        const t = b.addTest(.{ .root_module = m });
        t.root_module.linkSystemLibrary("c", .{});
        win_gpu_test_step.dependOn(&b.addRunArtifact(t).step);
    } else {
        const skip = b.addSystemCommand(&.{ "echo", "test-windows-gpu: skipped (no D3D11 on this host)" });
        win_gpu_test_step.dependOn(&skip.step);
    }

    // `native-test` runs the Linux-only Wayland/Vulkan tests.
    const native_test_step = b.step("native-test", "Run the Linux-only native (Wayland/Vulkan) tests");
    if (native_protocols) |protocols| {
        native_test_step.dependOn(makeNativeTestStep(b, target, zclay_mod, protocols));
    }
    // The terminal backend's own suite: pure encoders, the cell renderer and a real component tree. NOT part of `test`, so the parity count stays put.
    const tui_test_step = b.step("test-tui", "Run the terminal (TUI) backend tests: encoders, cell grid and a real component tree");
    tui_test_step.dependOn(makeTuiTestStep(b, target, zclay_mod, clay_lib));

    // The calculator example's tests are NOT here: they are portable and run in the parity `test` step above on every platform.

    // ---- lint: zginlint, pinned in build.zig.zon; `zginlint:check` is the gate ----
    const zginlint_dep = b.dependency("zginlint", .{ .target = target, .optimize = optimize });
    const zginlint_exe = zginlint_dep.artifact("zginlint");
    b.step("zginlint", "Build the zginlint CLI into zig-out/bin/zginlint")
        .dependOn(&b.addInstallArtifact(zginlint_exe, .{}).step);

    // ONE line per comment block (the tool's default is 3), and `has_side_effects` keeps a rerun from being skipped.
    const zginlint_check = b.step("zginlint:check", "Enforce the zginlint rules on the tree (zero findings)");
    const run_zginlint_check = b.addRunArtifact(zginlint_exe);
    run_zginlint_check.setCwd(b.path("."));
    run_zginlint_check.addArgs(&.{ "--max-comment-lines", "1", "src", "tools", "build.zig" });
    run_zginlint_check.has_side_effects = true;
    zginlint_check.dependOn(&run_zginlint_check.step);

    // ---- size: no .zig file over 3000 lines; POSIX sh, so an opt-in step rather than the default build ----
    const lines_check = b.step("lines:check", "Fail if any .zig file exceeds 3000 lines");
    // Kept in a const of its own: a 150-character literal inside the argument list is what made `zig fmt` pad the whole call.
    const lines_cmd = "find src -name '*.zig' -exec wc -l {} + | awk '$1 > 3000 && $2 != \"total\" { print $2 \": \" $1 \" lines (max 3000)\"; bad=1 } END { exit bad }'";
    const run_lines_check = b.addSystemCommand(&.{ "sh", "-c", lines_cmd });
    run_lines_check.has_side_effects = true;
    lines_check.dependOn(&run_lines_check.step);
}

// The vendored `zclay` bindings, built for a wasm target and linked against a wasm-targeted Clay.
fn makeWebZclay(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const z = b.createModule(.{
        .root_source_file = b.path("vendor/clay-zig-bindings/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    z.linkLibrary(makeClay(b, target, optimize));
    return z;
}

// Clay, compiled for `target`.
fn makeClay(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
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
            \\// Clay truncates a frame past its element ceiling and never tells the error handler, so the engine reads the flag it keeps to itself.
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
        // `-fno-sanitize=undefined` is load-bearing: Zig instruments C sources in a Debug build, and the resulting ubsan references are NOT satisfied when a

        // ReleaseSafe root links this archive (undefined symbol: ___ubsan_handle_add_overflow). Clay is a vendored header we do not change, so its C UB checks

        // earn nothing and cost frame time.
        .flags = &.{ "-ffreestanding", "-fno-sanitize=undefined" },
    });
    return b.addLibrary(.{
        .name = "clay",
        .linkage = .static,
        .root_module = clay_mod,
    });
}

// Serve `zig-out/web` and print the URL — what "run" means for a webapp.
fn serve_and_print(b: *std.Build, app: []const u8) *std.Build.Step.Run {
    // Every app is one page away: `?app=<name>` is the only routing there is, and the dashed spelling is what `web/shim.js` lists.
    const dashed = std.mem.replaceOwned(u8, b.allocator, app, "_", "-") catch @panic("OOM");
    const url = b.fmt("http://localhost:8080/?app={s}", .{dashed});
    const cmd = b.addSystemCommand(&.{
        "bash", "-c",
    });
    cmd.addArg(b.fmt(
        \\echo "glinlandui: serving zig-out/web on http://localhost:8080"
        \\echo "glinlandui: open {s}"
        \\exec python3 -m http.server 8080 --directory zig-out/web
    , .{url}));
    return cmd;
}

// The `glinlandui` module for a wasm target.
fn makeWebModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zclay: *std.Build.Module,
) *std.Build.Module {
    const m = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    m.addImport("zclay", zclay);
    // A browser has no terminal, so the flag is always false here; the import exists because `platform.zig` reads it.
    const cfg = b.addOptions();
    cfg.addOption(bool, "tui", false);
    m.addOptions("glinconfig", cfg);
    addVendoredStbInclude(b, m);
    m.addCSourceFile(.{ .file = b.path("src/core/stb_truetype_impl.c"), .flags = stbFlags(true) });
    m.addCSourceFile(.{ .file = b.path("src/core/stb_image_impl.c"), .flags = stbFlags(true) });
    // The C-compile surface standing in for libc.
    m.addIncludePath(b.path("src/web/compat"));
    // NOTE: no `linkLibrary(clay)` here.
    return m;
}

// A module exposing the webapp's font as `pub const bytes: []const u8`.
fn makeFontModule(b: *std.Build, path: ?[]const u8) *std.Build.Module {
    const src = path orelse {
        // No font: an empty module, so the entry point's `if (bytes.len == 0)` takes the glyph-free path.
        const empty = b.addWriteFiles().add("font_data.zig",
            \\// No font was embedded. Text draws as the documented glyph-free
            \\// per-byte bars. Pass -Dfont=<path> to embed one.
            \\pub const bytes: []const u8 = "";
            \\
        );
        return b.createModule(.{ .root_source_file = empty });
    };

    // Zig 0.16's Io-based fs: `cwd()` is a `Dir` and every call needs an `Io`.
    const io = std.Io.Threaded.global_single_threaded.io();
    const data = std.Io.Dir.cwd().readFileAlloc(
        io,
        src,
        b.allocator,
        .limited(8 << 20),
    ) catch |err| {
        std.debug.print("web: could not read font {s} ({s}); text will draw as bars\n", .{ src, @errorName(err) });
        const empty = b.addWriteFiles().add("font_data.zig",
            \\pub const bytes: []const u8 = "";
            \\
        );
        return b.createModule(.{ .root_source_file = empty });
    };

    // Hex-escape every byte.
    var out = std.array_list.Managed(u8).init(b.allocator);
    out.appendSlice(
        \\// GENERATED by build.zig — do not edit, do not commit.
        \\//
        \\// The webapp's font, emitted as source so no @embedFile path semantics
        \\// are involved. See `makeFontModule` in build.zig.
        \\pub const bytes: []const u8 =
        \\    "
    ) catch @panic("OOM");
    for (data) |byte| {
        out.print("\\x{x:0>2}", .{byte}) catch @panic("OOM");
    }
    out.appendSlice(
        \\";
        \\
    ) catch @panic("OOM");

    std.debug.print("web: embedding font {s} ({d} bytes)\n", .{ src, data.len });
    const generated = b.addWriteFiles().add("font_data.zig", out.items);
    return b.createModule(.{ .root_source_file = generated });
}

// The first font in a short per-host list that exists, or null.
fn detectFont() ?[]const u8 {
    const candidates = [_][]const u8{
        // The bundled face first, so the webapp and the desktop use the same typeface.
        "src/assets/IBMPlexMono-Regular.ttf",
        // Linux.
        "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
        "/usr/share/fonts/dejavu/DejaVuSansMono.ttf",
        // macOS. NOT Menlo.ttc — a collection, which stb cannot load.
        "/System/Library/Fonts/SFNSMono.ttf",
        "/System/Library/Fonts/Monaco.ttf",
        // A vendored font, if someone drops one in.
        "web/assets/font.ttf",
    };
    for (candidates) |path| {
        if (fileExists(path)) return path;
    }
    return null;
}

// True when `path` names a readable file.
fn fileExists(path: []const u8) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    f.close(io);
    return true;
}

// Win32 + D3D11 shim TU, its include path, and the import libraries its entry points live in.
fn addWindowsShim(b: *std.Build, m: *std.Build.Module) void {
    m.addIncludePath(b.path("src/windows"));
    // No extra flags: shim.c defines COBJMACROS itself, before it includes anything.
    m.addCSourceFile(.{ .file = b.path("src/windows/shim.c") });
    m.linkSystemLibrary("d3d11", .{});
    m.linkSystemLibrary("dxgi", .{});
    m.linkSystemLibrary("d3dcompiler_47", .{});
    m.linkSystemLibrary("user32", .{});
    m.linkSystemLibrary("gdi32", .{});
    m.linkSystemLibrary("shell32", .{});
    // ole32 for the file dialog: CoCreateInstance (which CLSID_FileOpenDialog and CLSID_FileSaveDialog are) and CoTaskMemFree (which frees the.
    m.linkSystemLibrary("ole32", .{});
}

// Keep the stb implementation headers identical on every Linux runner and independent of the host distribution's stb package version.
fn addVendoredStbInclude(b: *std.Build, m: *std.Build.Module) void {
    m.addIncludePath(b.path("vendor/stb"));
}

// Extra C flags a vendored stb TU needs, per target.
fn stbFlags(is_wasm: bool) []const []const u8 {
    return if (is_wasm) &.{ "-DSTBI_NO_STDIO=1", "-DSTBIR_NO_SIMD=1" } else &.{};
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

// The single root for the Linux-only `native-test` step.
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
    // A test build selects the portable window on every platform, so the flag is false; the import still has to resolve.
    const cfg = b.addOptions();
    cfg.addOption(bool, "tui", false);
    m.addOptions("glinconfig", cfg);
    m.addIncludePath(b.path("src/linux"));
    m.addCSourceFile(.{ .file = b.path("src/linux/vk.c"), .flags = &.{"-Werror"} });
    m.addIncludePath(protocols.xdg.header.dirname());
    m.addIncludePath(protocols.layer_shell.header.dirname());
    m.addIncludePath(protocols.cursor_shape.header.dirname());
    // The generated protocol C TUs supply the wl_interface symbols (xdg_wm_base_interface, wp_cursor_shape_manager_v1_interface, ...).
    m.addCSourceFile(.{ .file = protocols.xdg.code });
    m.addCSourceFile(.{ .file = protocols.layer_shell.code });
    m.addCSourceFile(.{ .file = protocols.cursor_shape.code });
    addTabletToolStub(b, m);
    addVendoredStbInclude(b, m);
    m.addCSourceFile(.{ .file = b.path("src/core/stb_truetype_impl.c"), .flags = stbFlags(false) });
    m.addCSourceFile(.{ .file = b.path("src/core/stb_image_impl.c"), .flags = stbFlags(false) });
    const test_exe = b.addTest(.{ .root_module = m });
    test_exe.root_module.linkSystemLibrary("c", .{});
    test_exe.root_module.linkSystemLibrary("vulkan", .{});
    // wayland-client is required at link time: Window owns the listener structs as fields, so every wl_* symbol is referenced even though run() itself is.
    test_exe.root_module.linkSystemLibrary("wayland-client", .{});
    return &b.addRunArtifact(test_exe).step;
}

// Linker stub for the cursor-shape protocol's tablet-tool dependency.
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

// An example's MODULE: `examples/<name>/root.zig` re-exports the app, the view, the ViewModel and the state, so a test imports exactly what the binary runs.
fn exampleModule(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    lib: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(b.fmt("examples/{s}/root.zig", .{name})),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "glinlandui", .module = lib }},
    });
}

// An example's WINDOW: `examples/<name>/main.zig` imports its own module by name, so no file names a path.
fn exampleExe(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    lib: *std.Build.Module,
    mod: *std.Build.Module,
) *std.Build.Step.Compile {
    // The artifact keeps the hyphenated name the CI legs look for (`glinlandui-file-dialog`), even though the module is `file_dialog`.
    const dashed = std.mem.replaceOwned(u8, b.allocator, name, "_", "-") catch @panic("OOM");
    return b.addExecutable(.{
        .name = b.fmt("glinlandui-{s}", .{dashed}),
        .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}/main.zig", .{name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "glinlandui", .module = lib },
                .{ .name = name, .module = mod },
            },
        }),
    });
}

// An app's `assets/` directory, for the browser: the same bytes, emitted as source, because a page has no filesystem to open them from — and decoded by the same decoder the disk path uses.
fn makeAssetsModule(b: *std.Build, name: []const u8) *std.Build.Module {
    const dir_path = b.fmt("examples/{s}/assets", .{name});
    const io = std.Io.Threaded.global_single_threaded.io();

    var out = std.array_list.Managed(u8).init(b.allocator);
    out.appendSlice(
        \\// GENERATED by build.zig — do not edit, do not commit.
        \\//
        \\// The browser build's copy of this app's assets. Registered through the app's `web.zig`, decoded by
        \\// `core/image_store.zig` and `render_software.decodeImageBytes`, which is the same decoder the disk
        \\// path uses: a page and a desktop window draw the same pixels.
        \\pub const Asset = struct { path: []const u8, bytes: []const u8 };
        \\pub const files = [_]Asset{
        \\
    ) catch @panic("OOM");

    var count: usize = 0;
    if (std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true })) |dir| {
        var d = dir;
        var it = d.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            const path = b.fmt("{s}/{s}", .{ dir_path, entry.name });
            const data = std.Io.Dir.cwd().readFileAlloc(io, path, b.allocator, .limited(16 << 20)) catch continue;
            out.print("    .{{ .path = \"{s}\", .bytes = \"", .{path}) catch @panic("OOM");
            for (data) |byte| out.print("\\x{x:0>2}", .{byte}) catch @panic("OOM");
            out.appendSlice("\" },\n") catch @panic("OOM");
            count += 1;
        }
    } else |_| {}

    if (count == 0) out.appendSlice("    // This app has no assets.\n") catch @panic("OOM");
    out.appendSlice("};\n") catch @panic("OOM");
    std.debug.print("web: {s}: {d} asset(s) embedded for the browser\n", .{ name, count });
    const file = b.addWriteFiles().add("asset_data.zig", out.items);
    return b.createModule(.{ .root_source_file = file });
}

// An example's BROWSER artifact: `examples/<name>/web.zig` as the root, `entry = .disabled`, and the page drives it.
fn exampleWebExe(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    lib: *std.Build.Module,
    mod: *std.Build.Module,
) *std.Build.Step.Compile {
    // The page fetches `glinlandui-<name>.wasm`; the dashed name is the one CI and `?app=` use.
    const dashed = std.mem.replaceOwned(u8, b.allocator, name, "_", "-") catch @panic("OOM");
    const exe = b.addExecutable(.{
        .name = b.fmt("glinlandui-{s}", .{dashed}),
        .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}/web.zig", .{name})),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "glinlandui", .module = lib },
                .{ .name = name, .module = mod },
            },
        }),
    });
    // No `_start`, no `main`: the module is a library the page drives.
    exe.entry = .disabled;
    // Keep the `export fn` surface even though nothing inside the module calls it.
    exe.rdynamic = true;
    exe.stack_size = 1024 * 1024;
    exe.initial_memory = 16 * 1024 * 1024;
    exe.max_memory = 256 * 1024 * 1024;
    return exe;
}

// An example's own tests: every file's `test` blocks, reached through the module's root.
fn exampleTest(b: *std.Build, mod: *std.Build.Module) *std.Build.Step.Compile {
    return b.addTest(.{ .root_module = mod });
}

// An example's E2E suite: `examples/<name>/<name>_test.zig` drives the real App through the module.
fn exampleE2E(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    lib: *std.Build.Module,
    mod: *std.Build.Module,
) *std.Build.Step.Compile {
    return b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("examples/{s}/{s}_test.zig", .{ name, name })),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "glinlandui", .module = lib },
                .{ .name = name, .module = mod },
            },
        }),
    });
}

// The single root for the `test-tui` step: the terminal backend's encoders, its cell grid and a real component tree.
fn makeTuiTestStep(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    zclay: *std.Build.Module,
    clay_lib: *std.Build.Step.Compile,
) *std.Build.Step {
    const m = b.createModule(.{
        .root_source_file = b.path("src/terminal_test.zig"),
        .target = target,
    });
    m.addImport("zclay", zclay);
    // The suite drives a real Host, and the composition root reads this flag; a test build selects the portable window either way.
    const cfg = b.addOptions();
    cfg.addOption(bool, "tui", true);
    m.addOptions("glinconfig", cfg);
    addVendoredStbInclude(b, m);
    m.addCSourceFile(.{ .file = b.path("src/core/stb_truetype_impl.c"), .flags = stbFlags(false) });
    m.addCSourceFile(.{ .file = b.path("src/core/stb_image_impl.c"), .flags = stbFlags(false) });
    if (target.result.os.tag == .windows) {
        m.addCSourceFile(.{ .file = b.path("src/terminal/console_win32.c"), .flags = &.{"-Werror"} });
    }
    m.linkLibrary(clay_lib);
    const test_exe = b.addTest(.{ .root_module = m });
    test_exe.root_module.linkSystemLibrary("c", .{});
    return &b.addRunArtifact(test_exe).step;
}
