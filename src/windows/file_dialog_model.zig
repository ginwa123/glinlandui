//! The IFileDialog model, as PURE data.
//!
//! `windows/file_dialog.zig` creates a COM `IFileDialog` through the shim;
//! THIS file decides what to ask it. It is the same split as
//! `mac/file_dialog_model.zig` and for the same reason: a mistake in the
//! options is a dialog that opens in the wrong place, and the options are
//! exactly the part that can be checked from a Linux runner.
//!
//! ## What the model has to decide that the platform will not do for it
//!
//!  - **Which class to create.** `FileOpenDialog` vs `FileSaveDialog` is the
//!    kind; the rest are options on the same object. Picking the wrong one is
//!    not a subtle wrong answer: a save dialog with no `defaultPath` shows the
//!    user a *chooser* where they expected to type a name.
//!  - **The file-type index.** `SetFileTypes` is followed by
//!    `SetFileTypeIndex` with a 1-BASED index, which is off by one in the way
//!    that is invisible in review and obvious to a user: index 0 means "no
//!    filter" and 1 means the FIRST one. `selectedFilterIndex` here is
//!    0-based because that is how a caller would think, and this file is
//!    where the conversion is made and tested.
//!  - **The pick-folder option.** `FOS_PICKFOLDERS` is the only way to get a
//!    directory chooser, and it is mutually exclusive with the flag that lets
//!    the dialog return files — so it is a MODE here rather than a flag that
//!    can be combined with everything else.
const std = @import("std");
const contract = @import("../core/file_dialog_contract.zig");

/// `IFileDialog` dialog options, as the bit flags the platform defines.
///
/// Named rather than raw numbers so the shim header stays free of
/// `FILEOPENDIALOGOPTIONS` — and so the combinability rules are stated in one
/// place instead of at each call site.
pub const Options = packed struct(u32) {
    pick_folders: bool = false,
    must_exist: bool = false,
    force_filesystem: bool = false,
    allow_multiple: bool = false,
    no_change_dir: bool = true,
    path_must_exist: bool = false,
    file_must_exist: bool = false,
    create_prompt: bool = false,
    /// The platform's own bits are clear, so a name this model does not know
    /// yet is not silently turned into a random flag.
    _reserved: u24 = 0,

    pub fn toBits(self: Options) u32 {
        return @bitCast(self);
    }
};

/// The file-type index a caller means, 0-based. Negative means "let the
/// platform choose", which is the default and is not the same as "the first
/// filter".
pub const FilterChoice = union(enum) {
    none,
    /// 0-based. The conversion to the platform's 1-based index is below, and
    /// is tested.
    index: usize,
};

/// The class to create, which is also the kind of dialog.
pub const DialogClass = enum {
    open_file,
    open_folder,
    save_file,

    pub fn toContract(self: DialogClass) contract.Kind {
        return switch (self) {
            .open_file => .open_file,
            .open_folder => .open_folder,
            .save_file => .save_file,
        };
    }
};

/// Everything the shim needs, derived from `Options` plus the chosen dialog.
pub const Model = struct {
    class: DialogClass,
    options: Options,
    /// 1-based, exactly as the COM method wants it. 0 means "no selection",
    /// which is a real value and not the same as "the first filter".
    file_type_index: u32,
    /// Filter count, or 0 for "no SetFileTypes call at all" — passing an
    /// empty array would install a filter that matches nothing.
    filter_count: u32,
};

/// Translate the caller's `Options` into the dialog and the flags.
///
/// The three rules that are decisions rather than translations:
///
///  - a FOLDER sets `pick_folders` and nothing else. It also must NOT set
///    `file_must_exist`, because a directory dialog that insists on a
///    *file* answers "no" to the only thing it was opened for.
///  - a SAVE sets `path_must_exist` (the folder has to be real) and, when the
///    caller gave a name, not `file_must_exist` (the file is the thing being
///    created). Setting both is the classic Windows file dialog bug: the save
///    dialog refuses to save a new file.
///  - an OPEN sets `file_must_exist`, so the dialog cannot return something
///    that is not there.
pub fn modelFor(class: DialogClass, opts: contract.Options, filters: []const contract.Filter) Model {
    var options = Options{ .no_change_dir = true };

    switch (class) {
        .open_folder => {
            options.pick_folders = true;
            options.path_must_exist = true;
        },
        .open_file => {
            options.must_exist = true;
            options.file_must_exist = true;
            options.force_filesystem = true;
        },
        .save_file => {
            // The folder must exist; the file does not have to.
            options.path_must_exist = true;
            options.file_must_exist = false;
        },
    }

    if (opts.multiple and class != .save_file) options.allow_multiple = true;

    return .{
        .class = class,
        .options = options,
        .file_type_index = 0,
        // An empty filter array installs a filter that matches NOTHING, so the
        // count is what the shim branches on, not the pointer.
        .filter_count = if (filters.len == 0) 0 else @intCast(filters.len),
    };
}

