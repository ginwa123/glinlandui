// The ViewModel: the only writer of the screen's state, and the owner of everything that must outlive a frame.
const std = @import("std");
const glinlandui = @import("glinlandui");

const state_mod = @import("state.zig");

const dialog = glinlandui.file_dialog;
const Machine = state_mod.Machine;

pub const DialogViewModel = struct {
    // The state, as a plain value: an intent replaces it, and the next frame reads whatever it says.
    state: Machine = .{},

    // The dialogs are called with the Activity's allocator, because a `Selection`'s memory belongs to whoever passed it in.
    alloc: std.mem.Allocator = glinlandui.platform.allocator,

    // A click runs AFTER the frame that declared it, so each button's context is a field of the model and never a stack local.
    action_ctxs: [state_mod.ACTIONS.len]ActionCtx = undefined,

    // One row button's context: the model, and which of `ACTIONS` this button asked for.
    pub const ActionCtx = struct {
        vm: *DialogViewModel,
        index: usize,
    };

    pub fn init() DialogViewModel {
        return .{};
    }

    // `onCreate`: the Activity hands the model the allocator its dialogs will be called with.
    pub fn start(self: *DialogViewModel, alloc: std.mem.Allocator) void {
        self.alloc = alloc;
    }

    // `val state by vm.state`: the machine the view draws, by pointer because `line` composes into the machine's own buffer.
    pub fn uiState(self: *DialogViewModel) *Machine {
        return &self.state;
    }

    // THE integration: ask for one kind of dialog and fold the answer in. It BLOCKS — a file dialog is modal, and an app that must keep painting calls this on a worker thread with `timeout_ms` set.
    pub fn open(self: *DialogViewModel, kind: dialog.Kind) void {
        const options = state_mod.optionsFor(kind, self.state.folderHint());

        const selection = switch (kind) {
            .open_file => dialog.openFile(self.alloc, options),
            .open_folder => dialog.openFolder(self.alloc, options),
            .save_file => dialog.saveFile(self.alloc, options),
        } catch |err| {
            self.state.fromError(err);
            return;
        };
        // Unconditional and safe for the cancelled case: `deinit` on an empty selection is a no-op, so there is no branch here to get wrong.
        defer selection.deinit(self.alloc);

        self.takeOutcome(kind, selection);
    }

    // The intent that TAKES an answer: by value, copied out, so the caller may free the selection in any order it likes.
    pub fn takeOutcome(self: *DialogViewModel, kind: dialog.Kind, selection: dialog.Selection) void {
        self.state.fromSelection(kind, selection);
    }

    // `onCleared()`: the store calls this when the screen goes away. This model holds no timers and no buffers of its own.
    pub fn onCleared(self: *DialogViewModel) void {
        _ = self;
    }
};
