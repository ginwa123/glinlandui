//! glinlandui example: the system file dialog.
//!
//! This is the "how to use" for `glinlandui.file_dialog` — the one call shape
//! an application needs, the errors it can get, and the two rules that decide
//! whether the integration feels right or feels broken:
//!
//!   1. A CANCELLED dialog is a `Status`, not an error. The user closed it on
//!      purpose. An app that treats that as a failure shows an error message
//!      for something nobody mistook.
//!   2. A `Selection` BORROWS its memory from the allocator you handed in.
//!      Copy what you keep before `deinit`, or you are reading freed memory.
//!
//! Run it with `zig build run-file-dialog`. The three buttons each open one
//! kind of dialog and print what came back.
//!
//! ## Why the logic is in a `Machine` and not in the click handler
//!
//! Everything a dialog can answer is turned into an `Outcome` by
//! `Machine.fromSelection` / `Machine.fromError`, and both are pure. That is
//! what makes this example's own tests meaningful: they run in the
//! cross-platform parity suite, on every OS, with no window, no compositor and
//! no session bus anywhere in sight. The click handler is four lines of glue
//! over them, and the glue is the part that has nothing to be wrong about.
//!
//! Note what that means for the test build. `platform.zig` selects
//! `core/file_dialog_portable.zig` under `builtin.is_test`, so in a test
//! `glinlandui.file_dialog` resolves to the `error.Unsupported` stub — with
//! the SAME `Options` / `Status` / `Selection` types, because those come from
//! the shared contract in `core/`. So these tests exercise the real contract on
//! every platform. The live XDG round trip is a different file
//! (`src/linux/file_dialog.zig`) and it is tested in `zig build native-test`.
//!
//! ## Running it without a desktop
//!
//! `GLIN_FILE_DIALOG_CHECK=1 zig build run-file-dialog` opens no window and
//! opens no dialog. It prints what this host's backend is and whether it is
//! wired up, then exits. That is the mode CI uses, and it is why a headless
//! runner can exercise the example: a real dialog needs a real user, and a
//! real portal, and neither exists on a build machine.
const std = @import("std");
const glinlandui = @import("glinlandui");

const Color = glinlandui.Color;
const components = glinlandui.components;
const dialog = glinlandui.file_dialog;

// ---- Palette (app-local; components stay theme-neutral) ----
const COLOR_BG = Color.hexC("#101014");
const COLOR_PANEL = Color.hexC("#1b1b21");
const COLOR_FG = Color.hexC("#f0f0f5");
const COLOR_DIM = Color.hexC("#8a8a99");
const COLOR_OK = Color.hexC("#6bd968");
const COLOR_WARN = Color.hexC("#e8c56b");
const COLOR_ERR = Color.hexC("#ff6b6b");

const WIN_W: u32 = 520;
const WIN_H: u32 = 300;

/// Everything a dialog can answer, reduced to what the UI actually needs.
///
/// A flat union rather than the raw `(Status, Error)` pair because a `switch`
/// over those two at the call site is where integration bugs live: the
/// temptation is to write one `catch` and one `if`, and the two statuses that
/// are NOT errors quietly fall through it. Folding them together once, here,
/// means there is exactly one place that has to be right.
pub const Outcome = union(enum) {
    /// Nothing has been asked yet.
    idle,
    /// The user confirmed. The path is owned by the `Machine`, not by the
    /// `Selection` that reported it.
    selected: Selected,
    /// The user dismissed the dialog. NOT a failure — see the note below.
    cancelled,
    /// This host has no dialog backend (a browser, say).
    unsupported,
    /// Linux: no D-Bus session bus, so no portal to ask.
    no_session_bus,
    /// Linux: the bus is there, nothing owns `org.freedesktop.portal.Desktop`.
    no_portal,
    /// The portal answered, and refused.
    portal_error,
    /// `timeout_ms` expired with the dialog still open.
    timed_out,

    /// The one-line summary the status bar shows.
    ///
    /// Only the fixed strings live here. The `selected` case needs a buffer
    /// (it composes a count and a path), so it is NOT handled by this switch
    /// — `Machine.line` owns that arm and this one returns "" for it. Keeping
    /// a second formatter would let the two disagree about what a selection
    /// looks like, which is the same class of bug as two definitions of a
    /// state machine's terminal state.
    pub fn line(self: Outcome) []const u8 {
        return switch (self) {
            .idle => "Nothing asked yet. Pick one of the three.",
            .selected => "", // composed by `Machine.line`
            // Deliberately calm, and deliberately not the word "error": the
            // user pressed Escape, which is a decision, not a malfunction.
            .cancelled => "Cancelled — nothing was chosen.",
            .unsupported => "No file dialog on this platform.",
            .no_session_bus => "No D-Bus session bus. Is this a desktop session?",
            .no_portal => "No desktop portal installed (xdg-desktop-portal).",
            .portal_error => "The portal refused the request.",
            .timed_out => "Timed out waiting for the dialog.",
        };
    }

    /// A confirmed selection, reduced to what a status bar can honestly show.
    ///
    /// `count` is here because it is the difference between "here is your
    /// file" and "here is your file, and two others you picked are not in
    /// this string". `open_file` is opened with `multiple = true` in this
    /// example, so a five-file selection is an ORDINARY outcome — and an app
    /// that keeps only the first path and says nothing about it is worse than
    /// one that never offered the choice, because the user believes the other
    /// four were taken.
    pub const Selected = struct {
        /// The FIRST path. Owned by the `Machine`, not by the `Selection`.
        path: []const u8,
        /// How many paths the dialog actually returned. `1` in the ordinary
        /// case; greater only for a `multiple` request.
        count: usize,
    };

    /// Whether the status bar should look like something went wrong.
    ///
    /// `cancelled` is deliberately NOT in this set. That is the whole point of
    /// modelling it as a `Status` rather than an error: the app has nothing to
    /// apologise for.
    pub fn isProblem(self: Outcome) bool {
        return switch (self) {
            .idle, .selected, .cancelled => false,
            .unsupported, .no_session_bus, .no_portal, .portal_error, .timed_out => true,
        };
    }
};

