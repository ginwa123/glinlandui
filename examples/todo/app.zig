// The Activity: what `MainActivity.onCreate` does in the Compose sample.
// It owns the ViewModelStore, the field and the click contexts, declares the screen, and routes the window's events into the model.
const glinlandui = @import("glinlandui");
const input_mod = glinlandui.components.input;
const frame = glinlandui.frame;

const view = @import("view.zig");
const view_model = @import("view_model.zig");
const state_mod = @import("state.zig");

pub const App = struct {
    // `ViewModelStoreOwner`: one screen, one store, one ViewModel for the life of the window.
    store: glinlandui.view_model.Store(view_model.TodoViewModel) = .{},
    // The field the keyboard types into: its look, its intents and its draft all live in it.
    field: input_mod.Field = .{ .id = .{ .text = view.field_id } },
    // Click contexts, owned here because a callback runs AFTER the frame that declared it.
    add_ctx: view.AddCtx = undefined,
    row_ctxs: [state_mod.max_todos]view.RowCtx = undefined,

    // `onCreate`: the field takes the keyboard, and the click context points at it.
    pub fn start(self: *App) void {
        // The look and the intents are set ONCE: a frame only hands the field the model's value.
        const t = glinlandui.theme.dark;
        self.field = .{
            .id = .{ .text = view.field_id },
            .font_size = t.type_scale.body,
            .bg = t.colors.surface,
            .fg = t.colors.text,
            .sel_bg = t.colors.surface_variant,
            .sel_fg = t.colors.text,
            .caret_fg = t.colors.primary,
            .radius = glinlandui.props.Radius.all(6),
            .pad = glinlandui.props.Pad.axes(8, 10),
            .border = .{ .width = 1, .color = t.colors.divider },
            .w = .{ .clamp = .{ .min = 120, .max = 640, .grow = true } },
            .on_change = view.onDraft,
            .on_submit = view.onSubmit,
            .ctx = self.vm(),
        };
        self.add_ctx = .{ .field = &self.field };
        frame.setFocus(view.field_id);
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
            .theme = glinlandui.theme.dark,
            .vm = model,
            .field = &self.field,
            // `val state by vm.state.collectAsState()`
            .state = model.uiState(),
            .add = &self.add_ctx,
            .rows = &self.row_ctxs,
        };
        view.TodoScreen(&scope);
    }
};
