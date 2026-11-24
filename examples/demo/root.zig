pub const demo_app = @import("demo_app");
pub const App = demo_app.App;

test "glinlandui surface resolves" {
    _ = @import("glinlandui").Window;
    _ = @import("glinlandui").WindowConfig;
    _ = @import("glinlandui").render;
    _ = @import("glinlandui").text;
}
