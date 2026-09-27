//! The browser's exported ABI — the `export fn glin_web_*` surface `src/web/shim.h`
//! declares.
//!
//! ## Why this is a backend file and not an entry point
//!
//! This used to live in `src/web_main.zig`, a per-application file whose only job
//! was to forward the ABI to one app. That was wrong, and it contradicted the
//! library's whole purpose: an application should be ONE source file that runs on
//! Linux, macOS and the browser, and the platform difference should live in the
//! backend.
//!
//! So the forwarding is here, in `src/web/`, next to `window.zig` — and it is
//! GENERIC over the application. `src/main.zig` and `examples/calculator.zig` each
//! keep a single `pub fn main` that works everywhere, and each binds this surface
//! to its own app with one line:
//!
//!     comptime { _ = glinlandui.platform.web_exports.bind(App, App.root); }
//!
//! ## Why the binding is a comptime call rather than a parameter
//!
//! `export fn` cannot take a comptime parameter — the ABI is fixed by
//! `src/web/shim.h`, and the page calls `glin_web_init(w, h, min_w, min_h)` with
//! no room for an app pointer. So the app has to be reachable from module scope,
//! and the only way to make that generic is for the application to hand its type
//! and root callback over at comptime.
//!
//! `bind` therefore does two things: it records the app type in a comptime
//! variable, and it forces this module to be ANALYSED. That second part is
//! load-bearing — Zig analyses lazily from the module root, so an `export fn` in a
//! file nothing references is never compiled and the linker has nothing to keep.
//! That is exactly the bug that produced a black canvas with a module exporting
//! `memory` and nothing else.
//!
//! ## One app per module
//!
//! The state below is module-scope, so a module can host exactly one application.
//! That is correct: a wasm module is one program, and the page loads one of them.
//! Two apps in one module would need two sets of exports, which the ABI does not
//! have and should not grow.
const std = @import("std");
const builtin = @import("builtin");
const window_mod = @import("window.zig");
const input_mod = @import("input.zig");
const adapter = @import("adapter.zig");
const glyphs = @import("../core/glyphs.zig");

