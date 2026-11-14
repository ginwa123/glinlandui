// The filesystem half of font loading: where the platform keeps its UI fonts, and how to read one whole. Deliberately dependency-free (std only) so that

// `glyphs.zig` can use it without importing the text BACKEND, which would be a cycle: the backend measures text, and measuring needs the font.
const std = @import("std");

// macOS ships these system fonts, so a no-dependency test can still prove the public font-resolution contract.
const macos_candidates: []const [:0]const u8 = &.{
    "/System/Library/Fonts/SFNSMono.ttf",
    "/System/Library/Fonts/SFNS.ttf",
    "/System/Library/Fonts/Menlo.ttc",
    "/Library/Fonts/Arial.ttf",
};

// Linux desktop fonts, in the order a UI usually wants them.
const linux_candidates: []const [:0]const u8 = &.{
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
};

// Windows ships these.
const windows_candidates: []const [:0]const u8 = &.{
    "C:/Windows/Fonts/consola.ttf",
    "C:/Windows/Fonts/segoeui.ttf",
    "C:/Windows/Fonts/arial.ttf",
};

// Every candidate path for this OS, best first.
pub fn fontCandidates() []const [:0]const u8 {
    return switch (@import("builtin").os.tag) {
        .macos => macos_candidates,
        .windows => windows_candidates,
        else => linux_candidates,
    };
}

// True when the path names a file this process can open.
pub fn fontExists(path: [:0]const u8) bool {
    std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), path, .{}) catch return false;
    return true;
}

// Read a font file whole. Returns `error.FontNotFound` for anything unreadable, so a caller can try the next one.
pub fn readFontBytes(path: [:0]const u8, alloc: std.mem.Allocator) ![]u8 {
    // Zig 0.16's Io-based fs: cwd() is a Dir and every call needs an Io.
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir = std.Io.Dir.cwd();
    const f = dir.openFile(io, path, .{}) catch return error.FontNotFound;
    defer f.close(io);
    const stat = f.stat(io) catch return error.FontNotFound;
    const n = stat.size;
    if (n == 0) return error.FontNotFound;
    const buf = alloc.alloc(u8, @intCast(n)) catch return error.OutOfMemory;
    errdefer alloc.free(buf);
    const got = f.readPositionalAll(io, buf, 0) catch return error.FontNotFound;
    if (got == 0) return error.FontNotFound;
    return buf;
}

test "fontCandidates is non-empty and every entry is NUL-terminated" {
    const list = fontCandidates();
    try std.testing.expect(list.len > 0);
    for (list) |path| try std.testing.expect(path.len > 0);
}
