//! The AppKit panel's behaviour, as PURE data.
//!
//! `mac/file_dialog.zig` calls `NSOpenPanel` through the shim; THIS file
//! decides what to ask it. The split is the same one the rest of the macOS
//! backend uses — `mac/keymap.zig`, `mac/adapter.zig`, `mac/present.zig` are
//! all pure and all in the cross-platform parity suite, and `mac/window.zig`
//! is the one that talks to AppKit — and it exists for the same reason:
//! a wrong answer here is a file dialog that opens in the wrong place, and no
//! amount of staring at a screenshot tells you whether Cancel was reported as
//! a selection.
//!
//! ## The one decision that really needs a test
//!
//! `NSModalResponse` has five values and they are NOT booleans:
//!
//!   Stop = 0, OK = 1, Cancel = 2, Continue = 3, Abort = 4
//!
//! So "OK" is 1 and "Cancel" is **2** — the opposite of the order they are
//! usually written in. Swap those two and every cancelled dialog reports a
//! selection of nothing, and every real selection reports a cancel: the
//! application looks like it is working and is doing the exact opposite, with
//! no error anywhere. `statusForResponse` exists so that mapping is one
//! tested function instead of an `if` in a file nobody opens on Linux.
const std = @import("std");
const contract = @import("../core/file_dialog_contract.zig");

/// `NSModalResponse`, named. The values are Apple's; the names are ours, and
/// they are the whole point — `continue_` carries a trailing underscore
/// because the word is a keyword.
pub const Response = enum(u32) {
    stop = 0,
    ok = 1,
    cancel = 2,
    continue_ = 3,
    abort = 4,
    /// A value AppKit has not defined yet. Treated as "neither", which is the
    /// safe direction: a response nobody recognises must not be reported as a
    /// selection.
    _,

    /// What this modal answer means to the toolkit.
    pub fn toStatus(self: Response) contract.Status {
        return switch (self) {
            .ok => .selected,
            // Cancel and Stop are both "the user did not give us anything",
            // and both are a normal outcome rather than a failure.
            .cancel, .stop => .cancelled,
            // Continue/Abort mean the panel is being driven by something else
            // (a sheet, an accessory view). Not a selection, not a cancel.
            else => .other,
        };
    }
};

/// What the panel must be told to allow, derived from the caller's `Options`.
///
/// A struct of plain booleans rather than an AppKit type, because this file
/// cannot see AppKit: that is the whole point of the split.
pub const PanelConfig = struct {
    /// The panel picks files. False for a folder-only request, which is what
    /// makes it a directory chooser instead of a file chooser that can also
    /// pick directories.
    can_choose_files: bool,
    /// The panel picks directories.
    can_choose_directories: bool,
    /// The panel accepts more than one. AppKit's `allowsMultipleSelection`.
    allows_multiple: bool,
    /// The panel can create a file that does not exist yet — the save case.
    can_create_files: bool,
    /// The title to show, already defaulted.
    title: []const u8,
    /// The directory to open in, or null for AppKit's own default.
    directory: ?[]const u8,
    /// The file name to pre-fill, for a save.
    file_name: ?[]const u8,
    /// The label on the confirming button ("Save", "Open", …), or null for the
    /// platform's own wording.
    prompt: ?[]const u8,
};

/// Translate `Options` into what the panel should be asked for.
///
/// The three cases that are not one-to-one with the platform's own settings
/// are spelled out here rather than at the call site, because each of them is
/// a thing the caller asked for in one word and AppKit expresses in two:
///
///  - a FOLDER is a panel that cannot choose files. Not a file panel that can
///    also choose directories: that one lets the user pick a .txt and call it
///    a folder, and the application then fails much later with a path that is
///    not a directory.
///  - a SAVE is a file panel that may create. `canCreateFiles` is what makes
///    the "navigate into a folder that does not exist" case work at all.
///  - MULTIPLE is meaningless for a save target, exactly as it is on the
///    portal — one path is what a write target means.
pub fn configFor(opts: contract.Options) PanelConfig {
    const folder = opts.kind == .open_folder;
    return .{
        .can_choose_files = !folder,
        .can_choose_directories = folder,
        .allows_multiple = opts.multiple and opts.kind.allowsMultiple(),
        .can_create_files = opts.kind == .save_file,
        .title = if (opts.title.len != 0) opts.title else opts.kind.defaultTitle(),
        .directory = opts.current_folder,
        .file_name = if (opts.kind == .save_file) opts.current_name else null,
        .prompt = if (opts.accept_label.len != 0) opts.accept_label else null,
    };
}

