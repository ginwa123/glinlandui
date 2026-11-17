//! How much of a label still fits the room it was given, and whether the rest has to read as dots.
const std = @import("std");
const text = @import("text_backend.zig");

/// The dots a cut label ends with: three full stops, because the bundled face has Latin-1 and no U+2026.
pub const dots = "...";

/// What survives a budget: how many bytes of the text to keep, and whether anything was cut.
pub const Fitted = struct { keep: usize, dots: bool };

/// Cut `label` to `budget` points at `size`, so the rest of the run can be drawn as dots instead of wrapping.
pub fn fit(label: []const u8, size: u16, budget: f32) Fitted {
    if (label.len == 0) return .{ .keep = 0, .dots = false };
    // No room at all: the label is dropped, because dots alone would be a lie about a name nobody can read anyway.
    if (budget <= 0) return .{ .keep = 0, .dots = true };
    if (text.measureText(label, size).w <= budget) return .{ .keep = label.len, .dots = false };
    const dots_w = text.measureText(dots, size).w;
    if (dots_w >= budget) return .{ .keep = 0, .dots = false };
    // The longest prefix that still fits beside the dots: a binary search over codepoints, so a 200 char label costs a handful of measures.
    var lo: usize = 0;
    var hi: usize = codepoints(label);
    while (lo < hi) {
        const mid = lo + (hi - lo + 1) / 2;
        if (text.measureText(prefix(label, mid), size).w + dots_w <= budget) lo = mid else hi = mid - 1;
    }
    return .{ .keep = prefix(label, lo).len, .dots = true };
}

/// A count of codepoints, so a cut never lands inside a UTF-8 sequence.
pub fn codepoints(label: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < label.len) : (n += 1) {
        i += 1;
        while (i < label.len and (label[i] & 0xC0) == 0x80) i += 1;
    }
    return n;
}

/// The first `n` codepoints of `label`.
pub fn prefix(label: []const u8, n: usize) []const u8 {
    var i: usize = 0;
    var k: usize = 0;
    while (i < label.len and k < n) : (k += 1) {
        i += 1;
        while (i < label.len and (label[i] & 0xC0) == 0x80) i += 1;
    }
    return label[0..i];
}

const testing = std.testing;

test "a cut never lands inside a UTF-8 sequence" {
    // "é" is two bytes in one codepoint: three codepoints are four bytes, and two of them are three.
    try testing.expectEqual(@as(usize, 3), codepoints("aéb"));
    try testing.expectEqualStrings("aé", prefix("aéb", 2));
    try testing.expectEqual(@as(usize, 3), prefix("aéb", 2).len);
}

test "a budget wide enough keeps the whole label, and an empty one drops it" {
    // Whatever font the host has, this budget is wider than the label: the cut is asked of the same measurer.
    const label = "a request name nobody would ever type";
    const whole = fit(label, 13, 1e6);
    try testing.expectEqual(label.len, whole.keep);
    try testing.expect(!whole.dots);
    const none = fit(label, 13, 0);
    try testing.expectEqual(@as(usize, 0), none.keep);
    // An empty label has nothing to cut, so it asks for no dots either.
    const empty = fit("", 13, 0);
    try testing.expectEqual(@as(usize, 0), empty.keep);
    try testing.expect(!empty.dots);
}
