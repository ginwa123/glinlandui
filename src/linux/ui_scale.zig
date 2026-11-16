//! Display density for the Wayland backend: the outputs a surface is on, the scale each one reports, and the one value they resolve to.
const std = @import("std");
const scale = @import("../core/scale.zig");

/// Outputs watched at once. A machine with more than four monitors gets the largest scale among the first four, which is still supersampled rather than blurry.
pub const max_outputs: usize = 4;

/// One output as this window knows it: the registry name it was announced under, the bound proxy, its own integer scale, and whether the surface has entered it.
pub const Output = struct {
    registry_name: u32 = 0,
    proxy: ?*anyopaque = null,
    scale: i32 = 1,
    entered: bool = false,

    fn vacant(self: Output) bool {
        return self.registry_name == 0 and self.proxy == null;
    }
};

/// The outputs this surface is on, and the rule that turns them into a single scale: the largest of the ones it has ENTERED.
pub const Watch = struct {
    outputs: [max_outputs]Output = [_]Output{.{}} ** max_outputs,
    /// `wl_surface.preferred_buffer_scale`, the compositor's own answer, which fractional-scale compositors round UP (so a 1.5x output asks for a 2x buffer).
    preferred: i32 = 0,

    /// Reserve a slot for a global the registry announced, before its proxy is bound.
    pub fn announce(self: *Watch, registry_name: u32) bool {
        for (&self.outputs) |*o| {
            if (o.registry_name == registry_name) return true;
            if (o.vacant()) {
                o.* = .{ .registry_name = registry_name };
                return true;
            }
        }
        return false;
    }

    /// Attach the bound proxy to the slot that announced it.
    pub fn attach(self: *Watch, registry_name: u32, proxy: ?*anyopaque) void {
        for (&self.outputs) |*o| {
            if (o.registry_name == registry_name) {
                o.proxy = proxy;
                return;
            }
        }
    }

    /// Drop an output: a registry `global_remove`, or the window tearing down. Its `entered` flag goes with it.
    pub fn forget(self: *Watch, proxy: ?*anyopaque) void {
        if (proxy == null) return;
        for (&self.outputs) |*o| {
            if (o.proxy == proxy) o.* = .{};
        }
    }

    /// Record one output's `scale` event. A compositor may send 0 for "unknown", which is kept as 1.
    pub fn setScale(self: *Watch, proxy: ?*anyopaque, factor: i32) void {
        if (self.find(proxy)) |o| o.scale = if (factor < 1) 1 else factor;
    }

    /// Record `wl_surface.enter`: this surface is on that output now.
    pub fn enter(self: *Watch, proxy: ?*anyopaque) void {
        if (self.find(proxy)) |o| o.entered = true;
    }

    /// Record `wl_surface.leave`: it is not on that output any more, so its scale must stop counting.
    pub fn leave(self: *Watch, proxy: ?*anyopaque) void {
        if (self.find(proxy)) |o| o.entered = false;
    }

    /// Record `wl_surface.preferred_buffer_scale`.
    pub fn setPreferred(self: *Watch, factor: i32) void {
        self.preferred = if (factor < 1) 0 else factor;
    }

    /// The scale to render at: the largest among the outputs the surface has entered, never below 1 and never above `scale.max_scale`.
    pub fn effective(self: *const Watch) f32 {
        var entered_max: i32 = 0;
        var known_max: i32 = 0;
        for (&self.outputs) |*o| {
            if (o.proxy == null) continue;
            known_max = @max(known_max, o.scale);
            if (o.entered) entered_max = @max(entered_max, o.scale);
        }
        // No enter event yet (some compositors send it only after the first commit): the largest known output is the best answer available.
        const from_outputs: i32 = if (entered_max > 0) entered_max else known_max;
        const raw: i32 = @max(from_outputs, self.preferred);
        if (raw <= 0) return 1.0;
        return scale.clampScale(@floatFromInt(raw));
    }

    fn find(self: *Watch, proxy: ?*anyopaque) ?*Output {
        if (proxy == null) return null;
        for (&self.outputs) |*o| {
            if (o.proxy == proxy) return o;
        }
        return null;
    }
};

/// The density the live window draws at. The toolkit runs one window per process, so one value is the whole state; `renderer.zig` reads it per frame.
var applied: f32 = 1.0;

/// Adopt a density, clamped through `core/scale.zig` so no backend can disagree about what 2x means.
pub fn setApplied(s: f32) void {
    applied = scale.clampScale(s);
}

/// The density the renderer must rasterise at.
pub fn current() f32 {
    return applied;
}

