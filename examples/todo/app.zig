// The Activity: what `MainActivity.onCreate` does in the Compose sample.
// It owns the ViewModelStore, installs the composition, and routes the window's events into the model. It holds no UI of its own.
const glinlandui = @import("glinlandui");
const input_mod = glinlandui.components.input;
const text_editor = glinlandui.text_editor;

const view = @import("view.zig");
const view_model = @import("view_model.zig");
const state_mod = @import("state.zig");

pub const App = struct {
    // `ViewModelStoreOwner`: one screen, one store, one ViewModel for the life of the window.
    store: glinlandui.view_model.Store(view_model.TodoViewModel) = .{},
    comp: glinlandui.composition.Composition = .{},
    // The field the keyboard types into. It owns its buffer, so there is nothing to bind here.
    field: input_mod.FieldCtx = .{ .id = view.field_id },
    // Asks the window for one more frame when the model publishes outside an input event.
    pump: ?*const fn (?*anyopaque) void = null,
    pump_ctx: ?*anyopaque = null,
    // Stops that pump once nothing is left to draw, so an idle window is silent.
    idle: ?*const fn (?*anyopaque) void = null,

    pub fn start(self: *App) void {
        self.comp.on_invalidate = requestFrame;
        self.comp.invalidate_ctx = self;
    }

    // `viewModel()`: the store's instance, created on the first frame and kept for the life of the screen.
    pub fn vm(self: *App) *view_model.TodoViewModel {
        return self.store.getOrCreate(view_model.TodoViewModel.init);
    }

    // `setContent { MaterialTheme { Surface { TodoScreen() } } }`, as the Host's root function.
    pub fn content(ctx: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        self.comp.beginFrame();

        const model = self.vm();
        var scope = view.Scope{
            .comp = &self.comp,
            .theme = glinlandui.theme.dark,
            .vm = model,
            .field = &self.field,
            // `val state by vm.state.collectAsState()`
            .state = self.comp.collectAsState(state_mod.TodoUiState, model.state.asStateFlow()),
        };
        view.TodoScreen(&scope);

        // Nothing asked for another frame during this one, so the pump has nothing left to draw.
        if (!self.comp.invalidated) self.stopFrames();
    }

    // `KeyboardActions(onDone = { vm.add(field.text()) })`: the draft goes up as an argument, and the field clears only if it was taken.
    pub fn submit(self: *App) void {
        if (self.vm().add(self.field.editor.text())) self.field.editor.setText("");
    }

    fn requestFrame(ctx: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        if (self.pump) |pump| pump(self.pump_ctx);
    }

    fn stopFrames(self: *App) void {
        if (self.idle) |idle| idle(self.pump_ctx);
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
