// The screen's state as a VALUE: everything a dialog can answer, and the machine that remembers the last answer.
const std = @import("std");
const glinlandui = @import("glinlandui");

const dialog = glinlandui.file_dialog;

// Everything a dialog can answer, folded into one flat union so no call site has to tell a Status from an Error.
pub const Outcome = union(enum) {
    idle,
    selected: Selected,
    cancelled,
    unsupported,
    no_session_bus,
    no_portal,
    portal_error,
    timed_out,

    // A confirmed selection, reduced to what a status bar can honestly show.
    pub const Selected = struct {
        path: []const u8,
        count: usize,
    };

    // Only the fixed lines live here; `selected` needs a buffer, so `Machine.line` owns that arm and this one returns "".
    pub fn line(self: Outcome) []const u8 {
        return switch (self) {
            .idle => "Nothing asked yet. Pick one of the three.",
            .selected => "",
            // Deliberately calm, and deliberately not the word "error": Escape is a decision, not a malfunction.
            .cancelled => "Cancelled — nothing was chosen.",
            .unsupported => "No file dialog on this platform.",
            .no_session_bus => "No D-Bus session bus. Is this a desktop session?",
            .no_portal => "No desktop portal installed (xdg-desktop-portal).",
            .portal_error => "The portal refused the request.",
            .timed_out => "Timed out waiting for the dialog.",
        };
    }

    // Whether the status bar should look like something went wrong — `cancelled` is deliberately not in this set.
    pub fn isProblem(self: Outcome) bool {
        return switch (self) {
            .idle, .selected, .cancelled => false,
            .unsupported, .no_session_bus, .no_portal, .portal_error, .timed_out => true,
        };
    }
};

// The app's state: no window, no Clay, no backend — just the answer to the last question, as a value a test can assert.
pub const Machine = struct {
    outcome: Outcome = .idle,

    // Kept even for a cancellation, because "you cancelled the folder picker" is a different conversation from Save As.
    last_kind: dialog.Kind = .open_file,

    // `Selection.paths` is freed by `Selection.deinit`, so the path the UI keeps is COPIED here instead of borrowed.
    path_buf: [1024]u8 = undefined,
    path_len: usize = 0,

    // `line` composes into a field rather than a local, so the slice stays valid for the draw that reads it after it returns.
    line_buf: [1200]u8 = undefined,

    // The folder the next dialog starts in: a dialog that reopens in $HOME every time is correct and infuriating.
    pub fn folderHint(self: *const Machine) ?[]const u8 {
        const path = switch (self.outcome) {
            .selected => |s| s.path,
            else => return null,
        };
        const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return null;
        // No leading slash means a bare filename, which is not a path at all; a leading "/" is the root, which is a useless hint.
        if (slash == 0) return null;
        return path[0..slash];
    }

    // The status-bar text, composed: this owns the `selected` arm, which has to say WHICH dialog answered and HOW MANY came back.
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

    // Fold a successful call in, taking the `Selection` BY VALUE so the caller can free it in any order.
    pub fn fromSelection(self: *Machine, kind: dialog.Kind, selection: dialog.Selection) void {
        self.last_kind = kind;
        switch (selection.status) {
            .selected => {
                const path = selection.first() orelse {
                    // `.selected` with no path contradicts the contract, and a UI that indexes an empty slice is a crash in someone else's app.
                    self.outcome = .portal_error;
                    return;
                };
                const n = @min(path.len, self.path_buf.len);
                @memcpy(self.path_buf[0..n], path[0..n]);
                self.path_len = n;
                // The COUNT is kept even though only the first path is: silently dropping N-1 picks is a lie told by omission.
                self.outcome = .{ .selected = .{
                    .path = self.path_buf[0..n],
                    .count = selection.paths.len,
                } };
            },
            .cancelled => self.outcome = .cancelled,
            .other => self.outcome = .portal_error,
        }
    }

    // Fold a failed call in, matched on the NAME because a desktop backend's error set is inferred: naming a member it lacks is a compile error, and `else` cannot rescue it.
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
            // The honest catch-all: the five names above are the ones a user can act on, and everything else is "the dialog could not be completed".
            .portal_error;
    }
};

// One of the three questions the screen offers: what its button says, and which dialog it asks for.
pub const Action = struct {
    id: []const u8,
    label: []const u8,
    kind: dialog.Kind,
};

