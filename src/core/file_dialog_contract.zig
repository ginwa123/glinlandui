//! The portable file-dialog contract: the types every backend speaks.
const std = @import("std");

/// What to ask the user for.
pub const Kind = enum {
    /// Pick an existing file.
    open_file,
    /// Pick an existing directory.
    open_folder,
    /// Pick a path to write to. The file need not exist.
    save_file,

    /// The window title the dialog should carry when the caller supplied none.
    pub fn defaultTitle(self: Kind) []const u8 {
        return switch (self) {
            .open_file => "Open File",
            .open_folder => "Open Folder",
            .save_file => "Save File",
        };
    }

    /// Whether asking for more than one selection is meaningful.
    pub fn allowsMultiple(self: Kind) bool {
        return self != .save_file;
    }
};

/// One pattern inside a filter, with an optional human label.
pub const Rule = struct {
    label: []const u8 = "",
    /// A glob such as `"*.png"`.
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

/// Everything a caller can ask for.
pub const Options = struct {
    kind: Kind = .open_file,
    /// Dialog title. Empty means "use `kind.defaultTitle()`".
    title: []const u8 = "",
    /// The filter list shown in the dialog.
    filters: []const Filter = &.{},
    /// Label for the confirming button, e.g. "Import".
    accept_label: []const u8 = "",
    /// Let the user select more than one.
    multiple: bool = false,
    /// Present the dialog as modal to the requesting window.
    modal: bool = true,
    /// Where to start.
    current_folder: ?[]const u8 = null,
    /// Pre-filled name, for `save_file`.
    current_name: ?[]const u8 = null,
    /// Give up after this many milliseconds.
    timeout_ms: ?u32 = null,
};

/// How the dialog ended.
pub const Status = enum {
    /// The user confirmed. `Selection.paths` holds at least one path.
    selected,
    /// The user dismissed the dialog.
    cancelled,
    /// The dialog closed for some other reason — the portal failed, or a backend-specific "no".
    other,

    pub fn isSelected(self: Status) bool {
        return self == .selected;
    }
};

/// The answer: what the user picked, or that they did not.
pub const Selection = struct {
    status: Status,
    /// Filesystem paths, empty unless `status == .selected`.
    paths: []const []const u8 = &.{},

    /// The first path, or null when nothing was selected.
    pub fn first(self: Selection) ?[]const u8 {
        return if (self.paths.len == 0) null else self.paths[0];
    }

    /// Release the paths.
    pub fn deinit(self: Selection, alloc: std.mem.Allocator) void {
        for (self.paths) |p| alloc.free(p);
        alloc.free(self.paths);
    }
};

/// Turn a filesystem path into a `file://` URI.
pub fn pathToFileUri(path: []const u8, out: []u8) ![]const u8 {
    const prefix = "file://";
    if (out.len < prefix.len) return error.NoSpaceLeft;
    @memcpy(out[0..prefix.len], prefix);
    var i: usize = prefix.len;
    for (path) |ch| {
        const unreserved = (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9') or
            ch == '-' or ch == '.' or ch == '_' or ch == '~' or ch == '/';
        if (unreserved) {
            if (i >= out.len) return error.NoSpaceLeft;
            out[i] = ch;
            i += 1;
        } else {
            if (i + 3 > out.len) return error.NoSpaceLeft;
            out[i] = '%';
            out[i + 1] = hexUpperDigit(ch >> 4);
            out[i + 2] = hexUpperDigit(ch & 0x0f);
            i += 3;
        }
    }
    return out[0..i];
}

/// Turn a `file://` URI back into a path.
pub fn fileUriToPath(uri: []const u8, out: []u8) ![]const u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return error.UnsupportedScheme;
    var rest = uri[prefix.len..];
    // `file://host/path` is legal; the host is empty for every local file, and a non-empty one is not something a local path can express.
    if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
        if (slash != 0) return error.RemoteHost;
        rest = rest[slash..];
    }
    var n: usize = 0;
    var i: usize = 0;
    while (i < rest.len) {
        if (n >= out.len) return error.NoSpaceLeft;
        if (rest[i] == '%') {
            if (i + 2 >= rest.len) return error.BadValue;
            const hi = hexDigitValue(rest[i + 1]) orelse return error.BadValue;
            const lo = hexDigitValue(rest[i + 2]) orelse return error.BadValue;
            out[n] = hi * 16 + lo;
            n += 1;
            i += 3;
        } else {
            out[n] = rest[i];
            n += 1;
            i += 1;
        }
    }
    return out[0..n];
}

fn hexUpperDigit(v: u8) u8 {
    return if (v < 10) '0' + v else 'A' + (v - 10);
}

fn hexDigitValue(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Everything a backend can fail to do, in ONE error set.
pub const Error = error{
    /// This host has no file dialog wired up.
    Unsupported,
    /// Linux: there is no D-Bus session bus, so there is no portal to ask.
    NoSessionBus,
    /// Linux: the bus is there but nothing owns `org.freedesktop.portal.Desktop` — typically a Wayland session with no desktop portal installed, which is a.
    NoPortal,
    /// The backend could not talk to the service it found.
    PortalError,
    /// The dialog is still open when `timeout_ms` expires.
    Timeout,
};

// Tests

test "the default request is a single-file open with nothing else set" {
    const opts = Options{};
    try std.testing.expectEqual(Kind.open_file, opts.kind);
    try std.testing.expectEqual(@as(usize, 0), opts.filters.len);
    try std.testing.expectEqual(@as(?[]const u8, null), opts.current_folder);
    try std.testing.expectEqual(@as(?u32, null), opts.timeout_ms);
    // Modal by default, because a non-modal file chooser over an app that cannot process input while it is open reads as a hang.
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
    // The rule is a one-liner in each backend's encoder, and stating it here means the behaviour is asserted rather than assumed.
    const opts = Options{ .kind = .open_folder, .title = "Choose a workspace" };
    try std.testing.expectEqualStrings("Choose a workspace", opts.title);
}

test "a path with spaces and punctuation survives the URI round trip" {
    var uri_buf: [128]u8 = undefined;
    const uri = try pathToFileUri("/home/u/notes (final) #2.txt", &uri_buf);
    try std.testing.expectEqualStrings("file:///home/u/notes%20%28final%29%20%232.txt", uri);

    var path_buf: [128]u8 = undefined;
    const path = try fileUriToPath(uri, &path_buf);
    try std.testing.expectEqualStrings("/home/u/notes (final) #2.txt", path);
}

test "a non-ASCII byte is percent-encoded and comes back unchanged" {
    var uri_buf: [128]u8 = undefined;
    const uri = try pathToFileUri("/home/u/caf\xC3\xA9", &uri_buf);
    try std.testing.expectEqualStrings("file:///home/u/caf%C3%A9", uri);
    var path_buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("/home/u/caf\xC3\xA9", try fileUriToPath(uri, &path_buf));
}

test "a URI that is not a local file is an error, not a mangled path" {
    var buf: [64]u8 = undefined;
    try std.testing.expectError(error.UnsupportedScheme, fileUriToPath("http://example.com/x", &buf));
    try std.testing.expectError(error.RemoteHost, fileUriToPath("file://host/x", &buf));
    // A truncated escape is a corrupt URI, not a literal "%2".
    try std.testing.expectError(error.BadValue, fileUriToPath("file:///a%2", &buf));
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
