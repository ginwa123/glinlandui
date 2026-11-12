//! A scriptable file dialog, for tests.

const std = @import("std");
const contract = @import("file_dialog_contract.zig");

/// What the dialog will say when it is called.
pub const Answer = union(enum) {
    /// The user picked these paths.
    selected: []const []const u8,
    /// The user dismissed the dialog.
    cancelled,
    /// The dialog closed for another reason.
    other,
    /// The backend refused.
    failed: contract.Error,
};

/// One recorded rule.
pub const FakeRule = struct {
    pattern: []const u8,

    /// The pattern as text.
    pub fn patternText(self: FakeRule) []const u8 {
        return self.pattern;
    }
};

/// One recorded filter.
pub const FakeFilter = struct {
    name: []const u8,
    rules: []const FakeRule,
    rule_count: usize,

    /// The filter's display name.
    pub fn nameText(self: FakeFilter) []const u8 {
        return self.name;
    }
};

const max_filters = 8;
const max_rules = 8;

/// The installed dialog. Lives on the caller's stack; `install` keeps a pointer to it.
pub const Fake = struct {
    answer: Answer = .cancelled,
    /// How many times the dialog was opened.
    calls: usize = 0,
    /// The title of the last request.
    last_title: []const u8 = "",
    /// The starting folder of the last request, null when none was given.
    last_folder: ?[]const u8 = null,
    /// How many filters the last request carried.
    filter_count: usize = 0,
    /// The filters of the last request.
    filters: []const FakeFilter = &.{},

    filter_buf: [max_filters]FakeFilter = undefined,
    rule_buf: [max_filters][max_rules]FakeRule = undefined,
};

var installed: ?*Fake = null;

/// Make `f` the dialog every `openFile` call answers from.
pub fn install(f: *Fake) void {
    installed = f;
}

/// Go back to the portable stub.
pub fn uninstall() void {
    installed = null;
}

/// Answer from the installed fake, recording the request first.
pub fn openFile(alloc: std.mem.Allocator, options: contract.Options) !contract.Selection {
    const f = installed orelse return error.Unsupported;

    f.calls += 1;
    f.last_title = options.title;
    f.last_folder = options.current_folder;

    const n = @min(options.filters.len, max_filters);
    f.filter_count = n;
    for (options.filters[0..n], 0..) |filter, i| {
        const rn = @min(filter.rules.len, max_rules);
        for (filter.rules[0..rn], 0..) |rule, j| {
            f.rule_buf[i][j] = .{ .pattern = rule.pattern };
        }
        f.filter_buf[i] = .{
            .name = filter.name,
            .rules = f.rule_buf[i][0..rn],
            .rule_count = rn,
        };
    }
    f.filters = f.filter_buf[0..n];

    return switch (f.answer) {
        .selected => |paths| .{
            .status = .selected,
            .paths = try dupePaths(alloc, paths),
        },
        .cancelled => .{ .status = .cancelled },
        .other => .{ .status = .other },
        .failed => |err| err,
    };
}

/// Ask for a folder. Same answer as `openFile`, so a test scripts one thing.
pub fn openFolder(alloc: std.mem.Allocator, options: contract.Options) !contract.Selection {
    return openFile(alloc, options);
}

/// Ask for a save target. Same answer as `openFile`, so a test scripts one thing.
pub fn saveFile(alloc: std.mem.Allocator, options: contract.Options) !contract.Selection {
    return openFile(alloc, options);
}

/// Whether a dialog can be shown. True whenever a fake is installed.
pub fn available() bool {
    return installed != null;
}

/// Copy `paths` into `alloc`, so the caller's `Selection.deinit` frees what it owns.
fn dupePaths(alloc: std.mem.Allocator, paths: []const []const u8) ![]const []const u8 {
    const out = try alloc.alloc([]const u8, paths.len);
    var done: usize = 0;
    errdefer {
        for (out[0..done]) |p| alloc.free(p);
        alloc.free(out);
    }
    for (paths, 0..) |p, i| {
        out[i] = try alloc.dupe(u8, p);
        done = i + 1;
    }
    return out;
}

test "with nothing installed the fake is the portable stub" {
    uninstall();
    try std.testing.expectError(error.Unsupported, openFile(std.testing.allocator, .{}));
}

test "an installed fake answers and records the request" {
    var f: Fake = .{ .answer = .{ .selected = &.{"/tmp/a.db"} } };
    install(&f);
    defer uninstall();

    const rules = [_]contract.Rule{.{ .pattern = "*.db" }};
    const filters = [_]contract.Filter{.{ .name = "Databases", .rules = &rules }};
    const sel = try openFile(std.testing.allocator, .{
        .title = "Open database",
        .filters = &filters,
        .current_folder = "/tmp",
    });
    defer sel.deinit(std.testing.allocator);

    try std.testing.expectEqual(contract.Status.selected, sel.status);
    try std.testing.expectEqualStrings("/tmp/a.db", sel.first().?);
    try std.testing.expectEqual(@as(usize, 1), f.calls);
    try std.testing.expectEqualStrings("Open database", f.last_title);
    try std.testing.expectEqualStrings("/tmp", f.last_folder.?);
    try std.testing.expectEqual(@as(usize, 1), f.filter_count);
    try std.testing.expectEqualStrings("Databases", f.filters[0].nameText());
    try std.testing.expectEqual(@as(usize, 1), f.filters[0].rule_count);
    try std.testing.expectEqualStrings("*.db", f.filters[0].rules[0].patternText());
}

test "a failed answer surfaces as the error the backend reported" {
    var f: Fake = .{ .answer = .{ .failed = error.NoPortal } };
    install(&f);
    defer uninstall();
    try std.testing.expectError(error.NoPortal, openFile(std.testing.allocator, .{}));
}

test "a cancelled answer owns nothing, so deinit is a no-op" {
    var f: Fake = .{ .answer = .cancelled };
    install(&f);
    defer uninstall();
    const sel = try openFile(std.testing.allocator, .{});
    defer sel.deinit(std.testing.allocator);
    try std.testing.expectEqual(contract.Status.cancelled, sel.status);
    try std.testing.expectEqual(@as(?[]const u8, null), sel.first());
}
