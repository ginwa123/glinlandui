//! Content zoom: the ladder `Ctrl/Cmd +` / `-` walk, and the factor every declared length is painted at.
const std = @import("std");

// The rungs a browser offers, inside what the toolkit can draw (50% .. 300%). 100% is on the ladder, so a reset lands on it.
pub const steps = [_]f32{ 0.5, 0.67, 0.75, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0 };

// `Ctrl/Cmd 0`: what a browser calls 100%.
pub const reset: f32 = 1.0;

// A difference smaller than this is the same rung: a factor that arrives as 1.0000001 must still step to 1.1, not skip it.
const epsilon: f32 = 0.001;

/// A factor inside the ladder's own range; zero, negative and NaN mean "no zoom" rather than a collapsed layout.
pub fn clamp(factor: f32) f32 {
    if (!(factor > 0)) return reset;
    return std.math.clamp(factor, steps[0], steps[steps.len - 1]);
}

/// The next rung up (`dir > 0`) or down (`dir < 0`); an off-ladder factor snaps to the rung it would cross, and `dir == 0` clamps in place.
pub fn next(factor: f32, dir: i8) f32 {
    const current = clamp(factor);
    if (dir > 0) {
        for (steps) |step| {
            if (step > current + epsilon) return step;
        }
        return steps[steps.len - 1];
    }
    if (dir < 0) {
        var i: usize = steps.len;
        while (i > 0) {
            i -= 1;
            if (steps[i] < current - epsilon) return steps[i];
        }
        return steps[0];
    }
    return current;
}

/// The highest rung at or below `ceiling`: a window that cannot show 150% jumps to 125% rather than to a plain number.
pub fn largestAtMost(ceiling: f32) f32 {
    const limit = clamp(ceiling);
    var best: f32 = steps[0];
    for (steps) |step| {
        if (step <= limit + epsilon) best = step;
    }
    return best;
}

/// The factor as a whole percentage, which is how a status line says it (`Zoom 125%`).
pub fn percentLabel(buffer: []u8, factor: f32) []const u8 {
    const pct: u32 = @intFromFloat(@round(clamp(factor) * 100.0));
    return std.fmt.bufPrint(buffer, "{d}%", .{pct}) catch "";
}

test "a step up and a step down walk the ladder" {
    try std.testing.expectEqual(@as(f32, 1.1), next(1.0, 1));
    try std.testing.expectEqual(@as(f32, 1.25), next(1.1, 1));
    try std.testing.expectEqual(@as(f32, 0.9), next(1.0, -1));
    try std.testing.expectEqual(@as(f32, 1.0), next(1.1, -1));
}

test "the ends are clamped, never wrapped" {
    try std.testing.expectEqual(@as(f32, 3.0), next(3.0, 1));
    try std.testing.expectEqual(@as(f32, 0.5), next(0.5, -1));
    try std.testing.expectEqual(@as(f32, 3.0), clamp(9.0));
    try std.testing.expectEqual(@as(f32, 0.5), clamp(0.1));
}

test "an off-ladder factor snaps to the rung it would cross" {
    // 129% is not a rung: up is 150%, down is 125%, and neither call skips a step.
    try std.testing.expectEqual(@as(f32, 1.5), next(1.29, 1));
    try std.testing.expectEqual(@as(f32, 1.25), next(1.29, -1));
    // A hair off a rung is that rung: 1.001 steps to 1.1, not to 1.25.
    try std.testing.expectEqual(@as(f32, 1.1), next(1.001, 1));
}

test "reset is 100% and lands on a rung" {
    try std.testing.expectEqual(@as(f32, 1.0), reset);
    try std.testing.expect(std.mem.indexOfScalar(f32, &steps, reset) != null);
    try std.testing.expectEqual(reset, clamp(0));
    try std.testing.expectEqual(reset, clamp(-2));
}

test "percentLabel reads like a browser" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("100%", percentLabel(&buf, 1.0));
    try std.testing.expectEqualStrings("125%", percentLabel(&buf, 1.25));
    try std.testing.expectEqualStrings("67%", percentLabel(&buf, 0.67));
    try std.testing.expectEqualStrings("50%", percentLabel(&buf, 0.2));
}