/// The application this module serves, as a comptime parameter.
///
/// ## Why this is a generic function rather than a mutable global
///
/// The first version of this file tried `var App: type = void` and assigned it
/// in `bind`. That cannot work: Zig will not store a `type` in a mutable global
/// ("variable of type 'type' must be const or comptime"), and `export fn` cannot
/// take a comptime parameter because the ABI is fixed by `src/web/shim.h` — the
/// page calls `glin_web_init(w, h, min_w, min_h)` with no room for an app pointer.
///
/// So the app type is a COMPTIME PARAMETER of a generic struct, and the
/// application instantiates it once:
///
///     comptime { _ = glinlandui.platform.web_exports(App, App.root); }
///
/// Verified by spike before this was written: a generic struct CAN hold
/// `export fn`s, and a comptime `type` parameter IS usable inside them. That is
/// the whole reason this shape works where the global did not.
///
/// ## One app per module
///
/// The state below is module-scope, so a module hosts exactly one application.
/// That is correct: a wasm module is one program, and the page loads one of them.
pub fn Exports(
    comptime App: type,
    comptime root_fn: *const fn (?*anyopaque, u32, u32) void,
) type {
    return struct {
        /// The longest `KeyboardEvent.code` is well under this ("NumpadSubtract"
        /// is 14, "LaunchApplication2" is 17); 32 is slack, and the page writes
        /// event codes into this buffer instead of allocating per keystroke.
        const key_scratch_len: usize = 32;

        // ---- process-wide state ----
        //
        // A page has exactly one UI. Everything below is a global for that
        // reason, and because the alternative — threading a context through the
        // exported ABI — would put a pointer in the interface that JS would have
        // to carry around for no gain.

        var g_app: ?*App = null;
        var g_host: ?@import("../core/host.zig").Host = null;
        var g_window: ?window_mod.Window = null;
        var g_key_scratch: []u8 = &.{};

        /// Log counters. A browser has nowhere to print — the default `logFn`
        /// cannot even compile for a freestanding target — so `std_options` in
        /// the application's root routes messages here and the page reads the
        /// numbers. That turns "we cannot report" into "the page can observe",
        /// and it is what `web/smoke.mjs` asserts.
        pub var log_errors: u32 = 0;
        pub var log_warnings: u32 = 0;
        pub var log_infos: u32 = 0;

        /// The application's `std.log` sink. The application's root must set
        /// `std_options.logFn` to this — see `src/main.zig` for the one line.
        pub fn logFn(
            comptime level: std.log.Level,
            comptime scope: @TypeOf(.enum_literal),
            comptime format: []const u8,
            args: anytype,
        ) void {
            _ = scope;
            _ = format;
            _ = args;
            switch (level) {
                .err => log_errors += 1,
                .warn => log_warnings += 1,
                .info, .debug => log_infos += 1,
            }
        }

        fn window() ?*window_mod.Window {
            if (g_window) |*w| return w;
            return null;
        }

        // -------------------------------------------------------------------
        // Lifecycle
        // -------------------------------------------------------------------

        /// See `src/web/shim.h`. Returns 1 on success, 0 if a window already
        /// exists or an allocation failed.
        export fn glin_web_init(backing_w: u32, backing_h: u32, min_w: u32, min_h: u32) i32 {
            if (g_window != null) return 0;
            const alloc = std.heap.wasm_allocator;

            // The app is allocated here rather than declared as a global because
            // its type is only known at comptime. One allocation, for the
            // lifetime of the module — the same ownership the native entry points
            // have, where the app is a stack local that outlives `run()`.
            const app_ptr = alloc.create(App) catch return 0;
            app_ptr.* = .{};

            g_host = @import("../core/host.zig").Host.init(alloc, app_ptr, root_fn) catch return 0;
            const host = if (g_host) |*h| h else return 0;
            g_app = app_ptr;

            // Let the application wire anything that depends on the Host — the
            // calculator registers its key chain here, and without this call its
            // keyboard would be dead in a browser while working natively.
            //
            // This is the ONE thing the ABI cannot infer from the app type: the
            // native entry points do it inline in their `main`, and the web entry
            // point has no `main` to run. So the application supplies a hook.
            if (@hasDecl(App, "onHostReady")) App.onHostReady(host, app_ptr);

            var win = window_mod.Window.init(alloc, .{
                .app_id = "glinlandui",
                .title = "glinlandui",
                .width = if (backing_w == 0) 480 else backing_w,
                .height = if (backing_h == 0) 360 else backing_h,
                .min_width = if (min_w == 0) 1 else min_w,
                .min_height = if (min_h == 0) 1 else min_h,
            });
            win.delegate = host.delegate();
            // Match the Host's idea of the window to the canvas from the start,
            // so the FIRST frame lays out at the real size rather than at
            // `host.zig`'s 720x480 default and then resizing.
            // `dispatch.pointerEvent` also uses these for its in-bounds test, so
            // a stale value would mis-hit the very first click.
            host.win_w = win.state.win_w;
            host.win_h = win.state.win_h;
            g_window = win;

            const scratch = alloc.alloc(u8, key_scratch_len) catch return 0;
            scratch[0] = 0;
            g_key_scratch = scratch;

            // Install the application's embedded font, if it has one. This is
            // what makes text GLYPHS in a browser rather than the documented
            // glyph-free bars, and it must happen before the first frame.
            //
            // It MUST come after `g_window = win`: `installEmbeddedFont` goes
            // through `window()`, which returns null until the global is set. An
            // earlier version called it before, so it silently recorded "no
            // window" and the browser drew bars — with `log_warnings` still 0,
            // because the failure was recorded in `font_error` rather than
            // logged. That is why `glin_web_font_error` exists.
            //
            // Read from the app rather than passed in, because the bytes are a
            // comptime constant the application owns (`@import("font_data")`),
            // and the ABI has no room for them. The declaration lives on the APP
            // TYPE, not on the entry-point file: `App` here is `demo_app.App` /
            // `calculator.App`, and a declaration in `main.zig` would be
            // invisible to this generic struct.
            if (@hasDecl(App, "embedded_font")) {
                const bytes = App.embedded_font;
                if (bytes.len > 0) installEmbeddedFont(bytes);
            }

            return 1;
        }

        /// See `src/web/shim.h`. Arms the loop and returns — it never blocks.
        export fn glin_web_run() i32 {
            const w = window() orelse return 0;
            w.run() catch return 0;
            return 1;
        }

        export fn glin_web_shutdown() void {
            const w = window() orelse return;
            w.shutdown();
        }

        // -------------------------------------------------------------------
        // Frame
        // -------------------------------------------------------------------

        export fn glin_web_needs_frame() i32 {
            const w = window() orelse return 0;
            return if (w.needsFrame()) 1 else 0;
        }

        export fn glin_web_frame() void {
            const w = window() orelse return;
            w.frame();
        }

        export fn glin_web_surface_ptr() u32 {
            const w = window() orelse return 0;
            const info = w.surfaceInfo() orelse return 0;
            // An OFFSET into wasm linear memory, not a JS pointer. usize is
            // 32-bit on wasm32, so this is lossless.
            return @intCast(@intFromPtr(info.ptr));
        }

        export fn glin_web_surface_len() u32 {
            const w = window() orelse return 0;
            const info = w.surfaceInfo() orelse return 0;
            return @intCast(info.len);
        }

        export fn glin_web_surface_width() u32 {
            const w = window() orelse return 0;
            const info = w.surfaceInfo() orelse return 0;
            return info.width;
        }

        export fn glin_web_surface_height() u32 {
            const w = window() orelse return 0;
            const info = w.surfaceInfo() orelse return 0;
            return info.height;
        }

        export fn glin_web_painted_pixels() u32 {
            const w = window() orelse return 0;
            return @intCast(w.paintedPixels());
        }

        /// The low 32 bits of the frame's FNV-1a hash. Truncated deliberately:
        /// the assertion it serves is "the frame is not a flat fill", for which
        /// 32 bits are plenty, and a `u64` return would arrive in JavaScript as a
        /// `BigInt` and make every caller handle a second numeric type.
        export fn glin_web_frame_hash() u32 {
            const w = window() orelse return 0;
            return @truncate(w.frameHash());
        }

        export fn glin_web_frames() u32 {
            const w = window() orelse return 0;
            return w.frames;
        }

        export fn glin_web_log_errors() u32 {
            return log_errors;
        }

        export fn glin_web_log_warnings() u32 {
            return log_warnings;
        }

        export fn glin_web_log_infos() u32 {
            return log_infos;
        }

        // -------------------------------------------------------------------
        // Input
        // -------------------------------------------------------------------

        export fn glin_web_pointer(kind: i32, button: i32, x: f64, y: f64) void {
            const w = window() orelse return;
            const fx: f32 = @floatCast(x);
            const fy: f32 = @floatCast(y);
            // 3 is `pointercancel`: the OS took the gesture over, so the press
            // has to be released rather than left latched.
            if (kind == 3) {
                w.cancelPointer(fx, fy);
                return;
            }
            const k: u8 = switch (kind) {
                0 => input_mod.MOTION,
                1 => input_mod.DOWN,
                2 => input_mod.UP,
                // An unknown kind is treated as motion rather than as a press:
                // inventing a press would click something the user never touched.
                else => input_mod.MOTION,
            };
            w.pointer(k, button, fx, fy);
        }

        export fn glin_web_wheel(dx: f64, dy: f64, mode: i32) void {
            const w = window() orelse return;
            w.wheel(@floatCast(dx), @floatCast(dy), adapter.WheelDeltaMode.fromInt(mode));
        }

        /// `code` points into a wasm-owned buffer (typically the scratch block
        /// from `glin_web_key_scratch`) for `code_len` bytes, and is NOT
        /// NUL-terminated.
        ///
        /// Returns 1 if the toolkit CONSUMED the key, so the page knows whether
        /// to `preventDefault`. The decision is the app's (`components.input`'s
        /// text fields want Tab, Space and the arrows), and it is made in Zig.
        export fn glin_web_key(code: [*]const u8, code_len: u32, pressed: i32) i32 {
            const w = window() orelse return 0;
            if (code_len == 0) return 0;
            return if (w.key(code[0..code_len], pressed != 0)) 1 else 0;
        }

        export fn glin_web_resize(backing_w: u32, backing_h: u32) void {
            const w = window() orelse return;
            w.resize(backing_w, backing_h);
        }

        export fn glin_web_scale(scale: f32) void {
            const w = window() orelse return;
            w.setScale(scale);
        }

        export fn glin_web_blur() void {
            const w = window() orelse return;
            w.blur();
        }

        // -------------------------------------------------------------------
        // Memory handed in, and the font
        // -------------------------------------------------------------------

        export fn glin_web_alloc(len: u32) u32 {
            if (len == 0) return 0;
            const buf = std.heap.wasm_allocator.alloc(u8, len) catch return 0;
            return @intCast(@intFromPtr(buf.ptr));
        }

        /// `ptr` / `len` must be the pair `glin_web_alloc` returned. The free
        /// uses alignment 1, matching the `alloc(u8, len)` above, which is what
        /// makes the round trip correct.
        export fn glin_web_free(ptr: u32, len: u32) void {
            if (ptr == 0 or len == 0) return;
            const p: [*]u8 = @ptrFromInt(ptr);
            std.heap.wasm_allocator.free(p[0..len]);
        }

        /// Installs a font the page fetched. OWNERSHIP OF THE BLOCK PASSES TO
        /// WASM and it is never freed: the installed font must outlive every
        /// glyph lookup, and `glyphs.Font.fromBytes` hands the rasterizer
        /// pointers into these bytes. So the page must NOT call `glin_web_free`
        /// on a block it passed here.
        ///
        /// Returns 0 when the bytes are not a loadable font, in which case the
        /// toolkit keeps drawing glyph-free text rather than failing — see
        /// `glyphs.sfntSignatureRecognized` for why a 404'd HTML page must be
        /// rejected BEFORE stb sees it.
        export fn glin_web_font(ptr: u32, len: u32) i32 {
            const w = window() orelse {
                font_error = 4;
                return 0;
            };
            if (ptr == 0 or len == 0) {
                font_error = 1;
                return 0;
            }
            const p: [*]u8 = @ptrFromInt(ptr);
            const ok = w.installFontBytes(p[0..len]);
            font_error = w.font_error;
            return if (ok) 1 else 0;
        }

        /// WHY the last `glin_web_font` failed, as a number.
        ///
        /// `glin_web_font` returns a bare 0/1, which cannot distinguish "the
        /// bytes were empty" from "the signature was not an sfnt" from "stb
        /// refused the header". That ambiguity cost real time: a browser showing
        /// bars looked identical whether the font was missing, rejected, or
        /// unparseable, and the only way to tell was to guess and re-run.
        ///
        /// So the failure is recorded here and the page can read it:
        ///
        ///   0 = no failure recorded
        ///   1 = empty input
        ///   2 = signature not recognised (not an sfnt; a `.ttc`, or HTML)
        ///   3 = stbtt_InitFont refused the header
        ///   4 = no window (glin_web_init has not run)
        export fn glin_web_font_error() u32 {
            return font_error;
        }

        var font_error: u32 = 0;

        /// Install font bytes the MODULE already owns — the embedded font, which
        /// lives in the data section for the lifetime of the instance. Separate
        /// from `glin_web_font` because the ownership differs: this one must
        /// never be freed, and the page never sees it.
        pub fn installEmbeddedFont(bytes: []const u8) void {
            const w = window() orelse {
                font_error = 4;
                return;
            };
            // The bytes are read-only, and `Font.fromBytes` hands the rasterizer
            // pointers into them. The const is cast away here and NOWHERE writes
            // through it; `Font.deinit` must never run on it, which is why the
            // web backend never frees its font.
            const mutable: []u8 = @constCast(bytes);
            if (!w.installFontBytes(mutable)) {
                log_warnings += 1;
                font_error = 3;
            }
        }

        export fn glin_web_key_scratch() u32 {
            if (g_key_scratch.len == 0) return 0;
            return @intCast(@intFromPtr(g_key_scratch.ptr));
        }

        export fn glin_web_key_scratch_len() u32 {
            return @intCast(g_key_scratch.len);
        }
    };
}