/// The app's state. No window, no Clay, no backend — just the answer to the
/// last question, in a form the UI can draw and a test can assert.
pub const Machine = struct {
    outcome: Outcome = .idle,
    /// Which dialog produced `outcome`.
    ///
    /// Kept even for a cancellation, because "you cancelled the folder
    /// picker" and "you cancelled Save As" are different conversations the
    /// user was having, and the status bar is the only place left to say
    /// which one just ended.
    last_kind: dialog.Kind = .open_file,
    /// The last selected path, copied here.
    ///
    /// It has to be copied. `Selection.paths` is allocated by the allocator
    /// passed to `openFile` and released by `Selection.deinit`, so holding the
    /// slice past the `defer` is a use-after-free that usually still reads
    /// plausible — the heap is rarely overwritten that fast — which makes it
    /// the worst kind of bug to notice.
    path_buf: [1024]u8 = undefined,
    path_len: usize = 0,
    /// Scratch for `line()`. It is a FIELD rather than a local so the returned
    /// slice stays valid for the draw that reads it — the same reason
    /// `path_buf` lives here. It is also why `line` takes a mutable `*Machine`:
    /// composing a sentence needs to write, and taking `*const` would only buy
    /// a guarantee the caller does not need.
    line_buf: [1200]u8 = undefined,

    /// The folder to start the next dialog in: the directory of the last
    /// thing the user picked.
    ///
    /// A dialog that reopens in the user's home directory every time is
    /// technically correct and infuriating in practice — the second time you
    /// open it, you are somewhere else entirely.
    ///
    /// Pure, and that is why it is a function rather than a line in the click
    /// handler: the string surgery is the part worth testing.
    pub fn folderHint(self: *const Machine) ?[]const u8 {
        const path = switch (self.outcome) {
            .selected => |s| s.path,
            else => return null,
        };
        const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
        // No leading slash means a bare filename, which is not a path at all;
        // and a leading "/" is the root, which is a useless hint.
        if (slash == 0) return null;
        return path[0..slash];
    }

    /// The status-bar text, composed.
    ///
    /// This owns the `selected` arm, which `Outcome.line` deliberately does
    /// not: a selection is the one outcome that has to say WHICH dialog
    /// answered and HOW MUCH came back, and that needs a buffer.
    ///
    /// The count matters most here. This example opens its file dialog with
    /// `multiple = true`, so "3 files, first: /a.png" is a line the user can
    /// act on, where a bare "/a.png" is a line that makes them believe the
    /// other two were lost.
    pub fn line(self: *Machine) []const u8 {
        const sel = switch (self.outcome) {
            .selected => |s| s,
            else => return self.outcome.line(),
        };
        const what = switch (self.last_kind) {
            .open_file => "file",
            .open_folder => "folder",
            .save_file => "save target",
        };
        const written = if (sel.count > 1)
            std.fmt.bufPrint(
                &self.line_buf,
                "{d} files chosen, first: {s}",
                .{ sel.count, sel.path },
            ) catch sel.path
        else
            std.fmt.bufPrint(&self.line_buf, "{s}: {s}", .{ what, sel.path }) catch sel.path;
        return written;
    }

    /// Fold a successful call's `Selection` into an `Outcome`.
    ///
    /// `kind` is a parameter, not a detail, and this is the correction that
    /// came out of writing the tests: the example offers three different
    /// dialogs, and a status bar that renders a picked FOLDER exactly like a
    /// picked FILE is not telling the user which question they answered. The
    /// three `Selection`s are the same type and the same shape — the only
    /// thing that distinguishes them is the question that was asked.
    ///
    /// Takes the `Selection` BY VALUE and copies out of it, so the caller can
    /// `defer selection.deinit(alloc)` unconditionally and in any order. The
    /// cancellation branch is here rather than at the call site for the reason
    /// above: it is a `Status`, and folding it in is what stops it from being
    /// mistaken for a failure.
    pub fn fromSelection(self: *Machine, kind: dialog.Kind, selection: dialog.Selection) void {
        self.last_kind = kind;
        switch (selection.status) {
            .selected => {
                const path = selection.first() orelse {
                    // `.selected` with no path contradicts the contract. It is
                    // handled rather than trusted because this is exactly the
                    // value a careless backend produces, and a UI that indexes
                    // into an empty slice is a crash in someone else's app.
                    self.outcome = .portal_error;
                    return;
                };
                const n = @min(path.len, self.path_buf.len);
                @memcpy(self.path_buf[0..n], path[0..n]);
                self.path_len = n;
                // The COUNT is kept even though only the first path is. See
                // `Selected.count`: silently dropping N-1 paths the user
                // picked is a lie told by omission.
                self.outcome = .{ .selected = .{
                    .path = self.path_buf[0..n],
                    .count = selection.paths.len,
                } };
            },
            .cancelled => self.outcome = .cancelled,
            .other => self.outcome = .portal_error,
        }
    }

    /// Fold a failed call into an `Outcome`.
    ///
    /// ## Why this matches on `@errorName` and not on the error value
    ///
    /// The obvious thing is `switch (err) { error.Unsupported => ..., else => ... }`,
    /// and that is exactly what `core/file_dialog_contract.zig` documents. It
    /// does not compile on any desktop.
    ///
    /// The reason is that the returned error set is PER BACKEND, and the three
    /// desktop backends declare a bare `!Selection`, which makes the set
    /// INFERRED:
    ///
    ///   - all three are missing `error.Unsupported` entirely. Each has a real
    ///     backend, so "this host has no dialog" is not a thing that can
    ///     happen — which is exactly why the contract's own example, the one
    ///     every reader tries first, fails on its first named arm;
    ///   - Linux's is much wider than the contract: OutOfMemory, the socket
    ///     errors, its own D-Bus failures, none of which the contract names;
    ///   - macOS and Windows cannot produce `NoPortal` at all, because they
    ///     do not talk to a D-Bus portal.
    ///
    /// So a `switch` arm naming `error.Unsupported` is a compile error on all
    /// three desktops, and one naming `error.NoPortal` is a compile error on
    /// macOS and Windows. No `else` rescues it: Zig checks each arm against
    /// the set it is switching over before it ever reaches the `else`.
    ///
    /// The irony worth recording: `core/file_dialog_portable.zig` declares
    /// `Error!Selection` explicitly, so it is the ONE backend that returns the
    /// contract's set and the one where the documented switch compiles. It is
    /// also the backend you only get in a test build or in a browser — never
    /// on a desktop, which is where the code actually runs.
    ///
    /// Matching the NAME sidesteps all of it, and costs a string comparison
    /// that happens once, on a path that has already shown a dialog. The named
    /// errors keep their own words because they are the ones a user can act
    /// on; everything else collapses into `portal_error`, which is the honest
    /// "the dialog could not be completed" line.
    ///
    /// The real fix is to narrow every backend to `contract.Error`, which would
    /// make the documented switch true. That needs a name for OutOfMemory and
    /// a decision about whether a socket failure is `PortalError` or something
    /// more precise — a change to the error CONTRACT, not to an example, and
    /// worth making deliberately rather than as a side effect of writing one.
    pub fn fromError(self: *Machine, err: anyerror) void {
        const name = @errorName(err);
        self.outcome = if (std.mem.eql(u8, name, "Unsupported"))
            .unsupported
        else if (std.mem.eql(u8, name, "NoSessionBus"))
            .no_session_bus
        else if (std.mem.eql(u8, name, "NoPortal"))
            .no_portal
        else if (std.mem.eql(u8, name, "Timeout"))
            .timed_out
        else
            .portal_error;
    }
};

