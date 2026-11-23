//! The browser's exported ABI — the `export fn glin_web_*` surface `src/web/shim.h` declares.
const std = @import("std");
const builtin = @import("builtin");
const window_mod = @import("window.zig");
const input_mod = @import("input.zig");
const adapter = @import("adapter.zig");
const glyphs = @import("../core/glyphs.zig");
const gpu = @import("gpu.zig");
const image_store = @import("../core/image_store.zig");
const renderer = @import("renderer.zig");
const route = @import("../core/route.zig");

/// The face the page draws with, compiled in by `build.zig`'s `-Dfont` option. It lives in the LIBRARY, not in an application: a browser has no font paths, and a toolkit that made every app carry a typeface would be making every app know how it is being hosted.
const embedded_font: []const u8 = @import("font_data").bytes;

/// The application this module serves, as a comptime parameter. No assets, for an app whose page needs none.
pub fn Exports(
    comptime App: type,
    comptime root_fn: *const fn (?*anyopaque, u32, u32) void,
) type {
    return ExportsWithAssets(App, root_fn, &[_]image_store.Source{});
}

/// The same ABI, plus the images this app's BROWSER build carries: a page has no filesystem, so `build.zig` emits an `asset_data` module and the app's browser entry passes the list here — the engine decodes them, and the app itself is untouched.
pub fn ExportsWithAssets(
    comptime App: type,
    comptime root_fn: *const fn (?*anyopaque, u32, u32) void,
    comptime assets: anytype,
) type {
    return struct {
        /// The longest `KeyboardEvent.code` is well under this ("NumpadSubtract" is 14, "LaunchApplication2" is 17); 32 is slack, and the page writes event.
        const key_scratch_len: usize = 32;

        // ---- process-wide state ---- A page has exactly one UI.

        var g_app: ?*App = null;
        var g_host: ?@import("../core/host.zig").Host = null;
        var g_window: ?window_mod.Window = null;
        var g_key_scratch: []u8 = &.{};
        var g_route_scratch: []u8 = &.{};

        /// Log counters.
        pub var log_errors: u32 = 0;
        pub var log_warnings: u32 = 0;
        pub var log_infos: u32 = 0;

        /// The application's `std.log` sink.
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

        // Lifecycle

        /// See `src/web/shim.h`.
        export fn glin_web_init(backing_w: u32, backing_h: u32, min_w: u32, min_h: u32) i32 {
            if (g_window != null) return 0;
            const alloc = std.heap.wasm_allocator;

            // A window starts with an empty address; the page then says where the app really is (`glin_web_location`).
            route.reset();

            // The app is allocated here rather than declared as a global because its type is only known at comptime.
            const app_ptr = alloc.create(App) catch return 0;
            app_ptr.* = .{};
            // `onCreate`: the same call every native `main.zig` makes BEFORE the Host exists, so a browser app starts started. Without it a screen whose `start` seeds the model (todo's focus, catalog's fields, lazy-scroll's pump) would draw an unstarted app.
            if (@hasDecl(App, "start")) App.start(app_ptr);

            g_host = @import("../core/host.zig").Host.init(alloc, app_ptr, root_fn) catch return 0;
            const host = if (g_host) |*h| h else return 0;
            g_app = app_ptr;

            // Let the application wire anything that depends on the Host — the calculator registers its key chain here, and without this call its keyboard would be.
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
            // Match the Host to the canvas, so the FIRST frame lays out at the real size; the Host's box is content points.
            host.win_w = @import("../core/frame.zig").contentWidth(win.state.win_w);
            host.win_h = @import("../core/frame.zig").contentHeight(win.state.win_h);
            g_window = win;

            const scratch = alloc.alloc(u8, key_scratch_len) catch return 0;
            scratch[0] = 0;
            g_key_scratch = scratch;

            const route_scratch = alloc.alloc(u8, route.max_path) catch return 0;
            route_scratch[0] = 0;
            g_route_scratch = route_scratch;

            // The images this build carries, registered before the first frame: the renderer looks them up by the same path the app declared.
            image_store.register(assets);

            // The engine's own typeface, installed before the first frame, so text is glyphs from the very first draw. A page that wants a different face calls `glin_web_font`.
            if (embedded_font.len > 0) installEmbeddedFont(embedded_font);

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

        // Frame

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
            // An OFFSET into wasm linear memory, not a JS pointer.
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

        /// The low 32 bits of the frame's FNV-1a hash.
        export fn glin_web_frame_hash() u32 {
            const w = window() orelse return 0;
            return @truncate(w.frameHash());
        }

        export fn glin_web_frames() u32 {
            const w = window() orelse return 0;
            return w.frames;
        }

        /// The CSS `cursor` keyword the last frame resolved, as an OFFSET into wasm memory — the page decodes those bytes and assigns them to `canvas.style.cursor` verbatim, which is what keeps the choice in Zig.
        export fn glin_web_cursor_ptr() u32 {
            const w = window() orelse return 0;
            return offsetOf(w.cursorCss());
        }

        /// Its length in bytes, so the page never assumes a terminating NUL.
        export fn glin_web_cursor_len() u32 {
            const w = window() orelse return 0;
            return @intCast(w.cursorCss().len);
        }

        /// Moves only when that keyword changed, so a hover over one target costs the page one integer read per frame instead of a DOM write.
        export fn glin_web_cursor_version() u32 {
            const w = window() orelse return 0;
            return w.cursorVersion();
        }

        // GPU

        /// The page tells the toolkit which backend it created: 0 = none (the CPU rasterizer), 1 = WebGPU, 2 = WebGL2.
        export fn glin_web_gpu_ready(kind: u32) void {
            const w = window() orelse return;
            w.setBackendKind(kind);
        }

        /// What the last `glin_web_gpu_ready` said. 0 means the CPU rasterizer is drawing, which is a supported browser, not a failure.
        export fn glin_web_gpu_kind() u32 {
            return renderer.backendKind();
        }

        /// An OFFSET into wasm memory (0 when the buffer is empty), like every other pointer this ABI exposes.
        export fn glin_web_gpu_verts_ptr() u32 {
            return offsetOf(gpu.vertices());
        }

        /// The vertex buffer's length in BYTES: `len / glin_web_gpu_vertex_stride()` is the vertex count the segments index into.
        export fn glin_web_gpu_verts_len() u32 {
            return @intCast(gpu.vertices().len);
        }

        export fn glin_web_gpu_segs_ptr() u32 {
            return offsetOf(gpu.segments());
        }

        export fn glin_web_gpu_segs_count() u32 {
            return gpu.segmentCount();
        }

        /// Bytes per vertex (17 floats, 68) and per segment (9 int32, 36), so the page never hardcodes a layout.
        export fn glin_web_gpu_vertex_stride() u32 {
            return gpu.vertexStride();
        }

        export fn glin_web_gpu_segment_stride() u32 {
            return gpu.segmentStride();
        }

        /// The 8-bit glyph atlas, and the version that changes only when its CONTENTS changed, so the page re-uploads on demand.
        export fn glin_web_gpu_atlas_ptr() u32 {
            return offsetOf(gpu.atlasBytes());
        }

        export fn glin_web_gpu_atlas_len() u32 {
            return @intCast(gpu.atlasBytes().len);
        }

        export fn glin_web_gpu_atlas_version() u32 {
            return gpu.atlasVersion();
        }

        export fn glin_web_gpu_atlas_width() u32 {
            return gpu.atlas_w;
        }

        export fn glin_web_gpu_atlas_height() u32 {
            return gpu.atlas_h;
        }

        /// The frame's target size in DEVICE pixels: the canvas backing store the geometry is expressed in.
        export fn glin_web_gpu_width() u32 {
            return gpu.width();
        }

        export fn glin_web_gpu_height() u32 {
            return gpu.height();
        }

        /// How many image textures this frame's segments can name: the page keeps one GPU texture per id, uploads it when the version changes, and a segment of kind 2 names its image in `texture_id`.
        export fn glin_web_gpu_image_count() u32 {
            return gpu.imageCount();
        }

        /// Per-image accessors. `index` is 0..count-1; a bad index answers 0 rather than trapping.
        export fn glin_web_gpu_image_id(index: u32) u32 {
            const t = gpu.imageAt(index) orelse return 0;
            return t.id;
        }

        export fn glin_web_gpu_image_version(index: u32) u32 {
            const t = gpu.imageAt(index) orelse return 0;
            return t.version;
        }

        export fn glin_web_gpu_image_width(index: u32) u32 {
            const t = gpu.imageAt(index) orelse return 0;
            return t.width;
        }

        export fn glin_web_gpu_image_height(index: u32) u32 {
            const t = gpu.imageAt(index) orelse return 0;
            return t.height;
        }

        /// The decoded RGBA8 bytes, as an offset into wasm memory (`width * height * 4` of them).
        export fn glin_web_gpu_image_ptr(index: u32) u32 {
            const t = gpu.imageAt(index) orelse return 0;
            return offsetOf(t.pixels);
        }

        export fn glin_web_gpu_image_len(index: u32) u32 {
            const t = gpu.imageAt(index) orelse return 0;
            return @intCast(t.pixels.len);
        }

        /// The clear colour as packed RGBA8, low byte red: one integer rather than four floats crossing the boundary per frame.
        export fn glin_web_gpu_clear_rgba() u32 {
            const c = gpu.clearColor();
            const r: u32 = @intFromFloat(@round(@min(@max(c[0], 0), 1) * 255));
            const g: u32 = @intFromFloat(@round(@min(@max(c[1], 0), 1) * 255));
            const b: u32 = @intFromFloat(@round(@min(@max(c[2], 0), 1) * 255));
            const a: u32 = @intFromFloat(@round(@min(@max(c[3], 0), 1) * 255));
            return r | (g << 8) | (b << 16) | (a << 24);
        }

        fn offsetOf(bytes: []const u8) u32 {
            if (bytes.len == 0) return 0;
            return @intCast(@intFromPtr(bytes.ptr));
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

        // Input

        export fn glin_web_pointer(kind: i32, button: i32, x: f64, y: f64) void {
            const w = window() orelse return;
            const fx: f32 = @floatCast(x);
            const fy: f32 = @floatCast(y);
            // 3 is `pointercancel`: the OS took the gesture over, so the press has to be released rather than left latched.
            if (kind == 3) {
                w.cancelPointer(fx, fy);
                return;
            }
            const k: u8 = switch (kind) {
                0 => input_mod.MOTION,
                1 => input_mod.DOWN,
                2 => input_mod.UP,
                // An unknown kind is treated as motion rather than as a press: inventing a press would click something the user never touched.
                else => input_mod.MOTION,
            };
            w.pointer(k, button, fx, fy);
        }

        export fn glin_web_wheel(dx: f64, dy: f64, mode: i32) void {
            const w = window() orelse return;
            w.wheel(@floatCast(dx), @floatCast(dy), adapter.WheelDeltaMode.fromInt(mode));
        }

        /// `code` points into a wasm-owned buffer (typically the scratch block from `glin_web_key_scratch`) for `code_len` bytes, and is NOT NUL-terminated.
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

        // Memory handed in, and the font

        export fn glin_web_alloc(len: u32) u32 {
            if (len == 0) return 0;
            const buf = std.heap.wasm_allocator.alloc(u8, len) catch return 0;
            return @intCast(@intFromPtr(buf.ptr));
        }

        /// `ptr` / `len` must be the pair `glin_web_alloc` returned.
        export fn glin_web_free(ptr: u32, len: u32) void {
            if (ptr == 0 or len == 0) return;
            const p: [*]u8 = @ptrFromInt(ptr);
            std.heap.wasm_allocator.free(p[0..len]);
        }

        /// Installs a font the page fetched.
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
        export fn glin_web_font_error() u32 {
            return font_error;
        }

        var font_error: u32 = 0;

        /// Install font bytes the MODULE already owns — the embedded font, which lives in the data section for the lifetime of the instance.
        pub fn installEmbeddedFont(bytes: []const u8) void {
            const w = window() orelse {
                font_error = 4;
                return;
            };
            // The bytes are read-only, and `Font.fromBytes` hands the rasterizer pointers into them.
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

        // Routing: the address the app is showing, and the page's way of saying where it really is.

        /// The route's bytes, as an offset into wasm memory (0 when the app has no address yet).
        export fn glin_web_route_ptr() u32 {
            return offsetOf(route.address());
        }

        export fn glin_web_route_len() u32 {
            return @intCast(route.address().len);
        }

        /// Changes on every navigation, so a page can tell an address it has already mirrored from a new one.
        export fn glin_web_route_generation() u32 {
            return route.generation();
        }

        /// A block the page may write an address into, so adopting one costs no allocation and cannot grow the heap.
        export fn glin_web_route_scratch() u32 {
            if (g_route_scratch.len == 0) return 0;
            return @intCast(@intFromPtr(g_route_scratch.ptr));
        }

        export fn glin_web_route_scratch_len() u32 {
            return @intCast(g_route_scratch.len);
        }

        /// The page's address (a deep link, Back, an edited URL), returning the generation the page records as mirrored.
        export fn glin_web_location(path: [*]const u8, path_len: u32) u32 {
            // A zero length is an ADDRESS — the root — not "nothing to say": Back to the bare URL has to arrive here too.
            route.adopt(if (path_len == 0) "" else path[0..path_len]);
            return route.generation();
        }
    };
}