// The buttons in draw order, so the view and the click that answers it agree on which button "the third" is.
pub const ACTIONS = [_]Action{
    .{ .id = "dlg-open-file", .label = "Open File...", .kind = .open_file },
    .{ .id = "dlg-open-folder", .label = "Open Folder...", .kind = .open_folder },
    .{ .id = "dlg-save-file", .label = "Save As...", .kind = .save_file },
};

// The filter list this example sends — best effort on Linux, where a portal that refuses it gets a second, plainer request instead of no dialog.
const IMAGE_FILTERS = [_]dialog.Filter{
    .{ .name = "Images", .rules = &.{
        .{ .pattern = "*.png" },
        .{ .pattern = "*.jpg" },
        .{ .pattern = "*.jpeg" },
        .{ .pattern = "*.webp" },
    } },
    .{ .name = "All files", .rules = &.{.{ .pattern = "*" }} },
};

// The `Options` this example sends for one `Kind` — one table, because the headless check prints the same requests the window builds.
pub fn optionsFor(kind: dialog.Kind, folder: ?[]const u8) dialog.Options {
    var options = dialog.Options{ .kind = kind, .current_folder = folder };
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
            // `multiple` stays off: a save target is a single path by definition — see `Kind.allowsMultiple`.
            options.current_name = "untitled.png";
        },
    }
    return options;
}

// ---- tests ---------------------------------------------------------------------------------------------------
// Part of the cross-platform PARITY suite: under `builtin.is_test` this module resolves to the PORTABLE backend, over the same `Status`/`Selection` types.

test "a cancelled dialog is reported calmly, not as a problem" {
    var m = Machine{};
    // The user pressed Escape. This is the single most important line in the example, and the one most integrations get wrong.
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

    // The allocator is watching: had `fromSelection` kept the borrowed slice, this read would be a use-after-free.
    try std.testing.expectEqualStrings("file: /home/u/Pictures/cat (1).png", m.line());
}

test "a selection with no path is a problem, not an index panic" {
    // `.selected` with nothing in it contradicts the contract, and it is exactly what a careless backend produces.
    var m = Machine{};
    m.fromSelection(.open_file, .{ .status = .selected, .paths = &.{} });
    try std.testing.expectEqual(Outcome{ .portal_error = {} }, m.outcome);
    try std.testing.expect(m.outcome.isProblem());
}

test "each error says something a user can act on" {
    // Held as `anyerror` rather than `dialog.Error`: a desktop backend's set is inferred, so a `dialog.Error` value cannot even be written here.
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
        // No two failures may share a line: "the dialog failed" for five different problems is the message this API exists to avoid.
        try std.testing.expect(case.want.line().len > 0);
    }
}

test "an error the contract never named still lands somewhere honest" {
    // A backend may return failures outside the five named ones, so the catch-all has to produce a line rather than silence.
    var m = Machine{};
    m.fromError(error.OutOfMemory);
    try std.testing.expectEqual(Outcome{ .portal_error = {} }, m.outcome);
    try std.testing.expect(m.outcome.isProblem());
}

test "the next dialog starts in the folder the last one came from" {
    var m = Machine{};
    // Nothing has been chosen, so the dialog opens wherever the backend decides.
    try std.testing.expectEqual(@as(?[]const u8, null), m.folderHint());

    m.fromSelection(.open_file, .{
        .status = .selected,
        .paths = @constCast(&[_][]const u8{"/home/u/Pictures/holiday/cat.png"}),
    });
    try std.testing.expectEqualStrings("/home/u/Pictures/holiday", m.folderHint().?);

    // A cancellation forgets it: the user said no, and the next dialog should not remember a choice they declined.
    m.fromSelection(.open_file, .{ .status = .cancelled });
    try std.testing.expectEqual(@as(?[]const u8, null), m.folderHint());

    // A bare filename is not a path, and "/" is not a useful hint — both would be sent as a `current_folder` to open.
    m.fromSelection(.open_file, .{ .status = .selected, .paths = @constCast(&[_][]const u8{"cat.png"}) });
    try std.testing.expectEqual(@as(?[]const u8, null), m.folderHint());
    m.fromSelection(.open_file, .{ .status = .selected, .paths = @constCast(&[_][]const u8{"/cat.png"}) });
    try std.testing.expectEqual(@as(?[]const u8, null), m.folderHint());
}