/// The filter list this example sends, and the thing worth knowing about it.
///
/// `filters` is best effort on Linux. The XDG portal protocol declares the
/// option as `a(sa(us))` — name, then a list of (type, pattern) — and the bus
/// in front of it cannot unmarshal that from inside a variant; it wants
/// `a(sa(ss))`, which is byte-identical on the wire and differs only in the
/// type system's name. Send the declared one and a portal takes the whole
/// connection down rather than refusing the option, so a portal that will not
/// take a filter list gets a second, plainer request instead of a dialog that
/// never opens. The dialog opens either way; it just has no filter dropdown.
///
/// That is why this example is free to pass filters and not worry about it.
const IMAGE_FILTERS = [_]dialog.Filter{
    .{ .name = "Images", .rules = &.{
        .{ .pattern = "*.png" },
        .{ .pattern = "*.jpg" },
        .{ .pattern = "*.jpeg" },
        .{ .pattern = "*.webp" },
    } },
    .{ .name = "All files", .rules = &.{.{ .pattern = "*" }} },
};

/// The buttons, in draw order. A fixed list so the draw path and the click
/// handler agree on what "the third button" means without either of them
/// carrying an index arithmetic bug.
const ACTIONS = [_]struct { id: []const u8, label: []const u8, kind: dialog.Kind }{
    .{ .id = "dlg-open-file", .label = "Open File...", .kind = .open_file },
    .{ .id = "dlg-open-folder", .label = "Open Folder...", .kind = .open_folder },
    .{ .id = "dlg-save-file", .label = "Save As...", .kind = .save_file },
};

