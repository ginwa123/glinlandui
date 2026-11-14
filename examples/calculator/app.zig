// The Activity: what `MainActivity.onCreate` does in the Compose sample.
// It owns the ViewModelStore and the theme, declares the screen, and lets the window's events reach the model.
const std = @import("std");
const glinlandui = @import("glinlandui");
const input_mod = glinlandui.components.input;

const view = @import("view.zig");
const view_model = @import("view_model.zig");

pub const App = struct {
    // `ViewModelStoreOwner`: one screen, one store, one ViewModel for the life of the window.
    store: glinlandui.view_model.Store(view_model.CalculatorViewModel) = .{},
    // `MaterialTheme`: the Activity picks it. The keypad paints from its own app-local palette, because the components stay theme-neutral.
    theme: glinlandui.theme.Theme = glinlandui.theme.dark,

    // The webapp's embedded font, read by `web/exports.zig` from `glin_web_init`: it MUST be a declaration of the App type, because `Exports(App, App.content)` can only see declarations that belong to `App` — one in the entry-point file would be invisible and the font would silently never install. Empty on native, where the backends resolve a font from the filesystem.
    pub const embedded_font: []const u8 = if (@import("builtin").cpu.arch.isWasm())
        @import("font_data").bytes
    else
        &.{};

    // `onCreate`: nothing to wire — the keypad owns no field and no timer, so the store's instance is the whole screen.
    pub fn start(self: *App) void {
        _ = self.vm();
    }

    // `viewModel()`: the store's instance, created on first use and kept for the life of the screen.
    pub fn vm(self: *App) *view_model.CalculatorViewModel {
        return self.store.getOrCreate(view_model.CalculatorViewModel.init);
    }

    // `setContent { CalculatorScreen() }`, as the Host's root function. The window repaints after every key and pointer event, and a click is dispatched BEFORE that repaint, so an intent raised by the user is on screen in the next frame.
    pub fn content(ctx: ?*anyopaque, w: u32, h: u32) void {
        _ = w;
        _ = h;
        const self: *App = @ptrCast(@alignCast(ctx.?));
        view.show(self.vm());
    }

    // Host KeyChain handler (see `dispatch.handleKey`): the mapping is the model's, so this only hands the key over and reports whether it was consumed. Escape is deliberately NOT consumed — the toolkit's own `keyToClose` contract uses it to quit the window.
    pub fn onKey(ctx: ?*anyopaque, mods: input_mod.Mods, keycode: u32) bool {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        return self.vm().onKeycode(mods, keycode);
    }

    // Called by BOTH entries once the Host exists: the native `main` calls it inline, and `web/exports.zig` calls it through `@hasDecl` because the web entry point has no `main` to run — without it the keyboard would be dead in a browser while working natively.
    pub fn onHostReady(host: *glinlandui.host.Host, app: *App) void {
        host.keys.register(App.onKey, app);
    }
};

// ---- tests ---------------------------------------------------------------------------------------------------

test "Escape is left unconsumed so the window can still close" {
    // wayland.keyToClose accepts the raw evdev code 1 and keysym 0xff1b.
    const escape_evdev: u32 = 1;
    try std.testing.expect(glinlandui.keyToClose(escape_evdev));
    var app = App{};
    // onKey routes through the KeyChain, which tracks modifiers first and then asks each handler. Escape reaches no handler.
    try std.testing.expect(!App.onKey(&app, .{}, escape_evdev));
    try std.testing.expectEqualStrings("0", app.vm().display());
}

test "onKey drives the machine through the Host KeyChain" {
    var app = App{};
    // Enter, Backspace and the arithmetic keypad are non-ASCII keycodes, so they only work via onKey — not via keyChar.
    try std.testing.expect(App.onKey(&app, .{}, input_mod.KEY_ENTER));
    try std.testing.expectEqualStrings("0", app.vm().display());

    // evdev 8 is the "7" key; type it twice through the chain.
    try std.testing.expect(App.onKey(&app, .{}, 8));
    try std.testing.expect(App.onKey(&app, .{}, 8));
    try std.testing.expectEqualStrings("77", app.vm().display());
    try std.testing.expect(App.onKey(&app, .{}, input_mod.KEY_BACKSPACE));
    try std.testing.expectEqualStrings("7", app.vm().display());

    try std.testing.expect(App.onKey(&app, .{}, view_model.KEY_KP_MULTIPLY));
    try std.testing.expect(App.onKey(&app, .{}, view_model.KEY_KP_PLUS));
    try std.testing.expect(App.onKey(&app, .{}, view_model.KEY_KP_MINUS));
    try std.testing.expect(App.onKey(&app, .{}, view_model.KEY_KP_DIVIDE));
    try std.testing.expect(App.onKey(&app, .{}, view_model.KEY_KP_ENTER));
}
