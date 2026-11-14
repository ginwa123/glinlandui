// The calculator example as a MODULE: `@import("calculator")` is the whole app — its state, its intents, its view, and its window.
pub const app = @import("app.zig");
pub const view = @import("view.zig");
pub const view_model = @import("view_model.zig");
pub const state = @import("state.zig");

// Every file's own tests, collected without adding an anonymous one of its own, so `tests.lock` counts real tests.
comptime {
    _ = @import("state.zig");
    _ = @import("view_model.zig");
    _ = @import("view.zig");
    _ = @import("app.zig");
}