pub const App = struct {
    m: Machine = .{},
    /// The allocator the dialogs are called with. Stored on the app because
    /// the click callback receives only `?*anyopaque`, and a `Selection`'s
    /// memory belongs to whoever passed the allocator in.
    alloc: std.mem.Allocator = undefined,

    /// Ask for one kind of dialog and fold the answer in.
    ///
    /// THIS is the whole integration. Everything else in this file is window
    /// management and pretty colours.
    ///
    /// Two things to notice, because they are the ones an app gets wrong:
    ///
    ///  - It BLOCKS. A file dialog is modal, and this runs on the thread that
    ///    runs the event loop, so the window is frozen for as long as the
    ///    dialog is up. That is what "modal" means and it is fine for the
    ///    overwhelmingly common case. An app that must keep painting — a
    ///    progress display, a cancellable operation — calls this on a worker
    ///    thread and posts the result back, and it should then set
    ///    `timeout_ms` too, because the portal call has no deadline of its
    ///    own. `timeout_ms` is Linux-only; AppKit and COM own their modal
    ///    loops and the only way to stop one is a cancel posted from a timer
    ///    the host will not run while it is blocked.
    ///  - There is NO `defer` around the call. `catch` handles the failure
    ///    case and falls through, so there is no `Selection` to free there,
    ///    and the one that IS returned is freed on the very next line.
    fn request(self: *App, kind: dialog.Kind) void {
        var options = dialog.Options{
            .kind = kind,
            .current_folder = self.m.folderHint(),
        };
        switch (kind) {
            .open_file => {
                options.title = "Pick an image";
                options.filters = &IMAGE_FILTERS;
                options.multiple = true;
            },
            .open_folder => {
                options.title = "Choose a folder";
                options.accept_label = "Use folder";
            },
            .save_file => {
                options.title = "Save as";
                options.filters = &IMAGE_FILTERS;
                options.current_name = "untitled.png";
            },
        }

        const selection = switch (kind) {
            .open_file => dialog.openFile(self.alloc, options),
            .open_folder => dialog.openFolder(self.alloc, options),
            // `multiple` is ignored for a save target, which is a single path
            // by definition — see `Kind.allowsMultiple`. Set it anyway and one
            // backend honours it while another silently does not.
            .save_file => dialog.saveFile(self.alloc, options),
        } catch |err| {
            self.m.fromError(err);
            return;
        };
        // Unconditional, and safe for the cancelled case: `deinit` on an empty
        // selection is a no-op, so there is no branch to get wrong here.
        defer selection.deinit(self.alloc);

        self.m.fromSelection(kind, selection);
    }

    fn onAction(ctx: ?*anyopaque, index: usize) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        self.request(ACTIONS[index].kind);
    }

    pub fn root(ctx: ?*anyopaque, _: u32, _: u32) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        components.box.box(.{
            .id = "dlg-root",
            .direction = .column,
            .w = .grow,
            .h = .grow,
            .bg = COLOR_BG,
            .pad = 16,
            .gap = 12,
        }, self, App.children);
    }

    fn children(self: *App) void {
        components.text.label(.{
            .str = "glinlandui.file_dialog — the system file picker",
            .font_size = 15,
            .color = COLOR_FG,
        });

        // Gate the buttons on `available()`. A browser is the one host with no
        // backend, and a button that cannot work is worse than no button: the
        // user finds out by clicking it.
        if (dialog.available()) {
            components.box.row(.{
                .id = "dlg-actions",
                .w = .grow,
                .h = .{ .fixed = 40 },
                .gap = 8,
            }, self, actionRow);
        } else {
            components.box.box(.{
                .id = "dlg-unavailable",
                .w = .grow,
                .h = .{ .fixed = 40 },
                .bg = COLOR_PANEL,
                .radius = 8,
                .pad = 12,
                .child_align = .{ .x = .left, .y = .center },
            }, self, unavailableChild);
        }

        components.box.box(.{
            .id = "dlg-status",
            .w = .grow,
            .h = .{ .fixed = 76 },
            .bg = COLOR_PANEL,
            .radius = 8,
            .pad = 12,
            .gap = 4,
        }, self, statusChildren);
    }

    fn unavailableChild(self: *App) void {
        _ = self;
        components.text.label(.{
            .str = "No file dialog on this platform (the browser has none).",
            .font_size = 13,
            .color = COLOR_WARN,
        });
    }

    fn actionRow(self: *App) void {
        var i: usize = 0;
        while (i < ACTIONS.len) : (i += 1) {
            var ctx = ActionCtx{ .app = self, .index = i };
            components.button.button(.{
                .id = ACTIONS[i].id,
                .label = ACTIONS[i].label,
                .font_size = 14,
                .h = 40,
                .bg = Color.hexC("#2f6df6"),
                .hover_bg = Color.hexC("#4a82ff"),
                .on_click = actionOnClick,
                .ctx = &ctx,
            });
        }
    }

    fn statusChildren(self: *App) void {
        const outcome = self.m.outcome;
        components.text.label(.{
            .str = "Last answer",
            .font_size = 11,
            .color = COLOR_DIM,
        });
        components.text.label(.{
            .str = self.m.line(),
            .font_size = 14,
            // Green for an answer, red for a problem, and NOT red for a
            // cancellation — `isProblem` is the same function the test holds
            // the line on, so the two cannot drift apart.
            .color = if (outcome.isProblem()) COLOR_ERR else COLOR_OK,
        });
    }
};

