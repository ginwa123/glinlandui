//! The glide a wheel gesture leaves behind: the engine's own momentum, for a host whose OS animates no flick.
const std = @import("std");

/// How long the wheel must be silent before the engine takes over. The browser exposes no gesture phase, only the silence: AppKit and Windows deliver their own momentum as more wheel events, one per refresh, so a host that animates a flick never leaves this gap, and a hand that came to rest before lifting leaves a speed too low to glide at all.
pub const takeover_s: f32 = 0.064;

/// The fastest glide a gesture can hand over, in points per second: a hard flick, and the ceiling that keeps a burst of events arriving in one frame from turning into a lurch nobody asked for.
pub const max_speed: f32 = 3000.0;

/// The slowest glide worth a frame, in points per second: one and a half points a frame at 60 Hz, so the tail never asks for a frame that moves nothing.
pub const min_speed: f32 = 90.0;

/// How fast a glide dies away, per second: `v(t) = v0 * e^(-decay_s * t)`, so a 2000 pt/s flick travels about 555 points and takes 0.86 s to fall under `min_speed`.
pub const decay_s: f32 = 3.6;

/// The longest silence between two deltas of the SAME gesture, in seconds: the slowest frame interval the velocity window trusts below. A continuous device reports on every frame of a 30 Hz loop, so anything sparser is a new gesture rather than a continuation of this one.
pub const sample_gap_s: f32 = 1.0 / 30.0;

/// How many frames of one gesture must carry a delta before the engine may invent motion of its own. A mouse wheel is a DETENT: one whole notch arrives in one frame and the next only when the hand turns the wheel again, so a single frame of delta is an impulse with no speed in it. A trackpad reports the fingers on frame after frame, and only a run of three such frames is a gesture rather than two notches that happened to land in back-to-back frames.
pub const min_samples: u16 = 3;

/// The longest interval one frame may integrate, so a host that stalled for a quarter of a second does not teleport the content on the frame it recovers.
pub const max_step_s: f32 = 0.05;

/// One frame's worth of travel, in the same units and sign the wheel reported.
pub const Delta = struct { dx: f32, dy: f32 };

/// A flick's velocity and the frame-by-frame travel it still owes after the fingers left the trackpad.
pub const Glide = struct {
    /// Speed in points per second per axis, in the wheel's own sign.
    vx: f32 = 0,
    vy: f32 = 0,
    /// Seconds since the last wheel delta arrived.
    idle_s: f32 = 0,
    /// True while this glide is the thing moving the content.
    moving: bool = false,
    /// A wheel delta arrived since the last `advance`, so this frame's motion is the gesture's and not the glide's.
    fed: bool = false,
    /// The wheel is still being delivered frame after frame: the gesture owns the content.
    gesture: bool = false,
    /// Frames of the current gesture that carried a delta, so an impulse is never mistaken for a measured velocity.
    samples: u16 = 0,

    /// Measure one frame of gesture from the delta the backend delivered in it. The caller applies that delta; this only reads how fast it arrived.
    pub fn feed(self: *Glide, dx: f32, dy: f32, dt: f32) void {
        if (!(dt > 0)) return;
        // A delta that follows more than a frame's silence opens a new gesture, so the count restarts: a detent is one sample, and the next detent is not its second.
        self.samples = if (self.idle_s > sample_gap_s) 1 else self.samples +| 1;
        // The interval a frame was delivered in, bounded: an idle tab's first frame back is a quarter second and a busy one is two milliseconds, and neither is a gesture's speed.
        const window = std.math.clamp(dt, 1.0 / 240.0, 1.0 / 30.0);
        const speed_x = std.math.clamp(dx / window, -max_speed, max_speed);
        const speed_y = std.math.clamp(dy / window, -max_speed, max_speed);
        self.vx = blend(self.gesture, self.vx, speed_x);
        self.vy = blend(self.gesture, self.vy, speed_y);
        self.gesture = true;
        self.fed = true;
        self.idle_s = 0;
        // The fingers are in charge again: a glide must never add to a gesture that is still being delivered.
        self.moving = false;
    }

    /// The travel this frame owes, or null when the gesture has the content and the glide has nothing to add.
    pub fn advance(self: *Glide, dt: f32) ?Delta {
        if (self.fed) {
            self.fed = false;
            return null;
        }
        if (!(dt > 0)) return null;
        // No delta this frame, so the gesture is over as far as the engine can tell.
        self.gesture = false;
        self.idle_s += dt;
        if (!self.moving) {
            if (self.idle_s < takeover_s) return null;
            // A detent, a scrollbar jump and a Home key are all ONE frame of delta: an impulse, whose "velocity" is only how far it was told to move.
            if (self.samples < min_samples or !self.fastEnough()) {
                self.end();
                return null;
            }
            self.moving = true;
        }
        const step = @min(dt, max_step_s);
        const keep = @exp(-decay_s * step);
        self.vx *= keep;
        self.vy *= keep;
        if (!self.fastEnough()) {
            self.end();
            return null;
        }
        return .{ .dx = self.vx * step, .dy = self.vy * step };
    }

    /// A gesture in progress is smoothed, so one jittery frame cannot decide how far the flick travels; the first frame of a gesture IS the measurement, and so is a frame that reverses it.
    fn blend(continuing: bool, previous: f32, sample: f32) f32 {
        if (!continuing or previous * sample < 0) return sample;
        return 0.5 * previous + 0.5 * sample;
    }

    /// True while a glide is still owed frames: what a backend asks before it idles.
    pub fn isMoving(self: *const Glide) bool {
        return self.moving;
    }

    /// True while a takeover is still possible but the gap it waits for has not elapsed. The host has to keep the frames coming through that gap, or the glide can never start: nothing else would wake it.
    pub fn pending(self: *const Glide) bool {
        return !self.moving and self.idle_s < takeover_s and self.samples >= min_samples and self.fastEnough();
    }

    /// End the glide now, so nothing is owed after this frame.
    pub fn end(self: *Glide) void {
        self.moving = false;
        self.vx = 0;
        self.vy = 0;
        // The gesture is spent, so the next delta is the first sample of a new one rather than the second of this one.
        self.samples = 0;
    }

    fn fastEnough(self: *const Glide) bool {
        return @abs(self.vx) >= min_speed or @abs(self.vy) >= min_speed;
    }
};