/// Map a raw `NSModalResponse` (an int from the shim) to a toolkit `Status`.
///
/// The integer arrives from C, so the enum conversion cannot be exhaustive —
/// hence the `_` arm in `Response`, and hence this function existing at all.
pub fn statusForResponse(raw: i32) contract.Status {
    if (raw < 0) return .other;
    const value: u32 = @intCast(raw);
    return switch (std.enums.fromInt(Response, value) orelse return .other) {
        .ok => .selected,
        .cancel, .stop => .cancelled,
        else => .other,
    };
}

/// One `NSOpenPanelFilter` argument pair, ready for the shim.
///
/// AppKit wants (name, patterns) and the patterns are a comma-separated list
/// in ONE string — so the array a caller passes has to be flattened before it
/// crosses into C, and the flattening is where a pattern quietly loses its
/// comma. `filterSpecs` is the tested version of that flattening.
pub const PanelFilter = struct {
    name: []const u8,
    /// The patterns joined with commas, which is the format AppKit parses.
    patterns: []const u8,
};

/// The scratch space a caller needs to flatten filters into `PanelFilter`s.
///
/// Sized for the shapes a real application uses — a handful of filters, a
/// handful of patterns each — and a caller that needs more than this gets a
/// null back and a list that is missing the filters it did not fit, rather
/// than a dialog with a truncated filter list and no way to tell.
/// How many filters the scratch holds — a named constant, because the caller
/// sizes an array by it.
pub const max_filters = 16;

pub const FilterScratch = struct {
    specs: [max_filters][128]u8 = undefined,
    patterns: [max_filters][256]u8 = undefined,
    out: [max_filters]PanelFilter = undefined,
    len: usize = 0,
};

/// Flatten `filters` into `scratch`, or return null when they do not fit.
///
/// Returns borrowed strings that live in `scratch`, so the caller must use
/// them before the next call — which is the lifetime of a `NSOpenPanel`
/// configuration that is built, used and dropped inside one function.
pub fn flattenFilters(filters: []const contract.Filter, scratch: *FilterScratch) ?[]const PanelFilter {
    if (filters.len > scratch.out.len) return null;
    scratch.len = 0;
    for (filters) |filter| {
        if (scratch.len >= scratch.out.len) return null;

        // The patterns first: they are the variable-length part, and they are
        // what the buffer is really for.
        var total: usize = 0;
        for (filter.rules, 0..) |rule, i| {
            if (i != 0) {
                if (total + 1 > scratch.patterns[scratch.len].len) return null;
                scratch.patterns[scratch.len][total] = ',';
                total += 1;
            }
            if (total + rule.pattern.len > scratch.patterns[scratch.len].len) return null;
            @memcpy(scratch.patterns[scratch.len][total..][0..rule.pattern.len], rule.pattern);
            total += rule.pattern.len;
        }
        if (filter.name.len > scratch.specs[scratch.len].len) return null;
        @memcpy(scratch.specs[scratch.len][0..filter.name.len], filter.name);

        scratch.out[scratch.len] = .{
            .name = scratch.specs[scratch.len][0..filter.name.len],
            .patterns = scratch.patterns[scratch.len][0..total],
        };
        scratch.len += 1;
    }
    return scratch.out[0..scratch.len];
}

// ---------------------------------------------------------------------------
// Tests. These run in the cross-platform parity suite, on every OS, because
// this file imports nothing platform-specific — which is the only reason a
// macOS decision can be checked from a Linux runner.
// ---------------------------------------------------------------------------

test "a folder request is a panel that cannot choose files" {
    const config = configFor(.{ .kind = .open_folder });
    try std.testing.expect(!config.can_choose_files);
    try std.testing.expect(config.can_choose_directories);
    try std.testing.expect(!config.can_create_files);
}

test "a file request is a panel that cannot choose directories" {
    // The distinction that matters: NOT a file panel that can also pick
    // directories, which would let the user return a .txt where a folder was
    // asked for.
    const config = configFor(.{ .kind = .open_file });
    try std.testing.expect(config.can_choose_files);
    try std.testing.expect(!config.can_choose_directories);
    try std.testing.expect(!config.can_create_files);
}

test "a save target may create the file it names" {
    const config = configFor(.{ .kind = .save_file, .current_name = "notes.txt" });
    try std.testing.expect(config.can_choose_files);
    try std.testing.expect(config.can_create_files);
    try std.testing.expectEqualStrings("notes.txt", config.file_name.?);
}