/// One row button's context. Passed by pointer because `box`'s children
/// callback dedupes its ctx type at comptime, so a `*ActionCtx` and an `*App`
/// must not collapse to the same type.
const ActionCtx = struct {
    app: *App,
    index: usize,
};

fn actionOnClick(ctx: ?*anyopaque) void {
    const ac: *ActionCtx = @ptrCast(@alignCast(ctx.?));
    App.onAction(ac.app, ac.index);
}

pub fn main() !void {
    // The `--check` escape hatch, as an environment variable because that is
    // this repository's existing convention (`QS_SETTINGS_TEST_FRAMES`,
    // `GLIN_DUMP_SURFACE`) and because `zig build run-file-dialog` forwards
    // args to the binary, so an argv flag would also have to survive that
    // indirection.
    if (std.c.getenv("GLIN_FILE_DIALOG_CHECK") != null) return check();

    const alloc = glinlandui.platform.allocator;

    var app = App{ .alloc = alloc };
    var host = try glinlandui.host.Host.init(alloc, &app, App.root);
    defer host.deinit();

    var window = glinlandui.Window.init(alloc, .{
        .app_id = "glinlandui-file-dialog",
        .title = "glinlandui - file dialog",
        .width = WIN_W,
        .height = WIN_H,
        .min_width = WIN_W,
        .min_height = WIN_H,
    });
    window.delegate = host.delegate();

    window.run() catch |err| {
        std.debug.print("window unavailable ({s})\n", .{@errorName(err)});
    };
}

