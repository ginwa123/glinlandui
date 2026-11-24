const std = @import("std");
const glinlandui = @import("glinlandui");
const demo = @import("demo");

const App = demo.App;
const web = glinlandui.platform.web_exports.Exports(App, App.root);

comptime {
    if (@import("builtin").cpu.arch.isWasm()) {
        _ = glinlandui.web.compatImpl();
    }
}

pub const std_options: std.Options = .{ .logFn = web.logFn };
