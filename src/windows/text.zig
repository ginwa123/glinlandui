//! Windows text engine — the `text.zig` half of the platform mirror.
//!
//! Linux talks to pangocairo through `linux/text.zig` plus the `linux/shim.h`
//! header. Windows and macOS have no native text engine in this project: both
//! use the deterministic estimator in `core/text_portable.zig` — the same
//! module every test build uses on every platform.
//!
//! This file re-exports that surface so
//!
//!     linux/text.zig     (pangocairo via the C shim)          ~260 lines
//!     mac/text.zig       (the shared estimator)                38 lines
//!     windows/text.zig   (the shared estimator + Windows font paths)   this
//!
//! sit at the same path in each platform folder, and `platform.zig` can name a
//! Windows text module instead of special-casing "Windows has none". When a
//! DirectWrite backend lands, this is the file that grows.
//!
//! ## The one thing that IS Windows-specific: the font paths
//!
//! `core/text_portable.zig` lists macOS system fonts, and on Windows every one
//! of those misses. That is not a cosmetic difference: the CPU glyph
//! rasterizer degrades to one anti-aliased box per UTF-8 BYTE when it cannot
//! load a font (see `render_software.zig`), so a Windows build without these
//! entries renders the calculator's labels as bars. The list below is therefore
//! the whole point of this file, and the fact that it is a plain Zig constant
//! is why it needs no C import and stays in the parity suite.
//!
//! The order is best-looking-first and, importantly, all-`.ttf`: a `.ttc` is a
//! TrueType *collection* and stb_truetype's `stbtt_InitFont` rejects it, so a
//! collection early in the list only costs a failed open.
//!
//! The re-export list is deliberately the exact set `core/text_backend.zig`
//! forwards, so `core/select.zig` can treat either platform's module the same.
//!
//! NOTE: `pangoFamily` is a pangocairo concept with no meaning here. It is
//! re-exported for surface parity with `linux/text.zig`; the portable estimator
//! ignores it.
const portable = @import("../core/text_portable.zig");

pub const TextExtent = portable.TextExtent;
pub const ResolveFontError = portable.ResolveFontError;

/// Windows' monospace faces, in preference order.
///
/// Paths are absolute and drive-root-relative, which is what
/// `std.Io.Dir.cwd().access` resolves on Windows: `C:\Windows\Fonts\consola.ttf`
/// is looked up relative to the current drive, and Windows has been on C: since
/// Windows 95, so the list below is correct without consulting %WINDIR%.
///
/// The variable would be nicer, but `fontCandidates` returns a
/// `[]const [:0]const u8` with no error path, and a probe that can fail is a
/// probe whose failure is invisible. Four fixed paths covering three decades of
/// Windows installs is the more honest trade.
pub const font_candidates: []const [:0]const u8 = &.{
    // Consolas: shipped since Vista, and the face most Windows apps use.
    "C:\\Windows\\Fonts\\consola.ttf",
    // Courier New: since NT. A wider fallback for odd layouts.
    "C:\\Windows\\Fonts\\cour.ttf",
    // Lucida Console: since NT 4.0, present on nearly every install.
    "C:\\Windows\\Fonts\\lucon.ttf",
    // The Windows 3.1/95 bitmap console face. A last resort, but it is a plain
    // TrueType file and stb_truetype can load it.
    "C:\\Windows\\Fonts\\vgafix.ttf",
};

/// `resolveFont` is the estimator's own implementation, and it walks THAT
/// module's `font_candidates` — the macOS list — so it cannot be reused as-is
/// without returning a path that does not exist on Windows.
///
/// The behaviour is preserved exactly: the first path that merely EXISTS wins.
/// (The existence check, not parseability, because callers depend on that: the
/// CPU rasterizer walks the whole list itself and keeps the first file that
/// actually loads, precisely so a collection that merely exists does not stop
/// it.) What changes is only which paths are probed.
pub fn resolveFont() ResolveFontError![]const u8 {
    for (font_candidates) |path| {
        if (fontExists(path)) return path;
    }
    return error.FontNotFound;
}

fn fontExists(path: [:0]const u8) bool {
    std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), path, .{}) catch return false;
    return true;
}