/// Report this host's file-dialog backend without opening anything.
///
/// This is what CI runs, and it is a real check rather than a smoke test: the
/// call it makes is the same `glinlandui.file_dialog` the GUI path calls, so
/// it proves the module resolved, the types are the ones the contract
/// promises, and the backend reports itself honestly — all without a window, a
/// compositor, a user, or a portal.
fn check() void {
    // `std.debug.print` rather than a stdout writer: this is the convention the
    // rest of this repository's examples use for the few lines they print, and
    // `std.io` does not exist in Zig 0.16.
    std.debug.print("backend:     {s}\n", .{backendName()});
    std.debug.print("available:   {}\n", .{dialog.available()});
    std.debug.print("open_file:   {s}\n", .{probe()});
    std.debug.print("open_folder: {s}\n", .{probe()});
    std.debug.print("save_file:   {s}\n", .{probe()});
}

/// Which backend this build resolved to, by name.
///
/// `std.builtin.os.tag` is the one OS branch the layering gate allows outside
/// `src/platform.zig` — and this file is an EXAMPLE, which is outside the
/// gate's scope entirely. Inside the library, the same question is asked in
/// one place (`platform.zig`) precisely so that it does not have to be asked
/// here. A name printed for a human reading CI output is the cheapest thing
/// this example can do with that information; a real app has no use for it.
fn backendName() []const u8 {
    return switch (@import("builtin").os.tag) {
        .linux => "xdg-desktop-portal (pure-Zig D-Bus)",
        .macos => "NSOpenPanel",
        .windows => "IFileDialog",
        else => "none (error.Unsupported)",
    };
}

/// Call `openFile` and describe how it ended, WITHOUT a dialog appearing.
///
/// This is the one function here that calls the real backend, and it is what
/// makes the check mode worth running: a host with no session bus, no portal
/// or no backend at all answers with a specific error, and printing THAT is
/// more informative than a green exit code.
///
/// It must never open a real dialog. A `timeout_ms` bounds the wait so a host
/// that genuinely can show one — a developer running this on their desktop —
/// fails the check in two seconds instead of sitting on a modal window that
/// no one is there to dismiss.
fn probe() []const u8 {
    const selection = dialog.openFile(std.heap.page_allocator, .{
        .kind = .open_file,
        .title = "glinlandui check",
        .timeout_ms = 2_000,
    }) catch |err| {
        // Matched by NAME for the reason `Machine.fromError` gives in full: a
        // desktop backend's error set is inferred, so naming a member this
        // host does not have is a compile error, and an `else` does not save
        // it. On a CI runner the expected answer is `NoSessionBus`; on a
        // developer desktop it is `NoPortal` or, if a portal is somehow
        // answering, a real selection — which is why `timeout_ms` is set
        // above, so the third case costs two seconds instead of a modal
        // window.
        return @errorName(err);
    };
    defer selection.deinit(std.heap.page_allocator);
    return switch (selection.status) {
        .selected => "selected (a real dialog opened — press Cancel next time)",
        .cancelled => "cancelled",
        .other => "other",
    };
}

// ---- Tests ----
//
// These are part of the cross-platform PARITY suite: they compile and run
// identically on Linux, macOS and Windows, so `ci/check_test_parity.sh`
// counts them on all three and `tests.lock` covers them.
//
// They are portable because `platform.zig` selects
// `core/file_dialog_portable.zig` under `builtin.is_test`, while the `Status`
// and `Selection` types still come from the shared contract — so what is
// asserted here is the real contract, on every platform, rather than a
// stand-in for it. The live XDG round trip lives in
// `src/linux/file_dialog.zig` and runs in `zig build native-test`.

test "a cancelled dialog is reported calmly, not as a problem" {
    var m = Machine{};
    // The user pressed Escape. This is the single most important line in the
    // example, and it is the one most integrations get wrong.
    m.fromSelection(.open_file, .{ .status = .cancelled });
    try std.testing.expectEqual(Outcome{ .cancelled = {} }, m.outcome);
    try std.testing.expect(!m.outcome.isProblem());
}

test "a selected dialog keeps a COPY of the path, and survives the free" {
    const alloc = std.testing.allocator;
    const path = try alloc.dupe(u8, "/home/u/Pictures/cat (1).png");
    const paths = try alloc.alloc([]const u8, 1);
    paths[0] = path;

    var m = Machine{};
    {
        const selection = dialog.Selection{ .status = .selected, .paths = paths };
        m.fromSelection(.open_file, selection);
        // Exactly what an app does: take the answer, then release it.
        selection.deinit(alloc);
    }

    // The allocator is watching. If `fromSelection` had kept the borrowed
    // slice, this read would be a use-after-free and the testing allocator
    // would report the corruption on the next line.
    try std.testing.expectEqualStrings("file: /home/u/Pictures/cat (1).png", m.line());
}

