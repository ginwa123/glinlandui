// The composition: what survives a frame.
// In Compose the runtime keeps a slot table; a composable re-runs and `remember` hands it back what it stored
// last time. An immediate-mode frame has no call stack to walk, so a slot is keyed by the id the element
// already needs — and its value lives until the composition is thrown away.
// Nothing here allocates per frame: one arena, sized once, and a slot's address never moves, which is what
// lets a remembered value hold a pointer to another remembered value.
const std = @import("std");
const glinlandui = @import("glinlandui");
const flow_mod = @import("flow.zig");

// How many remembered values one composition may hold, and the bytes they share.
pub const max_slots: usize = 32;
pub const slot_bytes: usize = 32 * 1024;
// A slot key is copied, so it may be a formatted string rather than a literal. Longer keys are a bug.
pub const max_key_len: usize = 48;

const Slot = struct {
    key: [max_key_len]u8 = undefined,
    key_len: usize = 0,
    value: *anyopaque = undefined,
};

// `effect` remembers this, not the value it ran: whether it ever ran, and the key it last ran for.
const EffectSlot = struct {
    ran: bool = false,
    signature: u64 = 0,
};

pub const Composition = struct {
    slots: [max_slots]Slot = undefined,
    slot_count: usize = 0,
    arena: [slot_bytes]u8 align(16) = undefined,
    arena_used: usize = 0,

    // Set when a collected flow published. The app turns it into a frame request; a test reads it directly.
    invalidated: bool = false,
    on_invalidate: ?*const fn (?*anyopaque) void = null,
    invalidate_ctx: ?*anyopaque = null,

    // `remember`: the value behind `key`, created on the first call and handed back unchanged afterwards.
    // The returned pointer is stable for the life of the composition, so a callback may capture it.
    pub fn remember(self: *Composition, comptime T: type, key: []const u8, initial: T) *T {
        if (self.find(key)) |slot| return @ptrCast(@alignCast(slot.value));
        const start = std.mem.alignForward(usize, self.arena_used, @alignOf(T));
        const end = start + @sizeOf(T);
        if (self.slot_count >= max_slots or end > self.arena.len or key.len > max_key_len) {
            @panic("composition: slot table exhausted");
        }
        const value: *T = @ptrCast(@alignCast(&self.arena[start]));
        value.* = initial;
        self.arena_used = end;

        const slot = &self.slots[self.slot_count];
        @memcpy(slot.key[0..key.len], key);
        slot.key_len = key.len;
        slot.value = value;
        self.slot_count += 1;
        return value;
    }

    fn find(self: *Composition, key: []const u8) ?*Slot {
        for (self.slots[0..self.slot_count]) |*slot| {
            if (slot.key_len == key.len and std.mem.eql(u8, slot.key[0..slot.key_len], key)) return slot;
        }
        return null;
    }

    // `collectAsState`: read the value now and subscribe this composition, so a publish asks for a frame.
    // Collecting on every frame is the normal case and subscribes once — `collect` is idempotent by context.
    pub fn collectAsState(self: *Composition, comptime T: type, flow: *flow_mod.MutableStateFlow(T)) T {
        flow.collect(.{ .ctx = self, .on_value = onValue });
        return flow.value();
    }

    fn onValue(ctx: ?*anyopaque) void {
        const self: *Composition = @ptrCast(@alignCast(ctx.?));
        self.invalidated = true;
        if (self.on_invalidate) |pump| pump(self.invalidate_ctx);
    }

    // The top of every frame: the flag describes what happened since the last one, not ever.
    pub fn beginFrame(self: *Composition) void {
        self.invalidated = false;
    }

    // `LaunchedEffect(key) { ... }`: run on the first frame, and again whenever `signature` changes.
    pub fn effect(
        self: *Composition,
        key: []const u8,
        signature: u64,
        ctx: anytype,
        comptime run: fn (@TypeOf(ctx)) void,
    ) void {
        const slot = self.remember(EffectSlot, key, .{});
        if (slot.ran and slot.signature == signature) return;
        slot.ran = true;
        slot.signature = signature;
        run(ctx);
    }

    // `setContent { ... }`: hand a composable to a Host as its root function.
    // The ctx the Host was built with is the ctx the composable receives, exactly as `setContent` sees the
    // Activity's own fields.
    pub fn setContent(comptime content: fn (?*anyopaque) void) glinlandui.host.RootFn {
        return struct {
            fn root(ctx: ?*anyopaque, w: u32, h: u32) void {
                _ = w;
                _ = h;
                content(ctx);
            }
        }.root;
    }
};

// ---- tests ---------------------------------------------------------------------------------------------------

test "remember returns the same slot across frames, and keeps what was written to it" {
    var comp = Composition{};
    const first = comp.remember(u32, "a.counter", 0);
    first.* += 7;
    comp.beginFrame();
    const second = comp.remember(u32, "a.counter", 0);
    try std.testing.expect(first == second);
    try std.testing.expectEqual(@as(u32, 7), second.*);
}

test "two keys are two values, and a different type does not alias the first" {
    var comp = Composition{};
    const a = comp.remember(u32, "a", 1);
    const b = comp.remember(u32, "b", 2);
    const c = comp.remember(f64, "c", 3.5);
    try std.testing.expect(a != b);
    try std.testing.expectEqual(@as(u32, 1), a.*);
    try std.testing.expectEqual(@as(u32, 2), b.*);
    try std.testing.expectEqual(@as(f64, 3.5), c.*);
}

test "a collected flow invalidates the composition on publish, and only on publish" {
    var comp = Composition{};
    var flow = flow_mod.MutableStateFlow(u32).init(0);

    try std.testing.expectEqual(@as(u32, 0), comp.collectAsState(u32, &flow));
    try std.testing.expect(!comp.invalidated);

    _ = flow.set(0);
    try std.testing.expect(!comp.invalidated);

    _ = flow.set(1);
    try std.testing.expect(comp.invalidated);

    comp.beginFrame();
    try std.testing.expect(!comp.invalidated);
    // Collecting again must not subscribe twice: the second publish is still one notification.
    _ = comp.collectAsState(u32, &flow);
    try std.testing.expectEqual(@as(usize, 1), flow.collector_count);
}

test "an effect runs once, then again only when its key changes" {
    const Log = struct {
        runs: usize = 0,
        fn run(self: *@This()) void {
            self.runs += 1;
        }
    };
    var comp = Composition{};
    var log = Log{};

    comp.effect("e", 1, &log, Log.run);
    comp.effect("e", 1, &log, Log.run);
    try std.testing.expectEqual(@as(usize, 1), log.runs);

    comp.effect("e", 2, &log, Log.run);
    try std.testing.expectEqual(@as(usize, 2), log.runs);
}

test "setContent is a root function that hands the host's context to the composable" {
    const Seen = struct {
        var called: bool = false;
        fn content(_: ?*anyopaque) void {
            called = true;
        }
    };
    const root = Composition.setContent(Seen.content);
    root(null, 800, 600);
    try std.testing.expect(Seen.called);
}
