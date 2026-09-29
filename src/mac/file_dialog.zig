//! The macOS file dialog: `NSOpenPanel`, through the shim.
//!
//! The tenth file in the platform mirror, and the peer of
//! `linux/file_dialog.zig` — with one important difference in shape, which is
//! what the mirror is for. Linux talks D-Bus, which is a text protocol with
//! frames and headers, so its protocol layer needed two files
//! (`linux/dbus.zig` + `linux/portal.zig`). AppKit talks objects and
//! selectors, so the protocol layer is a few booleans and one enum, and it
//! fits in `mac/file_dialog_model.zig`. Same division of labour, different
//! amount of code.
//!
//!   - `mac/shim.m`      owns the NSOpenPanel. It decides nothing.
//!   - `file_dialog_model.zig`  owns every decision, and is pure.
//!   - this file         is the wiring between them.
//!
//! So the two things most likely to be wrong here — which panel a request
//! becomes, and what a modal answer means — are in a file the parity suite
//! runs on every platform. The thing left over, calling AppKit at all, is
//! exactly the thing no test can reach, which is why it is four lines.
//!
//! ## Blocking, like every other backend here
//!
//! `[NSOpenPanel runModal]` blocks the main thread until the user answers, and
//! the caller is inside a click handler at that point. That is correct for a
//! modal dialog and it is the same shape the Linux backend has; `timeout_ms`
//! is NOT honoured here, because AppKit owns the modal loop and the only way
//! to stop it is to call `-[NSOpenPanel cancel:]` from a timer the host does
//! not run while it is blocked. A host that needs a deadline should run the
//! dialog on a worker thread and post the answer back.
const std = @import("std");
const contract = @import("../core/file_dialog_contract.zig");
const model = @import("file_dialog_model.zig");

// The shim header is plain C by design (see mac/shim.h), so @cImport never
// has to survive an Objective-C type.
const c = @cImport({
    @cInclude("shim.h");
});

/// Re-exported so `glinlandui.file_dialog.Options` is this platform's module
/// and not a Linux one.
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

/// How many selections the panel can return, before the shim starts
/// delivering. AppKit's own limit is far lower (a few hundred), so this is
/// not a real constraint — it is a bound that makes the buffer below a
/// compile-time number instead of a "hope for the best".
const max_paths = 64;

/// The collector the shim's callback fills. It owns its own storage and hands
/// out borrowed paths, because the strings AppKit gives us are valid only
/// until the panel goes away.
const Collector = struct {
    alloc: std.mem.Allocator,
    items: [max_paths][]const u8 = undefined,
    count: usize = 0,
    /// Set when a selection could not be stored. Reported as a truncated
    /// result rather than silently returning fewer paths than the user chose.
    overflowed: bool = false,

    fn append(self: *Collector, file_uri: [*c]const u8) void {
        const uri = std.mem.span(file_uri);
        if (self.count >= self.items.len) {
            self.overflowed = true;
            return;
        }

        // A `file://` URL comes back percent-encoded; the shared codec turns
        // it into a path. A URL this host cannot map to a local file (a cloud
        // placeholder, a security-scoped bookmark) is SKIPPED rather than
        // fatal — the other selections are still perfectly good paths, and
        // failing the whole dialog over one of them is worse than the user
        // noticing one entry is missing.
        var buf: [4096]u8 = undefined;
        const path = contract.fileUriToPath(uri, &buf) catch return;
        self.items[self.count] = self.alloc.dupe(u8, path) catch {
            self.overflowed = true;
            return;
        };
        self.count += 1;
    }

    fn deinit(self: *Collector) void {
        for (self.items[0..self.count]) |p| self.alloc.free(p);
    }
};

/// `[*c]const u8`, not `[*:0]const u8`: the shim header declares a plain
/// `const char *`, and @cImport types it as an unsentineled pointer.
fn onPath(user: ?*anyopaque, file_uri: [*c]const u8) callconv(.c) void {
    const self: *Collector = @ptrCast(@alignCast(user.?));
    self.append(file_uri);
}

