// The browser entry point for this example: the exported ABI, the freestanding C runtime and the log sink.
// `main.zig` stays the native entry. A wasm artifact has `entry = .disabled`, so nothing calls `main`: this file only has to force the `export fn` surface (and the app type it is bound to) into the link.
const std = @import("std");
const glinlandui = @import("glinlandui");
const example = @import("lazy_scroll");

const App = example.app.App;

/// The page's ABI, bound to THIS application: on wasm this instantiates `src/web/exports.zig` with this app's type and root callback, which is what puts every `export fn` in the module.
const web = glinlandui.platform.web_exports.Exports(App, App.content);

// The freestanding C runtime, reached THROUGH the library: a relative `../src/web/compat_impl.zig` would escape this module's root directory. Guarded by `isWasm` because native has a real libc, and defining these again would be a duplicate symbol.
comptime {
    if (@import("builtin").cpu.arch.isWasm()) {
        _ = glinlandui.web.compatImpl();
    }
}

/// The page's `std.log` sink: a freestanding wasm module has nowhere to print, so the page reads the counters instead.
pub const std_options: std.Options = .{ .logFn = web.logFn };