// A surface on a 1x and a 2x output renders at 2x: the buffer is displayed unscaled on the dense one and downsampled on the other.
test "the densest output the surface is on sets the scale" {
    var w = Watch{};
    try std.testing.expect(w.announce(1));
    try std.testing.expect(w.announce(2));
    w.attach(1, @ptrFromInt(0x1000));
    w.attach(2, @ptrFromInt(0x2000));
    w.setScale(@ptrFromInt(0x1000), 1);
    w.setScale(@ptrFromInt(0x2000), 2);
    w.enter(@ptrFromInt(0x1000));
    w.enter(@ptrFromInt(0x2000));
    try std.testing.expectEqual(@as(f32, 2.0), w.effective());
}

test "an output the surface has not entered cannot raise the scale" {
    var w = Watch{};
    _ = w.announce(1);
    _ = w.announce(2);
    w.attach(1, @ptrFromInt(0x1000));
    w.attach(2, @ptrFromInt(0x2000));
    w.setScale(@ptrFromInt(0x1000), 1);
    w.setScale(@ptrFromInt(0x2000), 3);
    w.enter(@ptrFromInt(0x1000));
    try std.testing.expectEqual(@as(f32, 1.0), w.effective());
}

test "leaving the dense output drops the scale back to what is left" {
    var w = Watch{};
    _ = w.announce(1);
    _ = w.announce(2);
    w.attach(1, @ptrFromInt(0x1000));
    w.attach(2, @ptrFromInt(0x2000));
    w.setScale(@ptrFromInt(0x1000), 1);
    w.setScale(@ptrFromInt(0x2000), 2);
    w.enter(@ptrFromInt(0x1000));
    w.enter(@ptrFromInt(0x2000));
    w.leave(@ptrFromInt(0x2000));
    try std.testing.expectEqual(@as(f32, 1.0), w.effective());
    w.leave(@ptrFromInt(0x1000));
    // Nothing entered at all falls back to the outputs that exist, which is still better than pretending 1x.
    try std.testing.expectEqual(@as(f32, 2.0), w.effective());
}

test "before any enter event the largest known output is used" {
    var w = Watch{};
    _ = w.announce(1);
    _ = w.announce(2);
    w.attach(1, @ptrFromInt(0x1000));
    w.attach(2, @ptrFromInt(0x2000));
    w.setScale(@ptrFromInt(0x1000), 1);
    w.setScale(@ptrFromInt(0x2000), 2);
    try std.testing.expectEqual(@as(f32, 2.0), w.effective());
}

test "the compositor's preferred buffer scale wins over an output that reports less" {
    var w = Watch{};
    _ = w.announce(1);
    w.attach(1, @ptrFromInt(0x1000));
    w.setScale(@ptrFromInt(0x1000), 1);
    w.enter(@ptrFromInt(0x1000));
    w.setPreferred(2);
    try std.testing.expectEqual(@as(f32, 2.0), w.effective());
}

test "an output that vanishes stops counting, even though it was entered" {
    var w = Watch{};
    _ = w.announce(1);
    _ = w.announce(2);
    w.attach(1, @ptrFromInt(0x1000));
    w.attach(2, @ptrFromInt(0x2000));
    w.setScale(@ptrFromInt(0x1000), 2);
    w.setScale(@ptrFromInt(0x2000), 1);
    w.enter(@ptrFromInt(0x1000));
    w.enter(@ptrFromInt(0x2000));
    w.forget(@ptrFromInt(0x1000));
    try std.testing.expectEqual(@as(f32, 1.0), w.effective());
}

test "a nonsense scale is read as 1x, and an absurd one is clamped to the toolkit ceiling" {
    var w = Watch{};
    _ = w.announce(1);
    w.attach(1, @ptrFromInt(0x1000));
    w.enter(@ptrFromInt(0x1000));
    w.setScale(@ptrFromInt(0x1000), 0);
    try std.testing.expectEqual(@as(f32, 1.0), w.effective());
    w.setScale(@ptrFromInt(0x1000), -7);
    try std.testing.expectEqual(@as(f32, 1.0), w.effective());
    w.setScale(@ptrFromInt(0x1000), 99);
    try std.testing.expectEqual(scale.max_scale, w.effective());
}

test "the applied density is what the renderer reads, and it never goes below 1x" {
    setApplied(2.0);
    defer setApplied(1.0);
    try std.testing.expectEqual(@as(f32, 2.0), current());
    setApplied(0);
    try std.testing.expectEqual(@as(f32, 1.0), current());
    setApplied(std.math.nan(f32));
    try std.testing.expectEqual(@as(f32, 1.0), current());
}

test "watching more outputs than there is room for reports the overflow instead of scribbling" {
    var w = Watch{};
    for (0..max_outputs) |i| try std.testing.expect(w.announce(@intCast(i + 1)));
    try std.testing.expect(!w.announce(99));
    try std.testing.expectEqual(@as(f32, 1.0), w.effective());
}
