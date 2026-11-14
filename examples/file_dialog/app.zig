// The Activity: it owns the ViewModelStore and the theme, declares the screen, and wires the model before the first frame.
const glinlandui = @import("glinlandui");

const view = @import("view.zig");
const view_model = @import("view_model.zig");

pub const App = struct {
    // `ViewModelStoreOwner`: one screen, one store, one ViewModel for the life of the window.
    store: glinlandui.view_model.Store(view_model.DialogViewModel) = .{},
    // `MaterialTheme`: the Activity picks it, and the view reads it.
    theme: glinlandui.theme.Theme = glinlandui.theme.dark,

    // `onCreate`: the model gets the same allocator the window and the host were built with, so a dialog's answer is freed by its owner.
    pub fn start(self: *App) void {
        self.vm().start(glinlandui.platform.allocator);
    }

    // `viewModel()`: the store's instance, created on first use and kept for the life of the screen.
    pub fn vm(self: *App) *view_model.DialogViewModel {
        return self.store.getOrCreate(view_model.DialogViewModel.init);
    }

    // `setContent { DialogScreen() }`, as the Host's root function.
    pub fn content(ctx: ?*anyopaque, w: u32, h: u32) void {
        _ = w;
        _ = h;
        const self: *App = @ptrCast(@alignCast(ctx.?));
        const model = self.vm();
        var scope = view.Scope{
            .theme = self.theme,
            .vm = model,
            .state = model.uiState(),
        };
        view.DialogScreen(&scope);
    }
};