/// Run a glance: `frames` frames at `dt`, the first `gesture_frames` of them carrying one delta each, and report how far the content travelled.
fn travelled(glide: *Glide, v: f32, dt: f32, gesture_frames: usize, frames: usize) f32 {
    var total: f32 = 0;
    var i: usize = 0;
    while (i < frames) : (i += 1) {
        if (i < gesture_frames) {
            glide.feed(0, v * dt, dt);
            continue;
        }
        if (glide.advance(dt)) |d| total += d.dy;
    }
    return total;
}

/// Advance until the glide takes over, as a real host would: frame after frame of silence, up to a second of them.
fn takeOver(g: *Glide, dt: f32) ?Delta {
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        if (g.advance(dt)) |d| return d;
    }
    return null;
}

/// One frame's worth of delta, repeated: a continuous device reporting on frame after frame.
fn flick(g: *Glide, v: f32, dt: f32, frames: usize) void {
    var i: usize = 0;
    while (i < frames) : (i += 1) g.feed(0, v * dt, dt);
}

test "a wheel detent measured in one frame leaves no glide" {
    var g = Glide{};
    // A mouse wheel is a DETENT: one whole notch arrives as one event, and nothing follows it until the hand turns the wheel again.
    g.feed(0, 60.0, 0.016);
    var total: f32 = 0;
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        if (g.advance(0.016)) |d| total += d.dy;
    }
    // One sample is an impulse, not a gesture: there is no speed in it to hand over, so the list must stop where the notch left it.
    try std.testing.expectEqual(@as(f32, 0), total);
    try std.testing.expect(!g.isMoving());
}

test "a detent asks for no frame of its own, so a notch costs exactly the frame it arrived in" {
    var g = Glide{};
    g.feed(0, 60.0, 0.016);
    _ = g.advance(0.016);
    // A host that draws only when an engine asks would otherwise paint a second of frames for one click of the wheel.
    try std.testing.expect(!g.pending());
}

test "a flick measured over consecutive frames still coasts" {
    var g = Glide{};
    flick(&g, 2000.0, 0.016, 3);
    const first = takeOver(&g, 0.016) orelse return error.TestExpectedGlide;
    try std.testing.expect(first.dy > 0);
    try std.testing.expect(g.isMoving());
}