test "a folder pick reads as a folder, not as a file" {
    // The test that was missing, and its absence was a defect: a picked folder and a picked file are the same TYPE, so the question must travel with the answer.
    const alloc = std.testing.allocator;
    const path = try alloc.dupe(u8, "/home/u/Pictures");
    const paths = try alloc.alloc([]const u8, 1);
    paths[0] = path;

    var m = Machine{};
    const selection = dialog.Selection{ .status = .selected, .paths = paths };
    m.fromSelection(.open_folder, selection);
    selection.deinit(alloc);

    try std.testing.expectEqualStrings("folder: /home/u/Pictures", m.line());
    // A folder selection is a directory, so it is its own `current_folder` for next time — not the parent, which is the bug `folderHint` avoids for files.
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
    // A save target has exactly one answer by definition, so a count above 1 is something no backend should produce.
    try std.testing.expect(!dialog.Kind.save_file.allowsMultiple());
}

test "a multi-file selection says how many, not just the first" {
    // `open_file` is opened with `multiple = true` here, so this is an ordinary outcome — and showing only the first path makes the user believe the others were lost.
    const alloc = std.testing.allocator;
    const names = [_][]const u8{ "a.png", "b.png", "c.png" };
    const paths = try alloc.alloc([]const u8, names.len);
    for (names, 0..) |n, i| paths[i] = try alloc.dupe(u8, n);

    var m = Machine{};
    const selection = dialog.Selection{ .status = .selected, .paths = paths };
    m.fromSelection(.open_file, selection);

    // Counted BEFORE the free, and readable after it: the count is the thing that must survive, because the paths do not.
    try std.testing.expectEqual(@as(usize, 3), m.outcome.selected.count);
    selection.deinit(alloc);

    try std.testing.expectEqualStrings("3 files chosen, first: a.png", m.line());
    try std.testing.expect(!m.outcome.isProblem());
}

test "a cancelled folder dialog is still a cancellation, not a problem" {
    // The three cancellations are the same STATUS but not the same event, and `.cancelled` carries no kind of its own.
    var m = Machine{};
    for ([_]dialog.Kind{ .open_file, .open_folder, .save_file }) |kind| {
        m.fromSelection(kind, .{ .status = .cancelled });
        try std.testing.expectEqual(Outcome{ .cancelled = {} }, m.outcome);
        try std.testing.expect(!m.outcome.isProblem());
        try std.testing.expectEqualStrings("Cancelled — nothing was chosen.", m.line());
        // The kind is remembered even though nothing was chosen, so the app can say which dialog the user backed out of.
        try std.testing.expectEqual(kind, m.last_kind);
    }
}

test "the filter list is one that a portal can actually be asked for" {
    try std.testing.expectEqual(@as(usize, 2), IMAGE_FILTERS.len);
    for (IMAGE_FILTERS) |f| {
        try std.testing.expect(f.name.len > 0);
        for (f.rules) |r| try std.testing.expect(r.pattern.len > 0);
    }
    // The first group is images, and the last is the catch-all — the order a user expects to see them in.
    try std.testing.expectEqualStrings("*.png", IMAGE_FILTERS[0].rules[0].pattern);
    try std.testing.expectEqualStrings("*", IMAGE_FILTERS[1].rules[0].pattern);
}

test "the three buttons ask for three different portal methods" {
    try std.testing.expectEqual(@as(usize, 3), ACTIONS.len);
    try std.testing.expectEqual(dialog.Kind.open_file, ACTIONS[0].kind);
    try std.testing.expectEqual(dialog.Kind.open_folder, ACTIONS[1].kind);
    try std.testing.expectEqual(dialog.Kind.save_file, ACTIONS[2].kind);
    // A save target has exactly one answer, so `multiple` is meaningless there; `Kind.allowsMultiple` is what the backend consults.
    try std.testing.expect(dialog.Kind.open_file.allowsMultiple());
    try std.testing.expect(!dialog.Kind.save_file.allowsMultiple());
    // Ids are element ids, so they must be distinct.
    for (ACTIONS, 0..) |a, i| {
        for (ACTIONS[0..i]) |prev| try std.testing.expect(!std.mem.eql(u8, a.id, prev.id));
    }
}