test "multiple reaches the panel for an open, and not for a save" {
    try std.testing.expect(configFor(.{ .kind = .open_file, .multiple = true }).allows_multiple);
    try std.testing.expect(configFor(.{ .kind = .open_folder, .multiple = true }).allows_multiple);
    try std.testing.expect(!configFor(.{ .kind = .save_file, .multiple = true }).allows_multiple);
}

test "an empty title falls back to the kind's, and an explicit one wins" {
    try std.testing.expectEqualStrings("Open Folder", configFor(.{ .kind = .open_folder }).title);
    try std.testing.expectEqualStrings(
        "Choose a workspace",
        configFor(.{ .kind = .open_folder, .title = "Choose a workspace" }).title,
    );
}

test "a file name is only a save target's business" {
    // Sending one to an open panel is a no-op AppKit ignores; sending a
    // folder it did not ask for would pre-fill a name the user then has to
    // delete.
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        configFor(.{ .kind = .open_file, .current_name = "x.txt" }).file_name,
    );
}

test "an accept label only becomes a prompt when there is one" {
    try std.testing.expectEqual(@as(?[]const u8, null), configFor(.{}).prompt);
    try std.testing.expectEqualStrings("Import", configFor(.{ .accept_label = "Import" }).prompt.?);
}

test "OK is 1 and Cancel is 2 — the order they are NOT written in" {
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(Response.ok));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(Response.cancel));
    try std.testing.expectEqual(contract.Status.selected, statusForResponse(1));
    try std.testing.expectEqual(contract.Status.cancelled, statusForResponse(2));
}

test "Stop is a cancel, and everything else is neither" {
    try std.testing.expectEqual(contract.Status.cancelled, statusForResponse(0));
    try std.testing.expectEqual(contract.Status.other, statusForResponse(3));
    try std.testing.expectEqual(contract.Status.other, statusForResponse(4));
    // A value nobody has defined must never be read as a selection.
    try std.testing.expectEqual(contract.Status.other, statusForResponse(99));
    try std.testing.expectEqual(contract.Status.other, statusForResponse(-1));
}

test "filters flatten to comma-separated patterns, names kept" {
    var scratch: FilterScratch = .{};
    const filters = [_]contract.Filter{
        .{
            .name = "Images",
            .rules = &.{
                .{ .pattern = "*.png" },
                .{ .pattern = "*.jpg" },
            },
        },
        .{ .name = "All files", .rules = &.{.{ .pattern = "*" }} },
    };
    const flat = flattenFilters(&filters, &scratch) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(@as(usize, 2), flat.len);
    try std.testing.expectEqualStrings("Images", flat[0].name);
    // Comma-separated, in order, with no space and no trailing comma.
    try std.testing.expectEqualStrings("*.png,*.jpg", flat[0].patterns);
    try std.testing.expectEqualStrings("All files", flat[1].name);
    try std.testing.expectEqualStrings("*", flat[1].patterns);
}

test "a filter with no rules flattens to an empty pattern list" {
    // Not a null and not a crash: AppKit shows the filter with nothing to
    // match, which is what the caller asked for by supplying no rules.
    var scratch: FilterScratch = .{};
    const filters = [_]contract.Filter{.{ .name = "Everything" }};
    const flat = flattenFilters(&filters, &scratch) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), flat.len);
    try std.testing.expectEqualStrings("Everything", flat[0].name);
    try std.testing.expectEqualStrings("", flat[0].patterns);
}

test "no filters at all is an empty list, not a failure" {
    var scratch: FilterScratch = .{};
    const flat = flattenFilters(&.{}, &scratch) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), flat.len);
}

test "more filters than the scratch holds is a null, not a truncated dialog" {
    var scratch: FilterScratch = .{};
    var many: [17]contract.Filter = undefined;
    for (&many) |*f| f.* = .{ .name = "f", .rules = &.{.{ .pattern = "*" }} };
    try std.testing.expectEqual(@as(?[]const PanelFilter, null), flattenFilters(&many, &scratch));
}

test "a pattern too long for the scratch is refused rather than truncated" {
    // Truncation is the failure mode that matters: a half-written glob matches
    // nothing, so the dialog silently stops offering that filter and the user
    // concludes the file type is not supported.
    var scratch: FilterScratch = .{};
    const long = "x" ** 300; // one byte longer than the buffer allows
    const filters = [_]contract.Filter{.{ .name = "Big", .rules = &.{.{ .pattern = long }} }};
    try std.testing.expectEqual(@as(?[]const PanelFilter, null), flattenFilters(&filters, &scratch));
}