test "a detent following hard on a flick is still just a detent" {
    var g = Glide{};
    flick(&g, 2000.0, 0.016, 3);
    _ = takeOver(&g, 0.016) orelse return error.TestExpectedGlide;
    g.end();
    // The wheel goes quiet for longer than the takeover gap, then one notch: a new gesture, with one sample in it.
    var i: usize = 0;
    while (i < 10) : (i += 1) _ = g.advance(0.016);
    g.feed(0, 60.0, 0.016);
    _ = g.advance(0.016);
    try std.testing.expect(!g.pending());
    var total: f32 = 0;
    i = 0;
    while (i < 200) : (i += 1) {
        if (g.advance(0.016)) |d| total += d.dy;
    }
    try std.testing.expectEqual(@as(f32, 0), total);
}

test "a flick keeps moving after the wheel goes quiet" {
    var g = Glide{};
    // A 2000 pt/s flick over a few frames, then silence: the frames after it must still move the content, and in the same direction.
    flick(&g, 2000.0, 0.016, 3);
    const first = takeOver(&g, 0.016) orelse return error.TestExpectedGlide;
    try std.testing.expect(first.dy > 0);
    try std.testing.expect(g.isMoving());
    // And the content keeps arriving, frame after frame, without another wheel event.
    var moved: usize = 0;
    while (g.advance(0.016)) |d| {
        try std.testing.expect(d.dy > 0);
        moved += 1;
        if (moved > 200) break;
    }
    try std.testing.expect(moved > 10);
}

test "the glide starts only after a quiet gap, so an OS that animates the flick keeps the engine out of it" {
    var g = Glide{};
    // A host that delivers its own momentum sends an event every refresh: sixty frames of that must produce no glide at all.
    var total: f32 = 0;
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        g.feed(0, 1200.0 * 0.016, 0.016);
        if (g.advance(0.016)) |d| total += d.dy;
    }
    try std.testing.expectEqual(@as(f32, 0), total);
    try std.testing.expect(!g.isMoving());
}

test "a gesture that had already stopped before it was released leaves no glide" {
    var g = Glide{};
    // 40 pt/s is a drag that came to rest: lifting there must not start a wheel spinning on its own.
    g.feed(0, 40.0 * 0.016, 0.016);
    var total: f32 = 0;
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        if (g.advance(0.016)) |d| total += d.dy;
    }
    try std.testing.expectEqual(@as(f32, 0), total);
    try std.testing.expect(!g.isMoving());
}

test "a glide ends on its own and stays ended" {
    var g = Glide{};
    flick(&g, 2500.0, 0.016, 3);
    const first = takeOver(&g, 0.016) orelse return error.TestExpectedGlide;
    var frames: usize = 0;
    var previous: f32 = first.dy;
    while (frames < 400) : (frames += 1) {
        const d = g.advance(0.016) orelse break;
        try std.testing.expect(d.dy > 0);
        // A glide only ever slows down; a frame that sped up would be a sign flip or a growth bug.
        try std.testing.expect(d.dy < previous);
        previous = d.dy;
    }
    // Long enough to be felt, short enough to end: about a second at 60 Hz, and never a spin.
    try std.testing.expect(frames > 10 and frames < 120);
    try std.testing.expect(!g.isMoving());
    try std.testing.expect(g.advance(0.016) == null);
    try std.testing.expect(g.advance(0.016) == null);
}

test "a glide covers the same ground at 60 Hz and at 120 Hz" {
    var slow = Glide{};
    var fast = Glide{};
    const at_60 = travelled(&slow, 1800.0, 1.0 / 60.0, 4, 90);
    const at_120 = travelled(&fast, 1800.0, 1.0 / 120.0, 8, 180);
    // Same wall-clock second on both displays: the decay is per second, so the two totals agree to within the integration error.
    try std.testing.expectApproxEqRel(at_60, at_120, 0.02);
    try std.testing.expect(at_60 > 100 and at_60 < 600);
}

test "a new gesture cancels the glide instead of adding to it" {
    var g = Glide{};
    flick(&g, 3000.0, 0.016, 3);
    _ = takeOver(&g, 0.016) orelse return error.TestExpectedGlide;
    try std.testing.expect(g.isMoving());
    // Fingers back on the trackpad, moving the other way.
    g.feed(0, -200.0 * 0.016, 0.016);
    try std.testing.expect(!g.isMoving());
    // And the glide stays out of it for the whole gesture.
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        g.feed(0, -3.2, 0.016);
        try std.testing.expect(g.advance(0.016) == null);
    }
}