/// The 1-based index `SetFileTypeIndex` wants, from a 0-based choice.
///
/// Zero means "do not call it at all", and the shim takes that as "let the
/// platform decide". That is why `FilterChoice.none` and an index of 0 have to
/// be distinguishable: they are the same call with opposite outcomes, and
/// passing 0 to `SetFileTypeIndex` silently selects the first filter.
pub fn fileTypeIndex(choice: FilterChoice, filter_count: usize) u32 {
    return switch (choice) {
        .none => 0,
        // Out of range is not clamped: a caller asking for filter 9 of 3 has a
        // bug, and clamping would hide it behind a dialog that quietly offers
        // the wrong types.
        .index => |i| if (i < filter_count) @intCast(i + 1) else 0,
    };
}

/// The `SIGDN_FILESYSPATH` form of a selection, which is a plain path — not a
/// URI, and not an `IShellItem`.
///
/// One reason the two desktop platforms share a codec and Windows does not
/// need it: `IFileDialog` hands back a filesystem path directly, so there is
/// no `file://` round trip here at all. A path containing a space arrives as a
/// path containing a space.
pub const PathStyle = enum {
    /// A `file://` URL: percent-encoded, and must be decoded.
    file_url,
    /// A filesystem path: used exactly as it arrives.
    verbatim,
};

/// Which form this platform's dialog returns.
pub const path_style: PathStyle = .verbatim;

/// The scratch a caller needs to flatten filters into the shim's
/// `COMDLG_FILTERSPEC`-shaped pair (a name and a semicolon-separated spec).
///
/// Windows wants `"*.png;*.jpg"` where AppKit wants `["*.png", "*.jpg"]` and
/// the portal wants a real array. Three spellings of the same idea, and the
/// separator is the one thing that is easy to leave as a comma and end up
/// with a dialog that offers no file types at all.
/// How many filters the scratch holds. A named constant rather than
/// `FilterScratch.out.len`, because the caller sizes an ARRAY by it and
/// reaching through a value's field to find a length is a compile error waiting
/// to happen.
pub const max_filters = 16;

pub const FilterScratch = struct {
    names: [max_filters][128]u8 = undefined,
    specs: [max_filters][256]u8 = undefined,
    out: [max_filters]Filter = undefined,
    len: usize = 0,
};

pub const Filter = struct {
    name: []const u8,
    /// Semicolon-separated, which is what `COMDLG_FILTERSPEC.pszSpec` parses.
    spec: []const u8,
};

/// Flatten `filters` into `scratch`, or return null when they do not fit.
///
/// As on macOS: too many filters, or a spec too long, is a null rather than a
/// truncated list. A half-written `*.pn` matches nothing, and a dialog that
/// silently offers the wrong file types is worse than one that admits it
/// could not build them.
pub fn flattenFilters(filters: []const contract.Filter, scratch: *FilterScratch) ?[]const Filter {
    if (filters.len > scratch.out.len) return null;
    scratch.len = 0;
    for (filters) |filter| {
        if (scratch.len >= scratch.out.len) return null;

        var total: usize = 0;
        for (filter.rules, 0..) |rule, i| {
            if (i != 0) {
                if (total + 1 > scratch.specs[scratch.len].len) return null;
                scratch.specs[scratch.len][total] = ';';
                total += 1;
            }
            if (total + rule.pattern.len > scratch.specs[scratch.len].len) return null;
            @memcpy(scratch.specs[scratch.len][total..][0..rule.pattern.len], rule.pattern);
            total += rule.pattern.len;
        }
        if (filter.name.len > scratch.names[scratch.len].len) return null;
        @memcpy(scratch.names[scratch.len][0..filter.name.len], filter.name);

        scratch.out[scratch.len] = .{
            .name = scratch.names[scratch.len][0..filter.name.len],
            .spec = scratch.specs[scratch.len][0..total],
        };
        scratch.len += 1;
    }
    return scratch.out[0..scratch.len];
}

// ---------------------------------------------------------------------------
// Tests. In the parity suite, on every OS, because this file imports nothing
// platform-specific — which is the only way a Windows decision is checked
// from a Linux runner.
// ---------------------------------------------------------------------------

test "a folder is a picker that insists the path exists" {
    const m = modelFor(.open_folder, .{}, &.{});
    try std.testing.expect(m.options.pick_folders);
    try std.testing.expect(m.options.path_must_exist);
    // The bug this pairing prevents: a folder dialog that also insists on a
    // FILE answers "no" to the only thing it was opened for.
    try std.testing.expect(!m.options.file_must_exist);
    try std.testing.expectEqual(DialogClass.open_folder, m.class);
}

test "an open file asks for something that is already there" {
    const m = modelFor(.open_file, .{}, &.{});
    try std.testing.expect(m.options.file_must_exist);
    try std.testing.expect(m.options.must_exist);
    try std.testing.expect(!m.options.pick_folders);
}

