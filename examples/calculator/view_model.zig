// The ViewModel: the only place the machine is written.
// This is Kotlin's `CalculatorViewModel`, and `Store` in the engine is its `ViewModelStore`.
// Every public function here is an INTENT the view or the host may raise: it never draws, never reads a widget, never knows a window exists.
const std = @import("std");
const glinlandui = @import("glinlandui");
const input_mod = glinlandui.components.input;
const state_mod = @import("state.zig");

const Key = state_mod.Key;
const Machine = state_mod.Machine;

// Keypad keys the evdev code does not produce as printable ASCII, so `onKeycode` routes them by code instead of by character.
pub const KEY_KP_ENTER: u32 = 96;
pub const KEY_KP_PLUS: u32 = 78;
pub const KEY_KP_MINUS: u32 = 74;
pub const KEY_KP_MULTIPLY: u32 = 55;
pub const KEY_KP_DIVIDE: u32 = 98;

pub const CalculatorViewModel = struct {
    // The state, as a plain value: an intent replaces it, and the next frame reads whatever it says. It also carries `expression()`'s scratch, which is why the text Clay is handed survives the declare.
    machine: Machine = Machine.init(),

    // No per-key click array: the engine's registry keeps one entry per key holding this model's address and the grid index, so the context outlives the frame on its own.

    pub fn init() CalculatorViewModel {
        return .{};
    }

    // `val display by vm.state.collectAsState()` — read by the view while declaring, so it returns the model's own buffer.
    pub fn display(self: *const CalculatorViewModel) []const u8 {
        return self.machine.display();
    }

    // The pending-operation line. `*Self` rather than `*const Self` because the machine formats into its own buffer, and the slice must outlive this frame.
    pub fn expression(self: *CalculatorViewModel) []const u8 {
        return self.machine.expression();
    }

    // `val state by vm.state`: the latched error is state, and the view tints the display from it.
    pub fn hasError(self: *const CalculatorViewModel) bool {
        return self.machine.err;
    }

    // `fun press(key: Key)`: one keypad key, as an intent.
    pub fn press(self: *CalculatorViewModel, key: Key) void {
        self.machine.press(key);
    }

    // The pointer path: the click registry carries the grid index, and the model turns it into a key.
    pub fn pressIndex(self: *CalculatorViewModel, index: usize) void {
        self.machine.press(state_mod.KEYS_BY_INDEX[index]);
    }

    // `fun feedChar(c: Char)`: the printable half of the keyboard, mapped by the engine's keymap.
    pub fn feedChar(self: *CalculatorViewModel, c: u8) void {
        self.machine.feedChar(c);
    }

    // `fun onKey(code: KeyCode): Boolean`: the Host KeyChain's handler, in the shape the chain calls it. Escape is deliberately NOT consumed — `keyToClose` uses it to quit the window.
    pub fn onKeycode(self: *CalculatorViewModel, mods: input_mod.Mods, keycode: u32) bool {
        if (input_mod.keyChar(keycode, mods.shift)) |c| {
            self.feedChar(c);
            return true;
        }
        switch (keycode) {
            KEY_KP_ENTER, input_mod.KEY_ENTER => self.press(.equals),
            input_mod.KEY_BACKSPACE, input_mod.KEY_DELETE => self.press(.backspace),
            KEY_KP_PLUS => self.press(.plus),
            KEY_KP_MINUS => self.press(.minus),
            KEY_KP_MULTIPLY => self.press(.times),
            KEY_KP_DIVIDE => self.press(.divide),
            else => return false,
        }
        return true;
    }

    // `onCleared()`: the store calls this when the screen goes away. This ViewModel holds no timer and no buffer of its own.
    pub fn onCleared(self: *CalculatorViewModel) void {
        _ = self;
    }
};

// ---- tests ---------------------------------------------------------------------------------------------------

test "keyChar maps the calculator's printable keycodes" {
    // 0-9 live on the evdev digits row (2..11), '*' is evdev 55.
    try std.testing.expectEqual(@as(?u8, '7'), input_mod.keyChar(8, false));
    try std.testing.expectEqual(@as(?u8, '0'), input_mod.keyChar(11, false));
    try std.testing.expectEqual(@as(?u8, '/'), input_mod.keyChar(53, false));
    try std.testing.expectEqual(@as(?u8, '.'), input_mod.keyChar(52, false));
    // '*' is NOT in keyChar's table: evdev 55 is the keypad '*', so it is routed by onKeycode's KEY_KP_MULTIPLY arm instead.
    try std.testing.expectEqual(@as(?u8, null), input_mod.keyChar(KEY_KP_MULTIPLY, false));
    try std.testing.expectEqual(@as(?u8, '+'), input_mod.keyChar(13, true));
    // Non-printables (Enter, Backspace, Escape) are handled by the owner.
    try std.testing.expectEqual(@as(?u8, null), input_mod.keyChar(input_mod.KEY_ENTER, false));
    try std.testing.expectEqual(@as(?u8, null), input_mod.keyChar(input_mod.KEY_BACKSPACE, false));
}

test "a keypad click and the same key press agree" {
    var vm = CalculatorViewModel.init();
    // row 3 col 0 is index 12 -> "1"; row 1 col 0 is index 4 -> "7".
    vm.pressIndex(12);
    vm.pressIndex(4);
    try std.testing.expectEqualStrings("17", vm.display());
    // And the machine agrees with the label under that index.
    try std.testing.expectEqualStrings("1", state_mod.KEY_LABELS[12]);
    try std.testing.expectEqualStrings("7", state_mod.KEY_LABELS[4]);
}
