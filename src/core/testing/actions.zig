//! Pure action PLANNING for the E2E API — the geometry and gesture math behind `performScrollTo`, `performTouchInput` and the wheel helpers.
const std = @import("std");
const cl = @import("zclay");
const sm = @import("../semantics.zig");

/// A scroll nudge in `scroll.scrollBy`'s units: positive `dy` scrolls DOWN (content moves up), positive `dx` scrolls RIGHT.
pub const ScrollIntent = struct {
    dx: f32 = 0,
    dy: f32 = 0,

    pub fn isZero(self: ScrollIntent) bool {
        return self.dx == 0 and self.dy == 0;
    }
};

/// Clay multiplies a wheel delta by this factor (see scroll.zig's wheel test: a delta of 5 travels 50px), so a test that wants N pixels of travel must.
pub const wheel_factor: f32 = 10;

/// Convert a desired pixel travel into the wheel delta that produces it.
pub fn wheelUnitsForPixels(px: f32) f32 {
    return px / wheel_factor;
}

/// How far to scroll to bring `n` fully inside its clip rect.
pub fn revealDelta(n: sm.Node) ScrollIntent {
    if (!n.found) return .{};
    return .{
        .dx = revealAxis(n.bounds.x, n.bounds.width, n.clip.x, n.clip.width),
        .dy = revealAxis(n.bounds.y, n.bounds.height, n.clip.y, n.clip.height),
    };
}

fn revealAxis(node_pos: f32, node_len: f32, clip_pos: f32, clip_len: f32) f32 {
    if (node_len >= clip_len) return node_pos - clip_pos; // align leading edges
    if (node_pos < clip_pos) return node_pos - clip_pos; // above/left of the viewport
    const node_end = node_pos + node_len;
    const clip_end = clip_pos + clip_len;
    if (node_end > clip_end) return node_end - clip_end; // below/right of the viewport
    return 0;
}

/// A pointer gesture plan: press at the start, `steps` interpolated motions, then release at the end.
pub const Swipe = struct {
    from_x: f32,
    from_y: f32,
    to_x: f32,
    to_y: f32,
    /// Intermediate motion events.
    steps: u8 = 4,

    pub fn stepCount(self: Swipe) usize {
        return if (self.steps == 0) 1 else self.steps;
    }

    /// The gesture origin.
    pub fn start(self: Swipe) cl.Vector2 {
        return .{ .x = self.from_x, .y = self.from_y };
    }

    /// The release point.
    pub fn end(self: Swipe) cl.Vector2 {
        return .{ .x = self.to_x, .y = self.to_y };
    }

    /// Interpolated motion point `i` of `stepCount()`.
    pub fn pointAt(self: Swipe, i: usize) cl.Vector2 {
        const n = self.stepCount();
        const k: f32 = @floatFromInt(@min(i, n));
        const denom: f32 = @floatFromInt(n);
        const t = k / denom;
        return .{
            .x = self.from_x + (self.to_x - self.from_x) * t,
            .y = self.from_y + (self.to_y - self.from_y) * t,
        };
    }

    pub fn distance(self: Swipe) f32 {
        const dx = self.to_x - self.from_x;
        const dy = self.to_y - self.from_y;
        return @sqrt(dx * dx + dy * dy);
    }

    pub fn up(x: f32, y: f32, dist: f32) Swipe {
        return .{ .from_x = x, .from_y = y, .to_x = x, .to_y = y - dist };
    }

    pub fn down(x: f32, y: f32, dist: f32) Swipe {
        return .{ .from_x = x, .from_y = y, .to_x = x, .to_y = y + dist };
    }

    pub fn left(x: f32, y: f32, dist: f32) Swipe {
        return .{ .from_x = x, .from_y = y, .to_x = x - dist, .to_y = y };
    }

    pub fn right(x: f32, y: f32, dist: f32) Swipe {
        return .{ .from_x = x, .from_y = y, .to_x = x + dist, .to_y = y };
    }
};

// ---- Test doubles ----

