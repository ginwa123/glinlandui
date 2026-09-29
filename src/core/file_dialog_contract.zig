//! The portable file-dialog contract: the types every backend speaks.
//!
//! A file dialog is the first toolkit feature that is inherently a
//! SYSTEM dialog — on Linux the window belongs to another process, on macOS to
//! AppKit, in a browser to the page. What is portable is not the dialog but
//! the QUESTION and the ANSWER: "let the user pick a file / a folder / a save
//! target" in, and "here is what they picked, or they cancelled" out. That is
//! what this file defines, and it defines it in `core/` so a consumer writes
//! one `openFile(...)` and gets the same types on every host.
//!
//! ## Why `core/` and not a platform folder
//!
//! `src/core/window_contract.zig` is the precedent: the shared window API
//! lives in core, and each backend builds on it. This file is its twin. It is
//! pure Zig with no I/O, so it is in the cross-platform parity suite, and its
//! tests run identically on Linux, macOS and Windows.
//!
//! ## What the non-Linux backends do with it
//!
//! `core/file_dialog_portable.zig` implements the same functions and returns
//! `error.Unsupported`. That is the honest answer for a host with no portal,
//! and it is why the enum in `Status` has no "unavailable" member: an
//! unsupported platform is an error the CALLER must handle, while a
//! cancellation is a normal outcome that a UI should treat as a no-op.
const std = @import("std");

/// What to ask the user for.
pub const Kind = enum {
    /// Pick an existing file.
    open_file,
    /// Pick an existing directory. This is the "select folder" case, and it
    /// is a DIFFERENT portal method (`OpenDirectory`) rather than a flag on
    /// `open_file` — which is why it is a separate kind here rather than a
    /// `pick_folders: bool` option that some backends would honour and others
    /// ignore.
    open_folder,
    /// Pick a path to write to. The file need not exist.
    save_file,

    /// The window title the dialog should carry when the caller supplied none.
    /// Portable because every backend has some title to show, and a dialog
    /// that says "Open" in a file picker is the kind of detail a user notices.
    pub fn defaultTitle(self: Kind) []const u8 {
        return switch (self) {
            .open_file => "Open File",
            .open_folder => "Open Folder",
            .save_file => "Save File",
        };
    }

    /// Whether asking for more than one selection is meaningful. A save
    /// target is a single path by definition, and sending `multiple=true` for
    /// one is a request no backend can honour.
    pub fn allowsMultiple(self: Kind) bool {
        return self != .save_file;
    }
};

/// One pattern inside a filter, with an optional human label.
///
/// The portal models a filter as `(name, [(label, pattern)])`. Almost nobody
/// uses the label — `*.png` is a fine thing to print — so `label` defaults to
/// empty and backends print the pattern.
pub const Rule = struct {
    label: []const u8 = "",
    /// A glob such as `"*.png"`. Not a regex and not a path: the portal
    /// matches it against the file NAME.
    pattern: []const u8,

    /// What a backend should print for this rule.
    pub fn display(self: Rule) []const u8 {
        return if (self.label.len != 0) self.label else self.pattern;
    }
};

/// A named group of rules — "Images", "Text", "All files".
pub const Filter = struct {
    name: []const u8,
    rules: []const Rule = &.{},
};

/// Everything a caller can ask for. One struct, not a dozen parameters,
/// because the alternative is a call that grows a parameter per feature and
/// is unreadable at the call site.
pub const Options = struct {
    kind: Kind = .open_file,
    /// Dialog title. Empty means "use `kind.defaultTitle()`".
    title: []const u8 = "",
    /// The filter list shown in the dialog. Empty means the backend's own
    /// default, which for a file chooser is usually "all files".
    filters: []const Filter = &.{},
    /// Label for the confirming button, e.g. "Import".
    accept_label: []const u8 = "",
    /// Let the user select more than one. Ignored for `save_file`, which
    /// `Kind.allowsMultiple` says has exactly one answer.
    multiple: bool = false,
    /// Present the dialog as modal to the requesting window. A file chooser
    /// that is not modal lets the user keep clicking a window that cannot
    /// respond, which reads as a hang.
    modal: bool = true,
    /// Where to start. A filesystem path, not a URI: every host has paths, and
    /// converting to whatever the backend wants is the backend's job.
    current_folder: ?[]const u8 = null,
    /// Pre-filled name, for `save_file`.
    current_name: ?[]const u8 = null,
    /// Give up after this many milliseconds. Null waits as long as the user
    /// takes, which is the correct default for a dialog: a file chooser is
    /// modal, so nothing is lost by waiting, and a timeout that fires while
    /// the user is typing a long path is worse than no timeout at all.
    timeout_ms: ?u32 = null,
};

