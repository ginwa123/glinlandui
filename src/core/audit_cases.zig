// Frame-level fixtures for the audit: each one declares a REAL violation through the real components, and the test asserts the audit names it. The unit

// tests in `audit.zig` prove the checks fire on synthetic commands; these prove the wiring — that a violation declared the way an app declares one

// actually reaches the audit. A verifier that has only ever passed is indistinguishable from one that never ran.
const std = @import("std");
const cl = @import("zclay");
const testing = std.testing;

const audit = @import("audit.zig");
const frame_mod = @import("frame.zig");
const Host = @import("host.zig");
const Driver = @import("testing/root.zig").Driver;
const box_mod = @import("components/box.zig");
const button = @import("components/button.zig");
const text_mod = @import("components/text.zig");
const registry = @import("components/click_registry.zig");

// Records every finding the audit reports during one frame.
const Findings = struct {
    kinds: [16]audit.Kind = undefined,
    n: usize = 0,

    fn sink(f: audit.Finding) void {
        const self: *Findings = @ptrCast(@alignCast(recording.?));
        if (self.n < self.kinds.len) {
            self.kinds[self.n] = f.kind;
            self.n += 1;
        }
    }

    fn has(self: *const Findings, kind: audit.Kind) bool {
        for (self.kinds[0..self.n]) |k| {
            if (k == kind) return true;
        }
        return false;
    }
};

var recording: ?*Findings = null;

// Render one frame of `root` and return what the audit said about it.
fn frameOf(root: Host.RootFn) !Findings {
    var found = Findings{};
    recording = &found;
    audit.sink = Findings.sink;
    defer {
        audit.sink = null;
        recording = null;
    }

    var driver = try Driver.initOwned(std.heap.page_allocator, null, root);
    defer driver.deinit();
    try driver.start(.{ .width = 400, .height = 300 });
    driver.frame();
    return found;
}

const NoCtx = struct {};

fn noChildren(_: NoCtx) void {}

// ---- the cases ----

test "audit case: two elements with one id are caught where they are declared" {
    const Dups = struct {
        var seen: usize = 0;
        var msg: [64]u8 = undefined;
        var msg_len: usize = 0;

        fn sink(m: []const u8) void {
            seen += 1;
            const n = @min(m.len, msg.len);
            @memcpy(msg[0..n], m[0..n]);
            msg_len = n;
        }
    };
    Dups.seen = 0;
    Dups.msg_len = 0;
    frame_mod.duplicate_id_sink = Dups.sink;
    defer frame_mod.duplicate_id_sink = null;

    const root = struct {
        fn declare(_: ?*anyopaque, _: u32, _: u32) void {
            button.button(.{ .id = "dup.id", .label = "one" });
            button.button(.{ .id = "dup.id", .label = "two" });
        }
    }.declare;

    var driver = try Driver.initOwned(std.heap.page_allocator, null, root);
    defer driver.deinit();
    try driver.start(.{ .width = 200, .height = 100 });
    driver.frame();

    // Clay's message does not name the id ("An element with this ID was already previously declared"), so the check is that the duplicate is caught at all —

    // the panic stops the build where the second declaration is.
    try testing.expect(Dups.seen >= 1);
    try testing.expect(Dups.msg_len > 0);
}

test "audit case: a click target with no element is reported" {
    const root = struct {
        fn declare(_: ?*anyopaque, _: u32, _: u32) void {
            button.button(.{ .id = "real", .label = "OK" });
            registry.registerClick(cl.getElementId("never.declared"), noop, null);
        }
        fn noop(_: ?*anyopaque) void {}
    }.declare;

    const found = try frameOf(root);
    try testing.expect(found.has(.hit_target_missing));
}

test "audit case: a click target with an empty box is reported" {
    const root = struct {
        fn declare(_: ?*anyopaque, _: u32, _: u32) void {
            box_mod.box(.{ .id = "zero", .w = .{ .fixed = 0 }, .h = .{ .fixed = 0 } }, NoCtx{}, noChildren);
            registry.registerClick(cl.getElementId("zero"), noop, null);
        }
        fn noop(_: ?*anyopaque) void {}
    }.declare;

    const found = try frameOf(root);
    try testing.expect(found.has(.hit_target_empty));
}

test "audit case: a target that loses its own centre to a sibling is reported" {
    const root = struct {
        fn declare(_: ?*anyopaque, _: u32, _: u32) void {
            // Two overlapping targets, neither inside the other, at the same z: the click is ambiguous.
            box_mod.box(.{ .id = "left", .w = .{ .fixed = 100 }, .h = .{ .fixed = 40 } }, NoCtx{}, noChildren);
            cl.UI()(.{
                .id = .ID("right"),
                .layout = .{ .sizing = .{ .w = .fixed(100), .h = .fixed(40) } },
                .floating = .{
                    .offset = .{ .x = 50, .y = 0 },
                    .attach_to = .to_parent,
                    .attach_points = .{ .element = .left_top, .parent = .left_top },
                },
            })({});
            registry.registerClick(cl.getElementId("left"), noop, null);
            registry.registerClick(cl.getElementId("right"), noop, null);
        }
        fn noop(_: ?*anyopaque) void {}
    }.declare;

    const found = try frameOf(root);
    try testing.expect(found.has(.hit_target_not_self));
}

test "audit case: a clean frame reports nothing" {
    const root = struct {
        fn declare(_: ?*anyopaque, _: u32, _: u32) void {
            box_mod.box(.{ .id = "card", .w = .grow, .h = .grow, .direction = .column, .gap = 8, .pad = 8 }, NoCtx{}, children);
        }
        fn children(_: NoCtx) void {
            button.button(.{ .id = "card.ok", .label = "OK", .on_click = noop, .ctx = null });
            text_mod.label(.{ .str = "short", .font_size = 14 });
        }
        fn noop(_: ?*anyopaque) void {}
    }.declare;

    const found = try frameOf(root);
    try testing.expectEqual(@as(usize, 0), found.n);
}
