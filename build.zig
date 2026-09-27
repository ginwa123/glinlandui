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

    // ---- the webapp's font ----
    //
    // The browser build EMBEDS a font, so `zig build web` produces a webapp whose
    // text is glyphs with no fetch, no `assets/` directory and no server
    // configuration. That is a decision about the APPLICATION, not about the
    // library: `glinlandui` itself bundles no font and never will (see
    // `core/text_portable.zig`'s candidate list — it holds PATHS, and a browser
    // has none). `src/web_main.zig` is an application, so it may choose a face.
    //
    // Three values, and the third is the escape hatch:
    //   - a path        -> embed that file
    //   - "auto" (default) -> the first of a short per-host list that exists
    //   - "none"        -> embed nothing; text draws as the documented glyph-free
    //                      per-byte bars, and the module stays ~340 KB smaller
    //
    // The default is a MONOSPACE face on purpose. The layout estimator measures
    // `0.6 * font_size` per byte, which is a monospace assumption; a proportional
    // face would rasterize correctly and lay out slightly wrong. DejaVu Sans Mono
    // is also under a permissive licence (Bitstream Vera derivative), which
    // matters because embedding redistributes it.
    //
    // NOT a `.ttc`: `stbtt_InitFont` cannot load a TrueType collection, which is
    // why `glyphs.Font.loadDefault` walks a candidate list at all. macOS's first
    // candidate is `Menlo.ttc`, so the auto list below deliberately skips it.
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
    // The third real backend. A wasm target is neither linux nor macos, so it
    // would otherwise fall through to the CPU-only surface — correct, but with
    // no window, no loop and no way for a page to reach it. `is_wasm` is what
    // gives it a real backend and an artifact.
    const is_wasm = target.result.cpu.arch.isWasm();

    // ---- `-Dweb`: build for the browser instead of the desktop ----
    //
    // `zig build run-calculator -Dweb` builds the calculator for wasm, serves it,
    // and prints the URL.
    //
    // ## Why `-Dweb` and not `--web`
    //
    // `--web` is NOT available: `zig build` has its own built-in `--webui` flag,
    // and it parses `--web` as an abbreviation of that rather than forwarding it
    // to this script. The result is a build that silently does nothing — no
    // error, no output, no server — which is exactly the kind of failure that
    // costs an hour. `-D` is the unambiguous spelling for a build option.
    //
    // ## Why it is a BUILD-time option and not a runtime one
    //
    // The target is a compile-time property. A `wasm32-freestanding` module and an
    // `x86_64-linux` binary are different machine code with different allocators
    // and different module graphs, so "which platform" cannot be decided when the
    // program runs — by then the program already exists.
    //
    // What `-Dweb` therefore selects is a BUILD, and the `run-*` steps do the
    // three things "run it" means for a webapp: build, serve, print the URL.
    const web_flag = b.option(bool, "web", "Build for the browser (wasm) instead of the desktop") orelse false;

    // The target the web artifacts are built for. When the user asked for a wasm
    // target directly (`-Dtarget=wasm32-freestanding`), that wins; otherwise
    // `--web` pins it.
    const web_target = if (is_wasm) target else b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    // Hosts the calculator example is wired for: a real native windowing
    // runtime (Linux), the portable CPU backend behind a real window (macOS),
    // that same portable backend headless (Windows), or the browser
    // (`wasm32-freestanding`). See the example block below.
    //
    // The web arm is what makes `zig build web-calculator` exist. It is a
    // separate STEP rather than a second artifact of `zig build web`, because the
    // two applications have different entry points and different window sizes —
    // and because the CI matrix asserts the example is ABSENT on hosts not in
    // this list, so "the calculator is wired here" has to be a fact the build can
    // state, not a side effect.
    const is_windows = target.result.os.tag == .windows;
    const calc_supported = is_linux or is_macos or is_windows or is_wasm;

    // ---- vendored zclay Zig bindings (moved from qs build.zig) ----
    //
    // ONE `zclay` instance per TARGET, and the Clay archive it links must be built
    // for that same target. That is invariant I5 restated precisely: `@import("zclay")`
    // must resolve to a single module *within a build*, or Clay types stop being
    // the same type across the library boundary — but the native build and the
    // wasm build never meet, so each gets its own.
    //
    // Getting this wrong is not a type error, it is a LINK error, and a confusing
    // one: `zclay_mod.linkLibrary(clay_lib)` carries the archive into every module
    // that imports `zclay`, so a host-built `libclay.a` rode into the wasm link and
    // `wasm-ld` rejected it with
    //   `archive member 'clay.o' is neither Wasm object file nor LLVM bitcode`.
    // The native build never notices, because native-linking-native is fine.
    const zclay_mod = b.createModule(.{
        .root_source_file = b.path("vendor/clay-zig-bindings/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ---- vendored clay C library (moved from qs build.zig) ----
    // clay.h is header-only: exactly one TU must define CLAY_IMPLEMENTATION.
    const clay_lib = makeClay(b, target, optimize);
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
    mod.addCSourceFile(.{ .file = b.path("src/core/stb_truetype_impl.c"), .flags = stbFlags(is_wasm) });
    mod.addCSourceFile(.{ .file = b.path("src/core/stb_image_impl.c"), .flags = stbFlags(is_wasm) });

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
        mod.addCSourceFile(.{
            .file = b.path("src/mac/shim.m"),
            // `-Werror` is load-bearing, not style. The shim is the one
            // untestable part of the toolkit (it owns NSWindow/NSView and
            // nothing else), and its most likely bug is messaging a
            // selector AppKit does not implement. That is a WARNING in
            // clang, so the build passed and the app shipped a runtime
            // `NSInvalidArgumentException` on every single mouse event:
            // `-[NSEvent locationInView:]` does not exist, so no press or
            // release ever reached the toolkit and every macOS click was a
            // no-op. Promoting warnings to errors here turns that class of
            // mistake into a build failure. Verified against the SDK: with
            // the fix in place the file compiles with zero warnings, so
            // nothing else is silenced by accident.
            .flags = &.{"-Werror"},
        });
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
    // Clay is a portable C implementation, and every NATIVE host needs libc
    // alongside it; all remaining native dependencies above are platform-gated.
    //
    // A wasm32-freestanding target has no libc at all — `linkSystemLibrary("c")`
    // is a hard link failure there — so the freestanding C-compile surface is
    // supplied instead: the declaration-only headers in `src/web/compat`, which
    // is all that `@cImport` and the vendored C TUs need, plus
    // `src/web/compat_impl.zig`, which EXPORTS the symbols those declarations
    // promise. See that file for the symbol list and why it is a Zig TU rather
    // than a C one.
    //
    // The include path is GATED, exactly as `src/mac` is above and for the same
    // reason: an unconditional compat path would let `stb_truetype.h`'s
    // `#include <stdlib.h>` silently resolve to OUR header on a native build,
    // changing what the Linux and macOS backends compile against. This is the
    // trap `ci/check_layering.sh` rule R7 exists to catch.
    if (is_wasm) {
        mod.addIncludePath(b.path("src/web/compat"));
    } else {
        mod.linkSystemLibrary("c", .{});
    }

    // ---- Windows-only native windowing and rendering graph ----
    //
    // The Win32 + D3D11 shim: one C translation unit plus the import
    // libraries its entry points live in. The include path is GATED for the
    // same reason the macOS one is — all three platform folders expose a
    // header called `shim.h` with different contents, so only one platform's
    // include path is ever on at a time, which is what makes the shared
    // header name safe.
    if (is_windows) {
        addWindowsShim(b, mod);
    }

    mod.linkLibrary(clay_lib);

    // ---- WebAssembly / browser webapp ----
    //
    // Built BEFORE the native executable, because `zig build run --web` depends on
    // these install steps and Zig requires a declaration to precede its use.
    //
    // The third real backend, and the only artifact that is not a native
    // executable. Three things make it structurally different, and all three are
    // why it gets its own module rather than an `if` inside the native one:
    //
    //   1. NO LIBC. `wasm32-freestanding` has none, so the compat surface above
    //      replaces it. The resulting module should have an EMPTY import
    //      section, which is what `web/smoke.mjs` asserts — a freestanding wasm
    //      module that needs nothing from its host is the strongest statement
    //      this repository's no-dependency style can make.
    //   2. NO ENTRY POINT. `entry = .disabled`, because JS owns the lifetime:
    //      the exports in `src/web/shim.h` are the interface, and
    //      `glin_web_run` only arms the loop.
    //   3. NO WINDOWING SYSTEM. No Wayland, no EGL, no AppKit, no pango. The
    //      renderer is `core/render_software.zig` (as on macOS) and the display
    //      is a `<canvas>`.
    //
    // `web_target` is pinned above so that `--web` works from a native host
    // without also passing `-Dtarget`; when the user DID ask for a wasm target,
    // it is their target that is used.
    //
    // TWO modules, and the split is load-bearing.
    //
    // `web_lib` is the library, rooted at `src/root.zig` — the same root the
    // native module uses, so the public surface is identical.
    //
    // `web` is the EXECUTABLE, rooted at `src/main.zig` — the SAME file the
    // native executable uses. That is the whole point of the collapse: one source
    // file per application, three platforms. The browser's `export fn` surface
    // arrives through `platform.web_exports`, which `main.zig` references in a
    // `comptime` block so the linker keeps it.
    //
    // Rooting the executable at the LIBRARY instead (which an earlier version
    // did) produces a module that exports `memory` and NOTHING ELSE: Zig analyses
    // lazily from the root, nothing imports the export surface, so it is never
    // analysed and the linker has no exports to keep. The page then fails on its
    // first call with `glin_web_init is not a function` and shows a black canvas.
    const web_lib = makeWebModule(b, web_target, optimize, makeWebZclay(b, web_target, optimize));

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
    // Keep the `export fn` surface even though nothing inside the module calls
    // it. Without this the linker is entitled to drop the exports.
    web.rdynamic = true;
    // 1 MiB stack. The render path is shallow (Clay layout + the rasterizer),
    // but the rasterizer's per-glyph loops and Clay's recursive walk both live
    // on it, and the default is small enough to be worth raising once here
    // rather than debugging a stack overflow later.
    web.stack_size = 1024 * 1024;
    // Start at 16 MiB — comfortably above the Clay arena plus a 480x360 RGBA8
    // surface — and cap at 256 MiB so a runaway allocation is a clean wasm
    // out-of-memory rather than a browser tab the OOM killer takes down.
    web.initial_memory = 16 * 1024 * 1024;
    web.max_memory = 256 * 1024 * 1024;

    // The embedded font, handed to the entry point as a GENERATED MODULE.
    //
    // ## Why not `@embedFile`
    //
    // `@embedFile` resolves its argument against the IMPORTING FILE's package
    // root — `src/` — so a build-cache path is unreachable, and a host path like
    // `/usr/share/fonts/...` is rejected outright with `embed of file outside
    // package path`. Both were tried; neither can work.
    //
    // So the bytes are emitted as a Zig SOURCE FILE instead, and imported as an
    // anonymous module. That has no path semantics to satisfy: the compiler is
    // handed a file it already knows how to find, and the bytes arrive as an
    // ordinary `[]const u8` constant. The hex escaping makes the intermediate
    // file ~4x the font size, but the compiler folds it into the data section, so
    // the final wasm is the same size `@embedFile` would have produced — and the
    // intermediate lives in `.zig-cache/`, never in the repository.
    //
    // ## What the developer gets
    //
    //   zig build web                      # auto-detect; text is glyphs
    //   zig build web -Dfont=/path/to.ttf  # a specific face
    //   zig build web -Dfont=none          # no font; ~340 KB smaller, text is bars
    //
    // No fetch, no `assets/` directory, no server configuration, no 404.
    const font_module = makeFontModule(b, font_path);
    web_lib.addImport("font_data", font_module);
    web.root_module.addImport("font_data", font_module);

    const install_web = b.addInstallArtifact(web, .{
        .dest_dir = .{ .override = .{ .custom = "web" } },
    });

    // The static half: index.html, shim.js, style.css and (optionally)
    // assets/. Installed next to the .wasm so `zig-out/web` is a complete,
    // servable site with no build step in between.
    const install_assets = b.addInstallDirectory(.{
        .source_dir = b.path("web"),
        .install_dir = .prefix,
        .install_subdir = "web",
    });

    const web_step = b.step("web", "Build the browser webapp (wasm module + web/ assets)");
    web_step.dependOn(&install_web.step);
    web_step.dependOn(&install_assets.step);

    // ---- Native demo executable ----
    //
    // Skipped entirely for a wasm target: `src/main.zig` is a native `pub fn
    // main` that uses `std.debug.print` and `std.heap.page_allocator`, and a
    // wasm32-freestanding module has neither an entry point nor a process
    // allocator that grows linear memory. The browser's entry point is the SAME
    // `src/main.zig`, reached through `platform.web_exports`.
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

        // `zig build run` — and `zig build run --web`, which builds the webapp,
        // serves it and prints the URL instead of launching a window.
        const run_step = b.step("run", "Run the app (--web to build and serve the browser version)");
        if (web_flag) {
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

    // ---- Example app: the calculator ----
    //
    // The example drives the toolkit through its PUBLIC surface (`Window`,
    // `host.Host`, `components.*`), so it is NOT Linux-only: on Linux
    // `Window` is the real Wayland/EGL/GLES3/pangocairo runtime, on macOS the
    // real Cocoa backend, and on Windows the real Win32/D3D11 backend — each
    // opening a real window. On a host with no window station (a headless
    // service session, a container) `Window.run()` returns the same
    // "no display" error Linux and macOS already return, and the example
    // falls back to a real headless render and reports the painted pixel
    // count, so the example still works there and CI still has something to
    // assert on.
    //
    // `calc_supported` is the explicit list of hosts with a window backend the
    // example has actually been exercised on. Windows is on it because
    // `.github/workflows/ci.yml` runs the same `present` assertions there as on
    // the other two — see the calculator job. Removing it does not delete the
    // backend; it just stops CI from requiring the example to build.
    //
    // `calc_test` is hoisted out of the block so the parity `test` step below
    // can depend on it: the example's tests are portable, so they belong in
    // the cross-platform count, not in the Linux-only `native-test` step.
    var calc_test: ?*std.Build.Step.Compile = null;
    var calc_e2e_test: ?*std.Build.Step.Compile = null;
    // The calculator's source, built for the WEB target. Declared out here
    // because the `web-calculator` step below needs it, and it must be a
    // DIFFERENT module instance from the native `calc_mod`: a module carries its
    // target, and `examples/calculator.zig` cannot belong to two modules at once
    // (Zig rejects that outright — `file exists in modules 'a' and 'b'`).
    //
    // The target is `web_target`, NOT `target`. Getting that wrong is not a type
    // error: the module would be built for the host, so it would link the native
    // `glinlandui` module and drag Wayland, EGL and pango into a wasm link —
    // which fails with a wall of `unable to find dynamic system library
    // 'wayland-client'` rather than anything mentioning the target.
    var calc_mod_for_web: ?*std.Build.Module = null;
    if (calc_supported) {
        const calc_mod = b.createModule(.{
            .root_source_file = b.path("examples/calculator.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "glinlandui", .module = mod },
            },
        });
        calc_mod_for_web = b.createModule(.{
            .root_source_file = b.path("examples/calculator.zig"),
            .target = web_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "glinlandui", .module = web_lib },
            },
        });
        const calc = b.addExecutable(.{
            .name = "glinlandui-calculator",
            .root_module = calc_mod,
        });
        b.installArtifact(calc);

        // ---- the calculator, for the browser ----
        //
        // A SECOND wasm artifact, from the SAME source file, sharing the library
        // and the page. `zig build web-calculator` installs it as
        // `zig-out/web/glinlandui-calculator.wasm`, and `web/shim.js` picks it up
        // when the URL says `?app=calculator` — so one page serves both
        // applications and the only difference is which module it fetches.
        //
        // Declared BEFORE `run-calculator` because that step depends on it when
        // `--web` is set, and Zig requires a declaration to precede its use.
        //
        // The calculator's own tests are already in the parity suite (they are
        // portable), so this adds no test count. What it adds is the artifact.
        const web_calc = b.addExecutable(.{
            .name = "glinlandui-calculator",
            // Rooted at `examples/calculator.zig` — the SAME file the native
            // executable uses. There is no `web_calculator_main.zig`; the browser
            // surface arrives through `platform.web_exports`, which the example's
            // `main` references in a `comptime` block.
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/calculator.zig"),
                .target = web_target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "glinlandui", .module = web_lib },
                },
            }),
        });
        web_calc.entry = .disabled;
        web_calc.rdynamic = true;
        web_calc.stack_size = 1024 * 1024;
        web_calc.initial_memory = 16 * 1024 * 1024;
        web_calc.max_memory = 256 * 1024 * 1024;
        web_calc.root_module.addImport("font_data", font_module);

        const install_web_calc = b.addInstallArtifact(web_calc, .{
            .dest_dir = .{ .override = .{ .custom = "web" } },
        });

        const web_calc_step = b.step("web-calculator", "Build the calculator for the browser");
        web_calc_step.dependOn(&install_web_calc.step);
        web_calc_step.dependOn(&install_assets.step);

        const run_calc_step = b.step("run-calculator", "Run the calculator (--web to build and serve the browser version)");
        if (web_flag) {
            // `--web`: build the wasm artifact, install the page, serve, print URL.
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

        // The E2E suite for the same example. A separate test root, so it is a
        // separate binary: it drives the calculator through the public
        // `glinlandui.testing` surface rather than through the app's own tests,
        // which is exactly what makes it a usage example for the E2E layer.
        //
        // The calculator arrives as an IMPORTED MODULE, not as a relative
        // `@import("calculator.zig")`. That distinction is load-bearing: Zig's
        // test collector walks file-path imports inside the module under test,
        // so a relative import would collect calculator.zig's own 36 tests into
        // this binary too — running them a second time and inflating the
        // locked parity count. It does not walk into imported modules, so
        // `calc_test` above stays the single home for those 36.
        calc_e2e_test = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/calculator_e2e_test.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "glinlandui", .module = mod },
                    .{ .name = "calculator", .module = calc_mod },
                },
            }),
        });
    }

    // The parity suite is a NATIVE concern: a wasm target has no test runner
    // here, and `-Dtarget=wasm32-freestanding` is for shipping the webapp, not
    // for running tests. Gating the roots rather than the runs is deliberate —
    // `b.addTest` would otherwise try to produce a wasm test binary and then
    // execute it through a runtime this build does not require anywhere else.
    var run_mod_tests: ?*std.Build.Step.Run = null;
    var run_exe_tests: ?*std.Build.Step.Run = null;
    if (!is_wasm) {
        // ---- the calculator, for the browser ----
        //
        // A SECOND wasm artifact, from a second entry point, sharing the library and
        // the page. `zig build web-calculator` installs it as
        // `zig-out/web/glinlandui-calculator.wasm`, and `web/shim.js` picks it up
        // when the URL says `?app=calculator` — so one page serves both applications
        // and the only difference is which module it fetches.
        //
        // It lives HERE, after the calculator block, because it needs
        // `calc_mod_for_web` — and that module must be a DIFFERENT instance from the
        // native `calc_mod`, since a module carries its target and
        const mod_tests = b.addTest(.{
            .root_module = mod,
        });
        run_mod_tests = b.addRunArtifact(mod_tests);

        const exe_tests = b.addTest(.{
            .root_module = exe_opt.?.root_module,
        });
        run_exe_tests = b.addRunArtifact(exe_tests);
    }

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
    // `check-colors` proves the macOS pixel hand-off for real.
    //
    // The parity suite CANNOT do this: `mac/present.zig`'s tests compare the
    // blit buffer against the surface it came from, i.e. against the
    // implementation's own idea of the answer, and the thing that actually
    // goes wrong lives in `mac/shim.m`'s `kGlinBitmapInfo`, which no Zig test
    // can reach. A wrong byte-order flag there rendered the whole window
    // bright red with every one of those tests still green. This step drives
    // CoreGraphics for real and compares the DISPLAYED colour with the colour
    // that was written — no window server, no Screen Recording permission, so
    // it is safe on any macOS machine and in CI.
    //
    // It is a separate step (and a separate `zig build check-colors`) rather
    // than part of `test` because it is macOS- or Windows-only and must not
    // perturb the cross-platform test count, which is what `tests.lock` pins.
    //
    // The Windows gate is the same idea for D3D11: `windows/present.zig`
    // claims the RGBA8 hand-off is the identity (no channel swap, no vertical
    // flip), and the tests there can only compare the upload buffer against the
    // surface it came from. What actually goes wrong lives in the shim's
    // swap-chain format and shader, where no Zig test can reach.
    const check_colors_step = b.step("check-colors",
        \\Check the platform colour hand-off (displayed == written)
    );
    if (is_macos) {
        const check_colors = b.addSystemCommand(&.{"bash"});
        check_colors.addFileArg(b.path("ci/check_macos_colors.sh"));
        check_colors.setName("ci/check_macos_colors.sh");
        check_colors_step.dependOn(&check_colors.step);
    } else if (is_windows) {
        // Deliberately NOT `bash ci/check_windows_colors.sh` here, the way the
        // macOS leg is. bash is not guaranteed to exist on a Windows developer
        // machine â€” Git for Windows ships it, but a machine with the toolchain
        // and nothing else does not â€” and a gate that cannot run is worse than
        // no gate. So the two things the script does are spelled out as build
        // steps: compile the real shim plus the probe, then run the probe. A
        // non-zero exit from the probe fails the build, exactly as a failing
        // script would.
        //
        // The shim TU is compiled IN, not a copy of its draw path, so the check
        // cannot drift from what the window actually does.
        //
        // Two Windows details, both learned the hard way:
        //
        //  - The exe path is a plain lazy path, not addOutputFileArg. This Run
        //    step EXECUTES the binary, and Zig will not infer a file type for a
        //    path another step declared as an output, so it errors out with
        //    "unrecognized file extension" before anything runs.
        //  - `cmd /c` is given that path RELATIVE to the build root, which is
        //    the Run step's working directory. That keeps the build root out
        //    of the argument list entirely, so a checkout whose path contains
        //    spaces cannot split the command in half. `zig cc` also does not
        //    create its output directory, hence the `if not exist` step.
        const probe = b.addSystemCommand(&.{ "zig", "cc", "-O1" });
        probe.addFileArg(b.path("ci/check_windows_colors.c"));
        probe.addFileArg(b.path("src/windows/shim.c"));
        probe.addArgs(&.{
            "-ld3d11", "-ldxgi", "-ld3dcompiler_47", "-luser32", "-lgdi32",
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
        // Not a failure on other hosts: the hand-off only exists on the
        // platforms that have a native presenter.
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

/// The vendored `zclay` bindings, built for a wasm target and linked against a
/// wasm-targeted Clay.
///
/// A second `zclay` instance exists because the bindings module CARRIES its Clay
/// archive: `zclay_mod.linkLibrary(clay_lib)` propagates to every module that
/// imports `zclay`, so the native instance would drag an x86-64 `libclay.a` into
/// the wasm link. `wasm-ld` rejects that with
/// `archive member 'clay.o' is neither Wasm object file nor LLVM bitcode`.
///
/// Invariant I5 says `@import("zclay")` must resolve to ONE module — and it does,
/// within each build. The native build has one instance, the wasm build has
/// another, and they never meet: no artifact contains both, and no type crosses
/// between them. What I5 forbids is two instances *in the same build*, which is
/// what a relative `@import("../../vendor/…")` would create.
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

/// Clay, compiled for `target`.
///
/// `clay.h` is header-only, so exactly one TU must define `CLAY_IMPLEMENTATION` —
/// the same rule the native graph follows, and the reason this is a generated
/// source file rather than a checked-in one.
///
/// ## Why this is a function and not an inline block
///
/// It is called TWICE, for two different targets: once for the build's own target
/// (the native graph) and once for `web_target` (the browser graph). That is not
/// duplication for its own sake — a static archive is architecture-specific, and
/// reusing the host's for a wasm link is exactly the bug this shape prevents:
///
///   `wasm-ld: archive member 'clay.o' is neither Wasm object file nor LLVM bitcode`
///
/// The native build never notices a mistake here, because native-linking-native
/// is fine. Only the wasm link complains, and only at link time.
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
        ),
        .flags = &.{"-ffreestanding"},
    });
    return b.addLibrary(.{
        .name = "clay",
        .linkage = .static,
        .root_module = clay_mod,
    });
}

