// The Activity: what `MainActivity.onCreate` does in the Compose sample.
// It owns the ViewModelStore and the theme, declares the screen, and lets the window's events reach the model.
const glinlandui = @import("glinlandui");
const frame = glinlandui.frame;

const view = @import("view.zig");
const view_model = @import("view_model.zig");

pub const App = struct {
    // `ViewModelStoreOwner`: one screen, one store, one ViewModel for the life of the window.
    store: glinlandui.view_model.Store(view_model.TodoViewModel) = .{},
    // `MaterialTheme`: the Activity picks it, and the model and the view both read it.
    theme: glinlandui.theme.Theme = glinlandui.theme.dark,

    // `onCreate`: the model starts its screen — the field takes the keyboard.
    pub fn start(self: *App) void {
        self.vm().start(self.theme);
        frame.setFocus(view_model.field_id);
    }

    // `viewModel()`: the store's instance, created on first use and kept for the life of the screen.
    pub fn vm(self: *App) *view_model.TodoViewModel {
        return self.store.getOrCreate(view_model.TodoViewModel.init);
    }

    // `setContent { MaterialTheme { TodoScreen() } }`, as the Host's root function.
    // The window repaints after every key and pointer event, and a click is dispatched BEFORE that repaint, so an
    // intent raised by the user is on screen in the next frame. An app that changes state from a timer asks the
    // window for a frame itself.
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
        view.TodoScreen(&scope);
    }
};