test "the first glide frame moves less than the flick's last frame" {
    var g = Glide{};
    const last = 2000.0 * 0.016;
    flick(&g, 2000.0, 0.016, 3);
    const first = takeOver(&g, 0.016) orelse return error.TestExpectedGlide;
    // A flick must not gain speed when the engine takes it over, or the lift reads as a shove.
    try std.testing.expect(first.dy < last);
}

test "a burst of events in one frame is spent in that frame and leaves no glide" {
    var g = Glide{};
    // Two hundred events landing between two frames is a programmatic scroll or a synthetic test, not a gesture: it must not become a lurch.
    g.feed(0, 40000.0, 0.016);
    try std.testing.expect(!g.pending());
    try std.testing.expect(takeOver(&g, 0.016) == null);
}

test "a gesture faster than a hand can flick is capped, not amplified" {
    var g = Glide{};
    // Measured over frames, a wild delta is still clamped to `max_speed`, so the hand-over cannot outrun what the gesture delivered.
    flick(&g, 40000.0 / 0.016, 0.016, 3);
    const first = takeOver(&g, 0.016) orelse return error.TestExpectedGlide;
    try std.testing.expect(first.dy <= max_speed * 0.016);
}

test "two notches that land in back-to-back frames still leave no glide" {
    var g = Glide{};
    // A wheel spun hard is still a wheel: two detents, two samples, and nothing between them that a hand could have kept up for a third frame.
    g.feed(0, 60.0, 0.016);
    g.feed(0, 60.0, 0.016);
    try std.testing.expect(!g.pending());
    try std.testing.expect(takeOver(&g, 0.016) == null);
}

test "a frame that reverses the gesture is the measurement, not an average of the two directions" {
    var g = Glide{};
    // A burst one way, then a flick the other: averaging those two would cancel both and leave the content dead still.
    g.feed(0, -4000.0 * 0.016, 0.016);
    g.feed(0, -4000.0 * 0.016, 0.016);
    g.feed(0, 2000.0 * 0.016, 0.016);
    const first = takeOver(&g, 0.016) orelse return error.TestExpectedGlide;
    try std.testing.expect(first.dy > 0);
}

test "a stalled host does not teleport the content on the frame it recovers" {
    var g = Glide{};
    flick(&g, 4000.0, 0.016, 3);
    _ = takeOver(&g, 0.016) orelse return error.TestExpectedGlide;
    // A quarter-second hitch: the travel is capped at `max_step_s` worth of speed, not a quarter second of it.
    const d = g.advance(0.25) orelse return error.TestExpectedGlide;
    try std.testing.expect(d.dy < 4000.0 * max_step_s);
}

test "the gap before a takeover asks for the frames that measure it" {
    var g = Glide{};
    flick(&g, 2000.0, 0.016, 3);
    _ = g.advance(0.016);
    // No event will arrive to wake the engine, so a host that only draws when it is asked would never start the coast.
    try std.testing.expect(g.pending());
    while (g.advance(0.016) == null) {
        if (!g.pending()) break;
    }
    try std.testing.expect(g.isMoving());
    try std.testing.expect(!g.pending());
}

test "a gesture too slow to coast asks for no frames at all" {
    var g = Glide{};
    g.feed(0, 20.0 * 0.016, 0.016);
    _ = g.advance(0.016);
    try std.testing.expect(!g.pending());
}

test "a horizontal flick glides sideways and leaves the vertical axis alone" {
    var g = Glide{};
    var i: usize = 0;
    while (i < 3) : (i += 1) g.feed(1500.0 * 0.016, 0, 0.016);
    const d = takeOver(&g, 0.016) orelse return error.TestExpectedGlide;
    try std.testing.expect(d.dx > 0);
    try std.testing.expectEqual(@as(f32, 0), d.dy);
}

test "ending a glide early owes nothing more" {
    var g = Glide{};
    flick(&g, 5000.0, 0.016, 3);
    _ = takeOver(&g, 0.016) orelse return error.TestExpectedGlide;
    g.end();
    try std.testing.expect(!g.isMoving());
    try std.testing.expect(g.advance(0.016) == null);
    try std.testing.expect(g.advance(0.016) == null);
}