/// Serve `zig-out/web` and print the URL — what "run" means for a webapp.
///
/// `zig build run-calculator --web` should leave you with a running server and a
/// URL to open, because that is the closest thing to "run it" a browser app has.
/// The alternative — build only, and tell the user to run `zig build serve` — is
/// less magic but makes the `run-` prefix a lie.
///
/// `app` selects the URL: `?app=calculator` loads the calculator module, anything
/// else the demo. Both are served from the same directory by the same page.
///
/// `python3` rather than npm on purpose: the whole point of the browser backend is
/// that it needs no JavaScript toolchain, so the development server should not
/// introduce one. A served origin is required — `fetch` of the `.wasm` fails from
/// a `file://` page.
fn serve_and_print(b: *std.Build, app: []const u8) *std.Build.Step.Run {
    const url = if (std.mem.eql(u8, app, "calculator"))
        "http://localhost:8080/?app=calculator"
    else
        "http://localhost:8080/";
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

/// The `glinlandui` module for a wasm target.
///
/// This duplicates a handful of lines from the native module graph on purpose.
/// The alternative — one factory called twice — was considered and rejected: the
/// native path takes OS-gated C sources, Wayland protocol codegen, the pango
/// shim and eight system libraries, none of which a wasm build may see. A single
/// factory would need every one of those behind a target test, which makes the
/// NATIVE path harder to read in exchange for avoiding a short, plainly
/// wasm-only function. Keeping the graphs separate bounds the drift risk to the
/// parts they genuinely share, and those are exactly four declarations:
///
///   - the same `zclay` module instance (invariant I5: `@import("zclay")` must
///     resolve to ONE module, or Clay types stop being the same type across the
///     library boundary — and `build.zig.zon`'s path dependency is what makes
///     that possible without any network fetch);
///   - the same vendored stb include path;
///   - the same two vendored stb implementation TUs, with `stbFlags(true)`;
///   - Clay, built FOR WASM (see below).
///
/// What is absent is the point: no `linkSystemLibrary` at all, no EGL/Wayland/
/// pango, no `src/mac` or `src/linux` include path. The module should link with
/// an EMPTY import section, which `web/smoke.mjs` asserts.
///
/// ## Clay has to be compiled for the target, not borrowed
///
/// The first version of this took the host's `clay_lib` as a parameter and linked
/// it. That cannot work, and the failure is worth recording because it is not
/// obvious from the source: `clay_lib` is built with the BUILD's target, so it is
/// an x86-64 archive, and `wasm-ld` rejects it with
/// `archive member 'clay.o' is neither Wasm object file nor LLVM bitcode`. The
/// native build never notices, because native-linking-native is fine.
///
/// So Clay is built here, for `target`. It is the same header-only C with the same
/// `-ffreestanding` flag — the only difference is which architecture the object
/// file is for.
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
    addVendoredStbInclude(b, m);
    m.addCSourceFile(.{ .file = b.path("src/core/stb_truetype_impl.c"), .flags = stbFlags(true) });
    m.addCSourceFile(.{ .file = b.path("src/core/stb_image_impl.c"), .flags = stbFlags(true) });
    // The C-compile surface standing in for libc. GATED here in the sense that
    // it is only ever added for a wasm target — this function is only called
    // for one — because an unconditional `src/web/compat` on the include path
    // would let `stb_truetype.h`'s `#include <stdlib.h>` resolve to OUR header
    // on a native build. Rule R7 in ci/check_layering.sh watches for that.
    m.addIncludePath(b.path("src/web/compat"));
    // NOTE: no `linkLibrary(clay)` here. Clay arrives through `zclay`, which the
    // caller built against a wasm-targeted archive — see the `zclay_mod` comment
    // in `build` for why linking it twice, or linking the host's, is a link error.
    return m;
}

