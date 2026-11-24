const std = @import("std");
const glinlandui = @import("glinlandui");
const calculator = @import("calculator");

const App = calculator.app.App;
const web = glinlandui.platform.web_exports.Exports(App, App.content);

comptime {
    if (@import("builtin").cpu.arch.isWasm()) {
        _ = glinlandui.web.compatImpl();
    }
}

pub const std_options: std.Options = .{ .logFn = web.logFn };
