//! Images a host supplies as BYTES, for a backend with no filesystem: the browser build carries the app's `assets/` (a generated `asset_data` module), registers them here, and the renderer decodes them with the SAME decoder the disk path uses — so a page and a window draw the same pixels.
const std = @import("std");

/// One image the host supplied: the path the app asks for, and the bytes to decode.
pub const Source = struct { path: []const u8, bytes: []const u8 };

/// A fixed table rather than an allocation: registration happens once, before the first frame, and a browser that exceeds it fails to an unlisted image (a placeholder) rather than a crash.
pub const capacity: usize = 64;
var sources: [capacity]Source = undefined;
var source_count: usize = 0;

/// Register the images this build carries. Called from the generated asset module through the app's browser entry; a native build registers nothing and reads the filesystem instead.
pub fn register(list: anytype) void {
    for (list) |item| {
        if (source_count == sources.len) return;
        sources[source_count] = .{ .path = item.path, .bytes = item.bytes };
        source_count += 1;
    }
}

/// The bytes for `path`, or null when this host has none (every native build, and a browser whose build carried no assets). A miss is not an error: the renderer draws its documented placeholder.
pub fn find(path: []const u8) ?[]const u8 {
    if (path.len == 0) return null;
    for (sources[0..source_count]) |s| {
        if (std.mem.eql(u8, s.path, path)) return s.bytes;
    }
    return null;
}

/// How many images the host supplied, for a test or a log line.
pub fn count() usize {
    return source_count;
}

/// Forget everything: a test harness that registers a second set starts from empty.
pub fn reset() void {
    source_count = 0;
}