/// A module exposing the webapp's font as `pub const bytes: []const u8`.
///
/// Reads `path` (or emits an empty module when it is null) and writes a Zig
/// source file with the bytes hex-escaped. See the call site for why this is a
/// generated module rather than `@embedFile`.
///
/// The read is capped at 8 MiB: a font larger than that is a mistake (or a
/// mis-specified path pointing at something else), and failing loudly at build
/// time is better than a 40 MB wasm module nobody can explain.
fn makeFontModule(b: *std.Build, path: ?[]const u8) *std.Build.Module {
    const src = path orelse {
        // No font: an empty module, so the entry point's `if (bytes.len == 0)`
        // takes the glyph-free path. A legitimate build, not a failure.
        const empty = b.addWriteFiles().add("font_data.zig",
            \\// No font was embedded. Text draws as the documented glyph-free
            \\// per-byte bars. Pass -Dfont=<path> to embed one.
            \\pub const bytes: []const u8 = "";
            \\
        );
        return b.createModule(.{ .root_source_file = empty });
    };

    // Zig 0.16's Io-based fs: `cwd()` is a `Dir` and every call needs an `Io`.
    // The limit is a `std.Io.Limit`, not a byte count — `.limited(n)` is the
    // spelling, and it is what turns an oversized file into `error.StreamTooLong`
    // rather than a 40 MB wasm module nobody can explain.
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

    // Hex-escape every byte. `\xNN` is unambiguous inside a Zig string literal
    // and cannot be confused with a following character, which a raw byte could
    // (a font containing `"` or `\` would otherwise break the literal).
    //
    // `std.ArrayList(u8)` is the UNMANAGED list in Zig 0.16 — it has no `init`,
    // no `writer`, and every method takes the allocator. `std.array_list.Managed`
    // is the one with the allocator baked in, and it has `appendSlice`/`print`
    // directly, which is all this needs.
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

/// The first font in a short per-host list that exists, or null.
///
/// Deliberately a small, ordered list rather than a filesystem search: the result
/// is baked into the artifact, so it should be predictable and reviewable. Every
/// entry is a plain `.ttf`/`.otf` — never a `.ttc`, which `stbtt_InitFont` cannot
/// load (see `glyphs.Font.loadDefault`).
///
/// A null result is not an error. It means the webapp is built without a font,
/// text draws as the documented glyph-free per-byte bars, and the module is
/// ~340 KB smaller — which is a legitimate configuration, not a failure.
fn detectFont() ?[]const u8 {
    const candidates = [_][]const u8{
        // Linux. DejaVu Sans Mono is the face `linux/text.zig` already prefers,
        // and it is under a permissive licence.
        "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
        "/usr/share/fonts/dejavu/DejaVuSansMono.ttf",
        // macOS. NOT Menlo.ttc — a collection, which stb cannot load.
        "/System/Library/Fonts/SFNSMono.ttf",
        "/System/Library/Fonts/Monaco.ttf",
        // A vendored font, if someone drops one in. Checked last so a host font
        // wins, but present so a repo can pin a face without a build flag.
        "web/assets/font.ttf",
    };
    for (candidates) |path| {
        if (fileExists(path)) return path;
    }
    return null;
}

/// True when `path` names a readable file.
///
/// `std.fs` is available to the BUILD script — it runs on the host, not on the
/// target — which is why this is fine here and forbidden in `src/web/**` (rule
/// R8). Relative paths resolve against the build root, which is what makes the
/// `web/assets/font.ttf` candidate work.
///
/// Zig 0.16's Io-based fs: `cwd()` is a `Dir` and every call needs an `Io`, the
/// same shape `core/text_portable.zig` uses. A single-threaded global is right
/// here because a build script is single-threaded by construction.
fn fileExists(path: []const u8) bool {
    const io = std.Io.Threaded.global_single_threaded.io();
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    f.close(io);
    return true;
}

/// Win32 + D3D11 shim TU, its include path, and the import libraries its
/// entry points live in.
///
/// The library list is not decoration; each one is a symbol the shim actually
/// calls, and dropping it is a link error rather than a runtime surprise:
///
///   d3d11           ID3D11Device / *Context / *Texture2D / *Shader, and
///                   D3D11CreateDeviceAndSwapChain
///   dxgi            the swap chain itself (IDXGISwapChain::Present,
///                   ResizeBuffers, GetBuffer) — it is NOT part of d3d11
///   d3dcompiler_47  D3DCompile. The shaders are compiled at run time from
///                   source in this TU rather than checked in as prebuilt
///                   DXBC: shipping bytecode means shipping a compiler output
///                   the build can no longer read, and `d3dcompiler_47.dll` has
///                   shipped with Windows itself since Windows 7, so it is not
///                   an extra dependency to install.
///   user32          the window, the message loop, the mouse capture
///   gdi32           pulled in by user32's windowing entry points
///   shell32         SystemParametersInfo's work-area probe
///
/// Kept in one function so `mod` and any future standalone Windows test
/// module cannot drift apart.
fn addWindowsShim(b: *std.Build, m: *std.Build.Module) void {
    m.addIncludePath(b.path("src/windows"));
    // No extra flags: shim.c defines COBJMACROS itself, before it includes
    // anything. That has to happen in the TU rather than on the command line
    // for a boring but important reason — the macro is what makes the MinGW
    // Direct3D headers emit the COM method macros (ID3D11Device_Release and
    // friends), and the file has to own that decision so the shim still
    // compiles when it is built outside this build.zig (the CI colour check
    // compiles it with plain `zig cc`).
    m.addCSourceFile(.{ .file = b.path("src/windows/shim.c") });
    m.linkSystemLibrary("d3d11", .{});
    m.linkSystemLibrary("dxgi", .{});
    m.linkSystemLibrary("d3dcompiler_47", .{});
    m.linkSystemLibrary("user32", .{});
    m.linkSystemLibrary("gdi32", .{});
    m.linkSystemLibrary("shell32", .{});
}

/// Keep the stb implementation headers identical on every Linux runner and
/// independent of the host distribution's stb package version.
fn addVendoredStbInclude(b: *std.Build, m: *std.Build.Module) void {
    m.addIncludePath(b.path("vendor/stb"));
}

/// Extra C flags a vendored stb TU needs, per target.
///
/// Both flags are wasm-only and both remove a dependency the wasm build cannot
/// satisfy, rather than changing behaviour:
///
///   - `-DSTBI_NO_STDIO=1` drops `<stdio.h>` and the `fopen`/`fread` family from
///     stb_image. The only `stbi_load` call in the tree is in
///     `linux/renderer.zig` (for the image widget's file path), which a wasm
///     build never compiles — the CPU renderer takes already-decoded pixels
///     through `Surface.putImage`. So the stdio path is dead weight there and an
///     undefined-symbol risk.
///   - `-DSTBIR_NO_SIMD=1` keeps stb_image_resize2 away from
///     `<wasm_simd128.h>`, which is a clang *resource* header rather than one
///     Zig ships, so its absence is a compile error rather than a slow path.
///     Nothing in a wasm build calls `stbir_*` either. Enabling wasm SIMD is a
///     deliberate, separately measured optimisation, not a default.
fn stbFlags(is_wasm: bool) []const []const u8 {
    return if (is_wasm) &.{ "-DSTBI_NO_STDIO=1", "-DSTBIR_NO_SIMD=1" } else &.{};
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