fn run(alloc: std.mem.Allocator, opts: Options, kind: Kind) !Selection {
    // The kind is the caller's, not the wrapper's argument: `openFolder` is
    // the only thing that should ever produce a directory chooser, and this
    // is the one place that says so.
    var effective = opts;
    effective.kind = kind;

    const config = model.configFor(effective);

    // The filter list is flattened into storage the shim can point at for the
    // duration of the call. It must outlive `glin_cocoa_file_dialog` and
    // nothing else — which is why it is a local here rather than a field on
    // anything that outlives the dialog.
    var scratch: model.FilterScratch = .{};
    const filters = model.flattenFilters(effective.filters, &scratch);

    // NUL-terminated copies for the C strings. The shim reads them for the
    // duration of the call and never retains them, so borrowing is enough —
    // but a C string that is not NUL-terminated is a read past the end of the
    // buffer, so every one of these is `[*:0]`.
    const title_z = nulTerminate(config.title);
    const dir_z: ?[*:0]const u8 = if (config.directory) |d| nulTerminate(d) else null;
    const name_z: ?[*:0]const u8 = if (config.file_name) |n| nulTerminate(n) else null;
    const prompt_z: ?[*:0]const u8 = if (config.prompt) |p| nulTerminate(p) else null;

    var c_filters: [model.max_filters]c.GlinCocoaFileFilter = undefined;
    var filter_count: c_int = 0;
    if (filters) |list| {
        for (list) |f| {
            c_filters[@intCast(filter_count)] = .{
                .name = nulTerminate(f.name),
                .patterns = nulTerminate(f.patterns),
            };
            filter_count += 1;
        }
    }

    const request = c.GlinCocoaFileRequest{
        .kind = switch (kind) {
            .open_file => 0,
            .open_folder => 1,
            .save_file => 2,
        },
        .can_choose_files = if (config.can_choose_files) 1 else 0,
        .can_choose_directories = if (config.can_choose_directories) 1 else 0,
        .allows_multiple = if (config.allows_multiple) 1 else 0,
        .can_create_files = if (config.can_create_files) 1 else 0,
        .title = title_z,
        .directory = dir_z,
        .file_name = name_z,
        .prompt = prompt_z,
        .filters = if (filter_count > 0) &c_filters else null,
        .filter_count = filter_count,
    };

    var collector = Collector{ .alloc = alloc };
    defer collector.deinit();

    const response = c.glin_cocoa_file_dialog(&request, onPath, &collector);

    // The mapping is the model's, and it is tested on every platform: OK is 1
    // and Cancel is 2, which is the opposite of the order they read in.
    const status = model.statusForResponse(response);
    if (status != .selected) {
        // A cancelled panel delivers no paths, so there is nothing to free
        // and nothing to report — which is the whole reason cancellation is a
        // status rather than an error.
        return .{ .status = status };
    }

    if (collector.count == 0) return error.PortalError;

    // No `catch |err| switch`: an Allocator's only error IS OutOfMemory, so
    // the extra prong is unreachable — and a compile error, not a warning. The
    // Windows build caught it; the macOS backend has to be caught by reading,
    // which is exactly the kind of thing the parity suite cannot check and CI
    // finds on a Mac.
    const paths = alloc.alloc([]const u8, collector.count) catch return error.OutOfMemory;
    errdefer alloc.free(paths);

    // The collector's storage moves to the caller's, which is why the count is
    // copied BEFORE the defer above runs — and why `collector.deinit` must
    // not have run yet, hence the `count` reset.
    @memcpy(paths, collector.items[0..collector.count]);
    collector.count = 0;

    if (collector.overflowed) {
        // More selections than the bound, or one that could not be stored. The
        // caller gets what fitted, and the toolkit's `Status` has no way to
        // say "partly" — so this is reported rather than passed off as a
        // complete answer.
        return .{ .status = .other, .paths = paths };
    }
    return .{ .status = .selected, .paths = paths };
}

/// A NUL-terminated view of `text` that lives as long as the caller's frame.
///
/// The shim reads these for the duration of `glin_cocoa_file_dialog` and keeps
/// nothing, so borrowing is correct. A `[]const u8` is NOT: a C string that
/// is not terminated is a read past the end of the buffer, and the crash lands
/// somewhere unrelated.
fn nulTerminate(text: []const u8) [*:0]const u8 {
    return text.ptr[0..text.len :0];
}