fn sample() sm.Node {
    return .{
        .id = cl.getElementId("n"),
        .tag = "n",
        .found = true,
        .bounds = .{ .x = 0, .y = 0, .width = 50, .height = 40 },
        .clip = .{ .x = 0, .y = 0, .width = 200, .height = 100 },
        .visible_fraction = 1,
    };
}

test "revealDelta is zero when the node already fits" {
    const n = sample();
    try std.testing.expect(revealDelta(n).isZero());
}

test "revealDelta scrolls down for a node below the viewport" {
    var n = sample();
    // Node sits at y=300 with the viewport ending at 100: 240px too low.
    n.bounds.y = 300;
    n.visible_fraction = 0;
    const d = revealDelta(n);
    try std.testing.expectApproxEqAbs(@as(f32, 240), d.dy, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), d.dx, 0.001);
    // Positive dy = scroll down = content up, which is what brings it in.
    try std.testing.expect(d.dy > 0);
}

test "revealDelta scrolls up for a node above the viewport" {
    var n = sample();
    n.clip.y = 100; // viewport starts at 100
    n.bounds.y = 40; // node is 60px above it
    n.visible_fraction = 0;
    const d = revealDelta(n);
    try std.testing.expectApproxEqAbs(@as(f32, -60), d.dy, 0.001);
    try std.testing.expect(d.dy < 0);
}

test "revealDelta aligns the leading edge of an oversized node" {
    var n = sample();
    // Taller than the 100px viewport: fitting is impossible, so the top of the node is parked at the top of the viewport instead of oscillating.
    n.bounds.height = 400;
    n.bounds.y = 250;
    n.visible_fraction = 0.25;
    const d = revealDelta(n);
    try std.testing.expectApproxEqAbs(@as(f32, 250), d.dy, 0.001);
}

test "revealDelta handles the horizontal axis independently" {
    var n = sample();
    n.clip.width = 100;
    n.bounds.x = 160; // 110px past the right edge
    n.visible_fraction = 0;
    const d = revealDelta(n);
    try std.testing.expectApproxEqAbs(@as(f32, 110), d.dx, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0), d.dy, 0.001);
}

test "revealDelta is a no-op for a node that was never laid out" {
    var n = sample();
    n.found = false;
    try std.testing.expect(revealDelta(n).isZero());
}

test "wheelUnitsForPixels inverts Clay's x10 wheel factor" {
    try std.testing.expectApproxEqAbs(@as(f32, 5), wheelUnitsForPixels(50), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 120), wheelUnitsForPixels(1200), 0.0001);
    try std.testing.expectEqual(@as(f32, 0), wheelUnitsForPixels(0));
}

test "Swipe interpolates from start to end, landing exactly on the end" {
    const s = Swipe.up(100, 200, 80);
    try std.testing.expectEqual(@as(f32, 100), s.start().x);
    try std.testing.expectEqual(@as(f32, 200), s.start().y);
    try std.testing.expectEqual(@as(f32, 120), s.end().y);
    // Midpoint of a 4-step swipe.
    const mid = s.pointAt(2);
    try std.testing.expectApproxEqAbs(@as(f32, 100), mid.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 160), mid.y, 0.001);
    // The last step lands exactly on the end: no overshoot.
    try std.testing.expectApproxEqAbs(s.end().y, s.pointAt(s.stepCount()).y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 80), s.distance(), 0.001);
}

test "Swipe direction constructors move on the right axis" {
    try std.testing.expect(Swipe.down(0, 0, 30).to_y > 0);
    try std.testing.expect(Swipe.up(0, 30, 30).to_y == 0);
    try std.testing.expect(Swipe.left(30, 0, 30).to_x == 0);
    try std.testing.expect(Swipe.right(0, 0, 30).to_x > 0);
    // A degenerate step count still produces a usable single step.
    const s = Swipe{ .from_x = 0, .from_y = 0, .to_x = 10, .to_y = 0, .steps = 0 };
    try std.testing.expectEqual(@as(usize, 1), s.stepCount());
    try std.testing.expectApproxEqAbs(@as(f32, 10), s.pointAt(1).x, 0.001);
}
