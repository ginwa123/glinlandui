// The Activity: what `MainActivity.onCreate` does in the Compose sample.
// It owns the ViewModelStore, the theme and the window's frame pump, declares the screen, and lets the window's clock reach the meter.
const std = @import("std");
const glinlandui = @import("glinlandui");

const view = @import("view.zig");
const view_model = @import("view_model.zig");

pub const App = struct {
    // `ViewModelStoreOwner`: one screen, one store, one ViewModel for the life of the window.
    store: glinlandui.view_model.Store(view_model.LazyViewModel) = .{},
    // `MaterialTheme`: the Activity picks it, and the view reads it.
    theme: glinlandui.theme.Theme = glinlandui.theme.dark,
    // The clock the meter measures with: a frame time is a fact about this host, so the Activity reads it.
    io: std.Io,
    // The window's frame pump. The model decides that an animation needs another frame; only the Activity has a window to ask.
    pump: ?view_model.FramePump = null,

    // `onCreate`: the model gets the pump, so from here on it can keep an animation moving and let an idle window go quiet.
    pub fn start(self: *App) void {
        self.vm().pump = self.pump;
    }

    // `viewModel()`: the store's instance, created on first use and kept for the life of the screen.
    pub fn vm(self: *App) *view_model.LazyViewModel {
        return self.store.getOrCreate(view_model.LazyViewModel.init);
    }

    // `setContent { LazyScrollScreen() }`, as the Host's root function.
    // The window repaints after every key and pointer event, so an intent raised by the user is on screen in the next frame; an app that animates
    // itself asks the window for a frame instead, which is what `advance` does.
    pub fn content(ctx: ?*anyopaque, w: u32, h: u32) void {
        _ = w;
        _ = h;
        const self: *App = @ptrCast(@alignCast(ctx.?));
        const model = self.vm();

        const now: i64 = @intCast(std.Io.Clock.awake.now(self.io).nanoseconds);
        model.tick(now);
        model.maybeLog(now);
        // The animation advances BEFORE the tree is declared, so this frame draws the position it just moved to.
        model.advance();

        var scope = view.Scope{
            .theme = self.theme,
            .vm = model,
            .ui = model.uiState(),
        };
        view.Screen(&scope);
    }
};
