// The Activity: what `MainActivity.onCreate` does in the Compose sample.
// It owns the ViewModelStore, installs the composition, and routes the window's events into the model. It holds
// no UI of its own — the screen is `view.TodoScreen`, and the only thing this file knows about it is its name.
const glinlandui = @import("glinlandui");
const input_mod = glinlandui.components.input;
const frame = glinlandui.frame;
const text_editor = glinlandui.text_editor;

const view = @import("view.zig");
const composition = @import("composition.zig");
const view_model = @import("view_model.zig");
const theme_mod = @import("theme.zig");

pub const App = struct {
    // `ViewModelStoreOwner`: one screen, one store, one ViewModel for the life of the window.
    store: view_model.Store(view_model.TodoViewModel) = .{},
    comp: composition.Composition = .{},
    // The field the keyboard types into. It is the Activity's, because the Activity is what receives the keys.
    field: view.Field = .{},
    // Asks the window for one more frame when the model publishes outside an input event.
    pump: ?*const fn (?*anyopaque) void = null,
    pump_ctx: ?*anyopaque = null,
    // Stops that pump once nothing is left to draw, so an idle window is silent.
    idle: ?*const fn (?*anyopaque) void = null,

    // Bind the pieces that point at each other. Called once the App is where it will live — a Field bound inside
    // a function that returns it by value would point at a struct that no longer exists.
    pub fn start(self: *App) void {
        self.field.bind();
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

        var scope = view.Scope{
            .comp = &self.comp,
            .theme = theme_mod.dark,
            .vm = self.vm(),
            .field = &self.field,
        };
        view.TodoScreen(&scope);

        // Nothing asked for another frame during this one, so the pump has nothing left to draw.
        if (!self.comp.invalidated) self.stopFrames();
    }

    fn requestFrame(ctx: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        if (self.pump) |pump| pump(self.pump_ctx);
    }

    fn stopFrames(self: *App) void {
        if (self.idle) |idle| idle(self.pump_ctx);
    }

    // One key event. Only the field that owns the keyboard types; clicking anywhere else takes it away.
    pub fn onKey(ctx: ?*anyopaque, mods: input_mod.Mods, keycode: u32) bool {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        if (!frame.isFocused(view.field_id)) return false;

        // `KeyboardActions(onDone = { vm.add() })`: Enter commits, it does not insert a newline into a one-line field.
        if (keycode == text_editor.KEY_ENTER) {
            self.vm().add();
            return true;
        }
        return switch (text_editor.handleKey(&self.field.ed, keycode, mods.shift, mods.shortcut())) {
            .edited => true,
            else => false,
        };
    }

    // Composed text from the platform: `A` under Caps Lock, `*`, `(`, `é`. macOS sends this INSTEAD of a key for a
    // printable, so this path and `onKey` never both insert the same character.
    pub fn onText(ctx: ?*anyopaque, text: []const u8) bool {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        if (!frame.isFocused(view.field_id)) return false;
        return switch (text_editor.handleText(&self.field.ed, text)) {
            .edited => true,
            else => false,
        };
    }
};
