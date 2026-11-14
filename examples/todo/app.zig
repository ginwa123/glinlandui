// The Activity: what `MainActivity.onCreate` does in the Compose sample.
// It owns the ViewModelStore, the field and the click contexts, declares the screen, and routes the window's events into the model.
const glinlandui = @import("glinlandui");
const input_mod = glinlandui.components.input;
const frame = glinlandui.frame;
const text_editor = glinlandui.text_editor;

const view = @import("view.zig");
const view_model = @import("view_model.zig");
const state_mod = @import("state.zig");

pub const App = struct {
    // `ViewModelStoreOwner`: one screen, one store, one ViewModel for the life of the window.
    store: glinlandui.view_model.Store(view_model.TodoViewModel) = .{},
    // The field the keyboard types into. It owns its buffer, so there is nothing to bind here.
    field: input_mod.FieldCtx = .{ .id = view.field_id },
    // Click contexts, owned here because a callback runs AFTER the frame that declared it.
    add_ctx: view.AddCtx = undefined,
    row_ctxs: [state_mod.max_todos]view.RowCtx = undefined,

    // `onCreate`: the field takes the keyboard, and the contexts point at the one ViewModel.
    pub fn start(self: *App) void {
        self.add_ctx = .{ .vm = self.vm(), .field = &self.field };
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

    // `KeyboardActions(onDone = { vm.add(field.text()) })`: the draft goes up as an argument, and the field clears only if it was taken.
    pub fn submit(self: *App) void {
        if (self.vm().add(self.field.editor.text())) self.field.editor.setText("");
    }

    // One key event, and only for the field that owns the keyboard: clicking anywhere else takes it away.
    pub fn onKey(ctx: ?*anyopaque, mods: input_mod.Mods, keycode: u32) bool {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        if (!self.field.editor.focused) return false;
        // A single-line field commits on Enter instead of inserting a newline.
        if (keycode == text_editor.KEY_ENTER) {
            self.submit();
            return true;
        }
        const action = text_editor.handleKey(&self.field.editor, keycode, mods.shift, mods.shortcut());
        return action != .ignored;
    }

    // Composed text from the platform: `A` under Caps Lock, `*`, `(`, `é`. macOS sends this INSTEAD of a key for a printable.
    pub fn onText(ctx: ?*anyopaque, run: []const u8) bool {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        if (!self.field.editor.focused) return false;
        return text_editor.handleText(&self.field.editor, run) != .ignored;
    }
};
