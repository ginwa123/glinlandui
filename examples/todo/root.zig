// The todo example as a MODULE, not a single file: `@import("todo")` is the whole app.
// The layering is the point, and it is the same layering a Compose app has:
//   state.zig        the data class       — what the screen shows
//   view_model.zig   TodoViewModel        — the only writer of the state
//   view.zig         @Composable screen   — a function of the state
//   app.zig          Activity             — store, composition, event routing
//   main.zig         entry point          — window and `setContent`
// The runtime those files use — StateFlow, the composition, the ViewModel store, the theme — is the engine's.
pub const app = @import("app.zig");
pub const view = @import("view.zig");
pub const view_model = @import("view_model.zig");
pub const state = @import("state.zig");
pub const theme = @import("theme.zig");

// Every file's own tests, so `zig build test-todo` runs the whole example.
test {
    _ = @import("state.zig");
    _ = @import("view_model.zig");
    _ = @import("theme.zig");
    _ = @import("view.zig");
    _ = @import("app.zig");
}