test "a selection with no path is a problem, not an index panic" {
    // `.selected` with nothing in it contradicts the contract, and it is
    // exactly what a careless backend produces. The UI must survive it.
    var m = Machine{};
    m.fromSelection(.open_file, .{ .status = .selected, .paths = &.{} });
    try std.testing.expectEqual(Outcome{ .portal_error = {} }, m.outcome);
    try std.testing.expect(m.outcome.isProblem());
}

test "each error says something a user can act on" {
    // The cases are held as `anyerror` rather than as `dialog.Error`, for the
    // reason `Machine.fromError` gives in full: a desktop backend's error set
    // is inferred, so `error.Unsupported` is not a member of it and a value of
    // type `dialog.Error` cannot be written here on Linux at all. The
    // consequence worth noticing is that this test only ever exercises
    // `fromError` — it cannot tell you which of the five a given backend can
    // actually produce, because that is a property of the backend and not of
    // the mapping.
    var m = Machine{};
    for ([_]struct { err: anyerror, want: Outcome }{
        .{ .err = error.Unsupported, .want = .unsupported },
        .{ .err = error.NoSessionBus, .want = .no_session_bus },
        .{ .err = error.NoPortal, .want = .no_portal },
        .{ .err = error.PortalError, .want = .portal_error },
        .{ .err = error.Timeout, .want = .timed_out },
    }) |case| {
        m.fromError(case.err);
        try std.testing.expectEqual(case.want, m.outcome);
        try std.testing.expect(m.outcome.isProblem());
        // No two failures may share a line: "the dialog failed" for five
        // different problems is the message this API exists to avoid.
        try std.testing.expect(case.want.line().len > 0);
    }
}

test "an error the contract never named still lands somewhere honest" {
    // A backend is allowed to return failures outside the five named ones — the
    // contract says so in so many words — so the catch-all has to produce a
    // line rather than panic or, worse, silence.
    var m = Machine{};
    m.fromError(error.OutOfMemory);
    try std.testing.expectEqual(Outcome{ .portal_error = {} }, m.outcome);
    try std.testing.expect(m.outcome.isProblem());
}

test "the next dialog starts in the folder the last one came from" {
    var m = Machine{};
    // Nothing has been chosen, so there is no folder to suggest and the dialog
    // opens wherever the backend decides.
    try std.testing.expectEqual(@as(?[]const u8, null), m.folderHint());

    m.fromSelection(.open_file, .{
        .status = .selected,
        .paths = @constCast(&[_][]const u8{"/home/u/Pictures/holiday/cat.png"}),
    });
    try std.testing.expectEqualStrings("/home/u/Pictures/holiday", m.folderHint().?);

    // A cancellation forgets it: the user said no, and the next dialog should
    // not appear to remember a choice they declined to make.
    m.fromSelection(.open_file, .{ .status = .cancelled });
    try std.testing.expectEqual(@as(?[]const u8, null), m.folderHint());

    // A bare filename is not a path, and "/" is not a useful hint. Both would
    // otherwise be passed to the backend as `current_folder`, which is a path
    // it will try to open.
    m.fromSelection(.open_file, .{ .status = .selected, .paths = @constCast(&[_][]const u8{"cat.png"}) });
    try std.testing.expectEqual(@as(?[]const u8, null), m.folderHint());
    m.fromSelection(.open_file, .{ .status = .selected, .paths = @constCast(&[_][]const u8{"/cat.png"}) });
    try std.testing.expectEqual(@as(?[]const u8, null), m.folderHint());
}

test "a folder pick reads as a folder, not as a file" {
    // This is the test that was missing, and its absence was a real defect
    // rather than a coverage gap. `fromSelection` used to take only a
    // `Selection`, so all three dialogs produced an identical outcome and the
    // status bar could not tell the user which question they had just
    // answered. A picked folder and a picked file are the same TYPE; the only
    // thing that distinguishes them is the question that was asked, so the
    // question has to travel with the answer.
    const alloc = std.testing.allocator;
    const path = try alloc.dupe(u8, "/home/u/Pictures");
    const paths = try alloc.alloc([]const u8, 1);
    paths[0] = path;

    var m = Machine{};
    const selection = dialog.Selection{ .status = .selected, .paths = paths };
    m.fromSelection(.open_folder, selection);
    selection.deinit(alloc);

    try std.testing.expectEqualStrings("folder: /home/u/Pictures", m.line());
    // A folder selection is a directory, so it is its own `current_folder`
    // for next time — not the parent, which is the bug `folderHint` avoids
    // for files.
    try std.testing.expectEqualStrings("/home/u", m.folderHint().?);
}

