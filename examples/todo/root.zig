// The todo example as a MODULE: `@import("todo")` is the whole app — its state, its intents, its view, and its window.
// What is left here is what is genuinely this app's. The runtime it uses (the ViewModel store, the theme, the field, the list) is the engine's.
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