test "a save target requires a real folder but not a real file" {
    // Both flags at once is the classic Windows file dialog bug: the dialog
    // refuses to save anything that does not exist, which is everything.
    const m = modelFor(.save_file, .{}, &.{});
    try std.testing.expect(m.options.path_must_exist);
    try std.testing.expect(!m.options.file_must_exist);
}

test "multiple reaches an open dialog and not a save" {
    try std.testing.expect(modelFor(.open_file, .{ .multiple = true }, &.{}).options.allow_multiple);
    try std.testing.expect(modelFor(.open_folder, .{ .multiple = true }, &.{}).options.allow_multiple);
    try std.testing.expect(!modelFor(.save_file, .{ .multiple = true }, &.{}).options.allow_multiple);
}

test "the change-directory flag is set by default and nobody turns it off" {
    // A file dialog that changes the process's working directory is a file
    // dialog that breaks every relative path the app opens afterwards. This
    // is the default rather than an opt-in for that reason.
    const m = modelFor(.open_file, .{}, &.{});
    try std.testing.expect(m.options.no_change_dir);
}

test "the dialog class maps to the contract's kind" {
    try std.testing.expectEqual(contract.Kind.open_file, DialogClass.open_file.toContract());
    try std.testing.expectEqual(contract.Kind.open_folder, DialogClass.open_folder.toContract());
    try std.testing.expectEqual(contract.Kind.save_file, DialogClass.save_file.toContract());
}

test "the file type index is 1-based, and 0 means do not set one" {
    // The off-by-one that review never catches: SetFileTypeIndex takes 1-based
    // indices, so a 0-based index passed straight through either selects the
    // first filter when the caller meant "none", or skips the last one.
    try std.testing.expectEqual(@as(u32, 0), fileTypeIndex(.none, 3));
    try std.testing.expectEqual(@as(u32, 1), fileTypeIndex(.{ .index = 0 }, 3));
    try std.testing.expectEqual(@as(u32, 2), fileTypeIndex(.{ .index = 1 }, 3));
    try std.testing.expectEqual(@as(u32, 3), fileTypeIndex(.{ .index = 2 }, 3));
    // Out of range is refused rather than clamped: a caller asking for the
    // fourth of three filters has a bug, and clamping hides it.
    try std.testing.expectEqual(@as(u32, 0), fileTypeIndex(.{ .index = 3 }, 3));
    try std.testing.expectEqual(@as(u32, 0), fileTypeIndex(.{ .index = 0 }, 0));
}

test "no filters is a count of zero, not an empty array" {
    // SetFileTypes with an empty array installs a filter that matches nothing,
    // and the dialog then refuses to open any file at all.
    const m = modelFor(.open_file, .{}, &.{});
    try std.testing.expectEqual(@as(u32, 0), m.filter_count);

    const one = [_]contract.Filter{.{ .name = "All", .rules = &.{.{ .pattern = "*" }} }};
    try std.testing.expectEqual(@as(u32, 1), modelFor(.open_file, .{}, &one).filter_count);
}

test "filters flatten to SEMICOLON-separated specs, names kept" {
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
    // A semicolon, NOT a comma: COMDLG_FILTERSPEC splits on ';', so a comma
    // here yields one filter called "*.png,*.jpg" that matches no file.
    try std.testing.expectEqualStrings("*.png;*.jpg", flat[0].spec);
    try std.testing.expectEqualStrings("All files", flat[1].name);
    try std.testing.expectEqualStrings("*", flat[1].spec);
}

test "a filter with no rules flattens to an empty spec" {
    var scratch: FilterScratch = .{};
    const filters = [_]contract.Filter{.{ .name = "Everything" }};
    const flat = flattenFilters(&filters, &scratch) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("", flat[0].spec);
}

test "too many filters, or too long a spec, is a null rather than a truncation" {
    var scratch: FilterScratch = .{};
    var many: [17]contract.Filter = undefined;
    for (&many) |*f| f.* = .{ .name = "f", .rules = &.{.{ .pattern = "*" }} };
    try std.testing.expectEqual(@as(?[]const Filter, null), flattenFilters(&many, &scratch));

    const long = "x" ** 300; // one byte past what the spec buffer holds
    const big = [_]contract.Filter{.{ .name = "Big", .rules = &.{.{ .pattern = long }} }};
    try std.testing.expectEqual(@as(?[]const Filter, null), flattenFilters(&big, &scratch));
}

test "Windows selections are already paths, so nothing needs decoding" {
    // The reason macOS needs the URI codec and Windows does not: IFileDialog
    // answers with a filesystem path. Asserting it keeps the difference from
    // being "cleaned up" into a shared decode that would corrupt the result.
    try std.testing.expectEqual(PathStyle.verbatim, path_style);
}