test "a save target reads as a save target" {
    const alloc = std.testing.allocator;
    const path = try alloc.dupe(u8, "/home/u/out/untitled.png");
    const paths = try alloc.alloc([]const u8, 1);
    paths[0] = path;

    var m = Machine{};
    const selection = dialog.Selection{ .status = .selected, .paths = paths };
    m.fromSelection(.save_file, selection);
    selection.deinit(alloc);

    try std.testing.expectEqualStrings("save target: /home/u/out/untitled.png", m.line());
    // A save target has exactly one answer by definition, so a count above 1
    // is something no backend should produce — see the next test.
    try std.testing.expect(!dialog.Kind.save_file.allowsMultiple());
}

test "a multi-file selection says how many, not just the first" {
    // `open_file` is opened with `multiple = true` in this example, so this is
    // an ordinary outcome, not an exotic one. Showing only the first path and
    // saying nothing makes the user believe the other two were taken — which
    // is worse than never having offered the choice.
    const alloc = std.testing.allocator;
    const names = [_][]const u8{ "a.png", "b.png", "c.png" };
    const paths = try alloc.alloc([]const u8, names.len);
    for (names, 0..) |n, i| paths[i] = try alloc.dupe(u8, n);

    var m = Machine{};
    const selection = dialog.Selection{ .status = .selected, .paths = paths };
    m.fromSelection(.open_file, selection);

    // Counted BEFORE the free, and readable after it: the count is the thing
    // that must survive, because the paths do not.
    try std.testing.expectEqual(@as(usize, 3), m.outcome.selected.count);
    selection.deinit(alloc);

    try std.testing.expectEqualStrings("3 files chosen, first: a.png", m.line());
    try std.testing.expect(!m.outcome.isProblem());
}

test "a cancelled folder dialog is still a cancellation, not a problem" {
    // The three cancellations are the same STATUS but not the same event, and
    // the one that is easiest to get wrong is the one that looks identical in
    // the data: `.cancelled` carries no kind of its own.
    var m = Machine{};
    for ([_]dialog.Kind{ .open_file, .open_folder, .save_file }) |kind| {
        m.fromSelection(kind, .{ .status = .cancelled });
        try std.testing.expectEqual(Outcome{ .cancelled = {} }, m.outcome);
        try std.testing.expect(!m.outcome.isProblem());
        try std.testing.expectEqualStrings("Cancelled — nothing was chosen.", m.line());
        // The kind is remembered even though nothing was chosen, so the app
        // can say which dialog the user backed out of.
        try std.testing.expectEqual(kind, m.last_kind);
    }
}

test "the filter list is one that a portal can actually be asked for" {
    try std.testing.expectEqual(@as(usize, 2), IMAGE_FILTERS.len);
    for (IMAGE_FILTERS) |f| {
        try std.testing.expect(f.name.len > 0);
        for (f.rules) |r| try std.testing.expect(r.pattern.len > 0);
    }
    // The first group is images, so its rules are globs and the last is the
    // catch-all — which is the order a user expects to see them in.
    try std.testing.expectEqualStrings("*.png", IMAGE_FILTERS[0].rules[0].pattern);
    try std.testing.expectEqualStrings("*", IMAGE_FILTERS[1].rules[0].pattern);
}

test "the three buttons ask for three different portal methods" {
    try std.testing.expectEqual(@as(usize, 3), ACTIONS.len);
    try std.testing.expectEqual(dialog.Kind.open_file, ACTIONS[0].kind);
    try std.testing.expectEqual(dialog.Kind.open_folder, ACTIONS[1].kind);
    try std.testing.expectEqual(dialog.Kind.save_file, ACTIONS[2].kind);
    // A save target has exactly one answer, so `multiple` is meaningless
    // there; `Kind.allowsMultiple` is what the backend consults.
    try std.testing.expect(dialog.Kind.open_file.allowsMultiple());
    try std.testing.expect(!dialog.Kind.save_file.allowsMultiple());
    // Ids are element ids, so they must be distinct.
    for (ACTIONS, 0..) |a, i| {
        for (ACTIONS[0..i]) |prev| try std.testing.expect(!std.mem.eql(u8, a.id, prev.id));
    }
}