/// Every candidate path, for callers that must try more than one (e.g. a
/// rasterizer that has to keep going until a file actually parses).
///
/// THIS is the one symbol that is not a plain re-export, and the reason is
/// `core/glyphs.zig`: it calls `text_backend.fontCandidates()` and keeps the
/// first candidate that stb_truetype can actually parse. Re-exporting the
/// portable list here would make the Windows glyph path look for macOS fonts,
/// fail, and fall back to one box per byte — a silent, plausible-looking
/// regression that no test in the parity suite can see.
pub fn fontCandidates() []const [:0]const u8 {
    return font_candidates;
}

/// Read a font file whole. The fs half of font loading, which lives in the
/// platform text module rather than in `core/glyphs.zig` — see
/// `core/text_portable.zig` for why: `glyphs.zig` is compiled by EVERY build,
/// the wasm one included, so it must hold no filesystem code at all.
///
/// Windows has a real filesystem, so this is the same implementation the
/// portable module uses. It is duplicated rather than re-exported because
/// `windows/text.zig` deliberately does NOT re-export the portable module's
/// font list (see `fontCandidates` above) — the two are separate on purpose.
pub fn readFontBytes(path: [:0]const u8, alloc: std.mem.Allocator) ![]u8 {
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

const std = @import("std");

/// The family name reported for a resolved font. The portable estimator only
/// uses it for a cache key, so this is Windows' own monospace family name and
/// nothing more elaborate.
pub fn pangoFamily() [:0]const u8 {
    _ = resolveFont() catch {};
    return "Consolas";
}

pub const estimatorExtent = portable.estimatorExtent;
pub const hashMeasureKey = portable.hashMeasureKey;
pub const extentCacheReset = portable.extentCacheReset;
pub const measureText = portable.measureText;
pub const extent_hits = portable.extent_hits;
pub const extent_misses = portable.extent_misses;

// ===================== tests (parity suite — every platform) =====================
//
// The count stays identical on every platform: these assert the SHAPE of the
// candidate list, never the presence of a font, because "is Consolas
// installed" is a property of the build machine and must not move the locked
// parity total.

test "the candidate list is non-empty and every entry is a .ttf" {
    // A `.ttc` here would be a file stb_truetype cannot open, which costs a
    // failed parse before the next candidate is tried.
    try std.testing.expect(font_candidates.len > 0);
    for (font_candidates) |path| {
        const s: []const u8 = path;
        try std.testing.expect(s.len > 0);
        try std.testing.expect(std.mem.endsWith(u8, s, ".ttf"));
    }
}

test "the candidates are absolute Windows paths, not POSIX ones" {
    // The portable list is macOS absolute ("/System/Library/..."). A path that
    // starts with '/' resolves against the current DRIVE on Windows, so a
    // POSIX path silently probes C:\System\... and misses.
    for (font_candidates) |path| {
        const s: []const u8 = path;
        try std.testing.expect(s.len >= 3);
        try std.testing.expectEqual(@as(u8, ':'), s[1]);
        try std.testing.expect(s[0] >= 'A' and s[0] <= 'Z');
        try std.testing.expectEqual(@as(u8, '\\'), s[2]);
    }
}

test "the candidate list is deduplicated" {
    // A duplicate makes the rasterizer try the same file twice for no reason,
    // and hides a copy-paste error in the table.
    for (font_candidates, 0..) |a, i| {
        for (font_candidates[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, a, b));
        }
    }
}

test "fontCandidates is the same list resolveFont walks" {
    // If these two ever diverge, the glyph rasterizer and the reported family
    // name disagree about which font is in use — and the difference is only
    // visible as slightly different glyphs.
    try std.testing.expectEqual(@intFromPtr(font_candidates.ptr), @intFromPtr(fontCandidates().ptr));
}

test "resolveFont returns one of the advertised paths, or FontNotFound" {
    // Deliberately does NOT assert success: whether Consolas is installed is a
    // property of the build machine, and a test that depended on it would make
    // the locked cross-platform count depend on the host too.
    if (resolveFont()) |path| {
        var listed = false;
        for (font_candidates) |c| {
            if (std.mem.eql(u8, c, path)) listed = true;
        }
        try std.testing.expect(listed);
    } else |err| {
        try std.testing.expectEqual(ResolveFontError.FontNotFound, err);
    }
}

test "the family name is a stable, NUL-terminated Windows family" {
    const fam: []const u8 = pangoFamily();
    try std.testing.expectEqualStrings("Consolas", fam);
}
