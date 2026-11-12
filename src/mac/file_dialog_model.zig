//! The AppKit panel's behaviour, as PURE data.
const std = @import("std");
const contract = @import("../core/file_dialog_contract.zig");

/// `NSModalResponse`, named.
pub const Response = enum(u32) {
    stop = 0,
    ok = 1,
    cancel = 2,
    continue_ = 3,
    abort = 4,
    /// A value AppKit has not defined yet.
    _,

    /// What this modal answer means to the toolkit.
    pub fn toStatus(self: Response) contract.Status {
        return switch (self) {
            .ok => .selected,
            // Cancel and Stop are both "the user did not give us anything", and both are a normal outcome rather than a failure.
            .cancel, .stop => .cancelled,
            // Continue/Abort mean the panel is being driven by something else (a sheet, an accessory view).
            else => .other,
        };
    }
};

/// What the panel must be told to allow, derived from the caller's `Options`.
pub const PanelConfig = struct {
    /// The panel picks files.
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
    /// The label on the confirming button ("Save", "Open", …), or null for the platform's own wording.
    prompt: ?[]const u8,
};

/// Translate `Options` into what the panel should be asked for.
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
pub const PanelFilter = struct {
    name: []const u8,
    /// The patterns joined with commas, which is the format AppKit parses.
    patterns: []const u8,
};

/// The scratch space a caller needs to flatten filters into `PanelFilter`s.
pub const max_filters = 16;

pub const FilterScratch = struct {
    specs: [max_filters][128]u8 = undefined,
    patterns: [max_filters][256]u8 = undefined,
    out: [max_filters]PanelFilter = undefined,
    len: usize = 0,
};

/// Flatten `filters` into `scratch`, or return null when they do not fit.
pub fn flattenFilters(filters: []const contract.Filter, scratch: *FilterScratch) ?[]const PanelFilter {
    if (filters.len > scratch.out.len) return null;
    scratch.len = 0;
    for (filters) |filter| {
        if (scratch.len >= scratch.out.len) return null;

        // The patterns first: they are the variable-length part, and they are what the buffer is really for.
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

// Tests.

test "a folder request is a panel that cannot choose files" {
    const config = configFor(.{ .kind = .open_folder });
    try std.testing.expect(!config.can_choose_files);
    try std.testing.expect(config.can_choose_directories);
    try std.testing.expect(!config.can_create_files);
}

test "a file request is a panel that cannot choose directories" {
    // The distinction that matters: NOT a file panel that can also pick directories, which would let the user return a .txt where a folder was asked for.
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
    // Sending one to an open panel is a no-op AppKit ignores; sending a folder it did not ask for would pre-fill a name the user then has to delete.
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
    // Not a null and not a crash: AppKit shows the filter with nothing to match, which is what the caller asked for by supplying no rules.
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
    // Truncation is the failure mode that matters: a half-written glob matches nothing, so the dialog silently stops offering that filter and the user.
    var scratch: FilterScratch = .{};
    const long = "x" ** 300; // one byte longer than the buffer allows
    const filters = [_]contract.Filter{.{ .name = "Big", .rules = &.{.{ .pattern = long }} }};
    try std.testing.expectEqual(@as(?[]const PanelFilter, null), flattenFilters(&filters, &scratch));
}