/// How the dialog ended.
pub const Status = enum {
    /// The user confirmed. `Selection.paths` holds at least one path.
    selected,
    /// The user dismissed the dialog. A NORMAL outcome, not a failure: an app
    /// that treats it as an error shows an error message for something the
    /// user did on purpose.
    cancelled,
    /// The dialog closed for some other reason — the portal failed, or a
    /// backend-specific "no". Distinct from `cancelled` so an app can log it
    /// without bothering the user.
    other,

    pub fn isSelected(self: Status) bool {
        return self == .selected;
    }
};

/// The answer: what the user picked, or that they did not.
pub const Selection = struct {
    status: Status,
    /// Filesystem paths, empty unless `status == .selected`. Borrowed from
    /// the allocator the call was given, so `deinit` releases the whole set.
    paths: []const []const u8 = &.{},

    /// The first path, or null when nothing was selected. The overwhelmingly
    /// common case (a save target, one file), and spelled out here so every
    /// app does not re-implement "empty means null".
    pub fn first(self: Selection) ?[]const u8 {
        return if (self.paths.len == 0) null else self.paths[0];
    }

    /// Release the paths. No-op for the empty (cancelled) case, so a caller
    /// can `defer selection.deinit(...)` unconditionally.
    pub fn deinit(self: Selection, alloc: std.mem.Allocator) void {
        for (self.paths) |p| alloc.free(p);
        alloc.free(self.paths);
    }
};

/// Everything a backend can fail to do, in ONE error set.
///
/// The reason it is here rather than per backend: a consumer writes
/// `catch |err| switch (err) { error.Unsupported => ..., else => ... }` and
/// that switch has to mean the same thing on every host. A backend may also
/// return its own I/O errors (OutOfMemory, the OS's own socket errors); those
/// are outside this set on purpose, because a caller cannot do anything
/// platform-specific with them.
pub const Error = error{
    /// This host has no file dialog wired up. The non-Linux backends return
    /// exactly this, and it is the one error a UI is expected to handle by
    /// hiding a button.
    Unsupported,
    /// Linux: there is no D-Bus session bus, so there is no portal to ask.
    NoSessionBus,
    /// Linux: the bus is there but nothing owns
    /// `org.freedesktop.portal.Desktop` — typically a Wayland session with no
    /// desktop portal installed, which is a real and common configuration
    /// (a bare `weston` with no shell, for instance).
    NoPortal,
    /// The backend could not talk to the service it found. Distinct from
    /// `NoPortal` so a log says "the portal answered with an error" rather
    /// than "there is no portal".
    PortalError,
    /// The dialog is still open when `timeout_ms` expires.
    Timeout,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "the default request is a single-file open with nothing else set" {
    const opts = Options{};
    try std.testing.expectEqual(Kind.open_file, opts.kind);
    try std.testing.expectEqual(@as(usize, 0), opts.filters.len);
    try std.testing.expectEqual(@as(?[]const u8, null), opts.current_folder);
    try std.testing.expectEqual(@as(?u32, null), opts.timeout_ms);
    // Modal by default, because a non-modal file chooser over an app that
    // cannot process input while it is open reads as a hang.
    try std.testing.expect(opts.modal);
    try std.testing.expect(!opts.multiple);
}

test "each kind has a title, and only a save target is single by definition" {
    try std.testing.expectEqualStrings("Open File", Kind.open_file.defaultTitle());
    try std.testing.expectEqualStrings("Open Folder", Kind.open_folder.defaultTitle());
    try std.testing.expectEqualStrings("Save File", Kind.save_file.defaultTitle());

    try std.testing.expect(Kind.open_file.allowsMultiple());
    try std.testing.expect(Kind.open_folder.allowsMultiple());
    try std.testing.expect(!Kind.save_file.allowsMultiple());
}

test "a rule prints its label, or its pattern when it has none" {
    try std.testing.expectEqualStrings("*.png", (Rule{ .pattern = "*.png" }).display());
    try std.testing.expectEqualStrings(
        "PNGs",
        (Rule{ .label = "PNGs", .pattern = "*.png" }).display(),
    );
}

test "an explicit title wins over the kind's default" {
    // The rule is a one-liner in each backend's encoder, and stating it here
    // means the behaviour is asserted rather than assumed.
    const opts = Options{ .kind = .open_folder, .title = "Choose a workspace" };
    try std.testing.expectEqualStrings("Choose a workspace", opts.title);
}

test "a cancelled selection has no paths, and first() says so" {
    const sel = Selection{ .status = .cancelled };
    try std.testing.expectEqual(@as(?[]const u8, null), sel.first());
    try std.testing.expect(!sel.status.isSelected());
    // deinit on the empty case must be safe: apps call it unconditionally.
    sel.deinit(std.testing.allocator);
}

test "a selected selection hands back its first path" {
    const alloc = std.testing.allocator;
    const a = try alloc.dupe(u8, "/home/u/a.txt");
    const paths = try alloc.alloc([]const u8, 1);
    paths[0] = a;
    const sel = Selection{ .status = .selected, .paths = paths };
    defer sel.deinit(alloc);
    try std.testing.expectEqualStrings("/home/u/a.txt", sel.first().?);
    try std.testing.expect(sel.status.isSelected());
}
