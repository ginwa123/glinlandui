//! The Windows file dialog: `IFileDialog`, through the shim.
const std = @import("std");
const contract = @import("../core/file_dialog_contract.zig");
const model = @import("file_dialog_model.zig");

// The shim header is plain C by design (see windows/shim.h), so @cImport never has to survive a COM type.
const c = @cImport({
    @cInclude("shim.h");
});

/// Re-exported so `glinlandui.file_dialog.Options` is this platform's module and not a Linux one.
pub const Kind = contract.Kind;
pub const Rule = contract.Rule;
pub const Filter = contract.Filter;
pub const Options = contract.Options;
pub const Status = contract.Status;
pub const Selection = contract.Selection;
pub const Error = contract.Error;

/// True when this host can open a dialog at all.
pub fn available() bool {
    return true;
}

/// Ask for one existing file.
pub fn openFile(alloc: std.mem.Allocator, options: Options) !Selection {
    return run(alloc, options, .open_file);
}

/// Ask for one existing DIRECTORY.
pub fn openFolder(alloc: std.mem.Allocator, options: Options) !Selection {
    return run(alloc, options, .open_folder);
}

/// Ask where to write a file.
pub fn saveFile(alloc: std.mem.Allocator, options: Options) !Selection {
    return run(alloc, options, .save_file);
}

/// How many selections the dialog can return before the shim starts delivering.
const max_paths = 256;

/// The collector the shim's callback fills.
const Collector = struct {
    alloc: std.mem.Allocator,
    items: [max_paths][]const u8 = undefined,
    count: usize = 0,
    overflowed: bool = false,

    fn append(self: *Collector, path: [*c]const u8) void {
        if (self.count >= self.items.len) {
            self.overflowed = true;
            return;
        }
        self.items[self.count] = self.alloc.dupe(u8, std.mem.span(path)) catch {
            self.overflowed = true;
            return;
        };
        self.count += 1;
    }

    fn deinit(self: *Collector) void {
        for (self.items[0..self.count]) |p| self.alloc.free(p);
    }
};

/// `[*c]const u8`, not `[*:0]const u8`: the shim header declares a plain `const char *`, and @cImport types it as an unsentineled pointer.
fn onPath(user: ?*anyopaque, path: [*c]const u8) callconv(.c) void {
    const self: *Collector = @ptrCast(@alignCast(user.?));
    self.append(path);
}

fn run(alloc: std.mem.Allocator, opts: Options, class: model.DialogClass) !Selection {
    var effective = opts;
    effective.kind = class.toContract();

    const m = model.modelFor(class, effective, effective.filters);

    // The filter list, flattened into storage the shim can point at for the duration of the call.
    var scratch: model.FilterScratch = .{};
    const filters = model.flattenFilters(effective.filters, &scratch);

    const title_z = nulTerminate(effective.title);
    const label_z = nulTerminate(effective.accept_label);
    const folder_z: ?[*:0]const u8 = if (effective.current_folder) |f| nulTerminate(f) else null;
    const name_z: ?[*:0]const u8 = if (effective.current_name) |n| nulTerminate(n) else null;

    var c_filters: [model.max_filters]c.GlinWinFileFilter = undefined;
    var filter_count: c_int = 0;
    if (filters) |list| {
        for (list) |f| {
            c_filters[@intCast(filter_count)] = .{
                .name = nulTerminate(f.name),
                .spec = nulTerminate(f.spec),
            };
            filter_count += 1;
        }
    }

    const request = c.GlinWinFileRequest{
        .kind = switch (class) {
            .open_file => 0,
            .open_folder => 1,
            .save_file => 2,
        },
        .options = m.options.toBits(),
        .file_type_index = model.fileTypeIndex(.none, @intCast(filter_count)),
        .filter_count = filter_count,
        .filters = if (filter_count > 0) &c_filters else null,
        .title = title_z,
        .accept_label = label_z,
        .current_folder = folder_z,
        .current_name = name_z,
        .modal = if (effective.modal) 1 else 0,
        // 0 for now: nothing in the toolkit's public surface carries an HWND, and inventing one here would be a lie the shim cannot check.
        .owner_hwnd = 0,
    };

    var collector = Collector{ .alloc = alloc };
    defer collector.deinit();

    const result = c.glin_win_file_dialog(&request, onPath, &collector);

    // The shim's three failures are three different problems, and an app can do something about two of them: -1 cancelled the user closed it; a normal.
    if (result < 0) {
        return switch (result) {
            -1 => .{ .status = .cancelled },
            // -2 (could not be created) and -3 (could not be shown) are both "the dialog did not run", which no status describes: there is no selection and no.
            else => error.PortalError,
        };
    }

    if (collector.count == 0) return error.PortalError;

    // No `catch |err| switch`: an Allocator's only error IS OutOfMemory, so the extra prong is unreachable — and a compile error, not a warning.
    const paths = alloc.alloc([]const u8, collector.count) catch return error.OutOfMemory;
    errdefer alloc.free(paths);

    @memcpy(paths, collector.items[0..collector.count]);
    collector.count = 0; // the storage now belongs to `paths`

    if (collector.overflowed) {
        // More selections than the bound could hold.
        return .{ .status = .other, .paths = paths };
    }
    return .{ .status = .selected, .paths = paths };
}

/// A NUL-terminated view of `text` that lives as long as the caller's frame.
fn nulTerminate(text: []const u8) [*:0]const u8 {
    return text.ptr[0..text.len :0];
}
