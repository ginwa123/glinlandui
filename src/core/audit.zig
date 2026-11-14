//! The frame audit: invariants every frame must satisfy, checked where they can still be named.
//!
//! The tests in this repo check *model state* and *individual widgets*. Neither can see the three failures that cost
//! the most time in this project: a caret drawn as a glyph, a 1 pt hairline sitting between device pixels, and a
//! click target whose id resolves to a different element. All three are mechanically detectable on the frame itself,
//! which is what this file does — on the frames a developer actually runs, not only in a test.
//!
//! Findings go to `sink` when one is installed (a test records them and asserts), and to the log otherwise.
const std = @import("std");
const cl = @import("zclay");
const text_backend = @import("text_backend.zig");
const registry = @import("components/click_registry.zig");

pub const Kind = enum {
    /// A text run is wider than the box the layout gave it: it will be clipped, or overlap whatever is next to it.
    text_wider_than_box,
    /// A rectangle thinner than a device pixel is not on the device grid, so it renders as two half-lit columns.
    hairline_off_grid,
    /// A scissor was started and never ended, so the rest of the frame is clipped.
    unbalanced_scissor,
    /// A registered click target has no element this frame (a stale id, or an id that was never declared).
    hit_target_missing,
    /// A registered click target has an empty box, so nothing can ever be clicked.
    hit_target_empty,
    /// The topmost target at a click target's own centre is a DIFFERENT target.
    hit_target_not_self,
};

pub const Finding = struct {
    kind: Kind,
    /// The element id hash the finding is about (0 when it is not about one element).
    id: u32 = 0,
    detail: [160]u8 = undefined,
    detail_len: usize = 0,

    pub fn text(self: *const Finding) []const u8 {
        return self.detail[0..self.detail_len];
    }
};

/// Receives every finding. A test installs one to assert on; null logs instead.
pub var sink: ?*const fn (Finding) void = null;

/// On by default in a Debug build (and in tests, which are Debug), off in a release build unless `GLIN_AUDIT` is set.
pub var enabled: bool = @import("builtin").mode == .Debug;

/// Turn the audit on or off for this process.
pub fn setEnabled(on: bool) void {
    enabled = on;
}

fn report(f: Finding) void {
    if (sink) |s| {
        s(f);
        return;
    }
    std.log.err("glinlandui audit: {s} ({s})", .{ @tagName(f.kind), f.text() });
}

fn make(kind: Kind, id: u32, comptime fmt: []const u8, args: anytype) Finding {
    var f = Finding{ .kind = kind, .id = id };
    const written = std.fmt.bufPrint(&f.detail, fmt, args) catch "";
    f.detail_len = written.len;
    return f;
}

/// A device-pixel width at or below which a rectangle is a hairline.
const hairline_max_px: f32 = 1.5;

/// Check the command stream. `scale` is device pixels per point.
pub fn checkCommands(commands: []const cl.RenderCommand, scale: f32) usize {
    var findings: usize = 0;
    var depth: i32 = 0;
    for (commands) |cmd| {
        switch (cmd.command_type) {
            .scissor_start => depth += 1,
            .scissor_end => depth -= 1,
            .text => {
                const td = cmd.render_data.text;
                const bytes = td.string_contents.chars[0..@intCast(td.string_contents.length)];
                const measured = text_backend.measureText(bytes, td.font_size).w;
                // One point of slack: the last glyph's right side bearing is not part of its advance.
                if (measured > cmd.bounding_box.width + 1 and cmd.bounding_box.width > 0) {
                    report(make(.text_wider_than_box, cmd.id, "{s} is {d:.1} px wide in a {d:.1} px box", .{
                        bytes, measured, cmd.bounding_box.width,
                    }));
                    findings += 1;
                }
            },
            .rectangle => {
                if (cmd.bounding_box.width <= 0) continue;
                const device_w = cmd.bounding_box.width * scale;
                if (device_w > hairline_max_px) continue;
                const device_x = cmd.bounding_box.x * scale;
                if (@abs(device_x - @round(device_x)) > 0.01) {
                    report(make(.hairline_off_grid, cmd.id, "{d:.1} pt wide at x={d:.2} device px", .{
                        cmd.bounding_box.width, device_x,
                    }));
                    findings += 1;
                }
            },
            else => {},
        }
    }
    if (depth != 0) {
        report(make(.unbalanced_scissor, 0, "{d} scissor(s) left open", .{depth}));
        findings += 1;
    }
    return findings;
}

/// Check every registered click target against this frame's layout.
pub fn checkRegistry() usize {
    var findings: usize = 0;
    var i: usize = 0;
    while (i < registry.hitCount()) : (i += 1) {
        const hit = registry.hitAt(i) orelse continue;
        const data = cl.getElementData(hit.id);
        if (!data.found) {
            report(make(.hit_target_missing, hit.id.id, "entry {d} has no element this frame", .{i}));
            findings += 1;
            continue;
        }
        const bb = data.bounding_box;
        if (bb.width <= 0 or bb.height <= 0) {
            report(make(.hit_target_empty, hit.id.id, "entry {d} is {d:.1}x{d:.1}", .{ i, bb.width, bb.height }));
            findings += 1;
            continue;
        }
    }
    return findings;
}

/// Check that a click at each target's own centre reaches that target.
///
/// Quadratic in the number of targets, so it runs in tests only — the failure it catches (a duplicate or stale id
/// resolving to the wrong box) is a development-time bug, not a per-frame one.
pub fn checkHitConsistency() usize {
    var findings: usize = 0;
    var i: usize = 0;
    while (i < registry.hitCount()) : (i += 1) {
        const hit = registry.hitAt(i) orelse continue;
        const data = cl.getElementData(hit.id);
        if (!data.found) continue;
        const cx = data.bounding_box.x + data.bounding_box.width * 0.5;
        const cy = data.bounding_box.y + data.bounding_box.height * 0.5;
        const winner = registry.topmostAt(cx, cy) orelse continue;
        if (winner.id.id != hit.id.id) {
            report(make(.hit_target_not_self, hit.id.id, "entry {d} loses its own centre to id {d}", .{ i, winner.id.id }));
            findings += 1;
        }
    }
    return findings;
}

/// Run every check for one frame.
pub fn frame(commands: []const cl.RenderCommand, scale: f32) usize {
    if (!enabled) return 0;
    var findings = checkCommands(commands, scale);
    findings += checkRegistry();
    if (@import("builtin").is_test) findings += checkHitConsistency();
    return findings;
}

// ===================== tests: the verifier must be able to fail =====================
// A verifier that has only ever passed is indistinguishable from one that never ran.

const testing = std.testing;

fn rect(id: u32, x: f32, w: f32) cl.RenderCommand {
    return .{
        .bounding_box = .{ .x = x, .y = 0, .width = w, .height = 10 },
        .render_data = .{ .rectangle = .{ .background_color = .{ 1, 1, 1, 1 }, .corner_radius = .{} } },
        .user_data = null,
        .id = id,
        .z_index = 0,
        .command_type = .rectangle,
    };
}

fn textRun(id: u32, bytes: []const u8, w: f32) cl.RenderCommand {
    return .{
        .bounding_box = .{ .x = 0, .y = 0, .width = w, .height = 14 },
        .render_data = .{ .text = .{
            .string_contents = .{ .chars = bytes.ptr, .base_chars = bytes.ptr, .length = @intCast(bytes.len) },
            .text_color = .{ 1, 1, 1, 1 },
            .font_id = 0,
            .font_size = 14,
            .letter_spacing = 0,
            .line_height = 0,
        } },
        .user_data = null,
        .id = id,
        .z_index = 0,
        .command_type = .text,
    };
}

const Recorder = struct {
    kinds: [8]Kind = undefined,
    n: usize = 0,
};

fn sinkFn(f: Finding) void {
    const self: *Recorder = @ptrCast(@alignCast(current.?));
    if (self.n < self.kinds.len) {
        self.kinds[self.n] = f.kind;
        self.n += 1;
    }
}

var current: ?*Recorder = null;

/// Run the command checks with a recording sink, so a test can assert on what the audit found.
fn record(cmds: []const cl.RenderCommand, scale: f32) Recorder {
    var rec = Recorder{};
    current = &rec;
    sink = sinkFn;
    defer {
        sink = null;
        current = null;
    }
    _ = checkCommands(cmds, scale);
    return rec;
}

test "audit: a text run wider than its box is a finding" {
    const cmds = [_]cl.RenderCommand{textRun(1, "InvoiceLine", 4)};
    const rec = record(&cmds, 1);
    try testing.expect(rec.n >= 1);
    try testing.expectEqual(Kind.text_wider_than_box, rec.kinds[0]);
}

test "audit: a text run that fits is not a finding" {
    const width = text_backend.measureText("InvoiceLine", 14).w;
    const cmds = [_]cl.RenderCommand{textRun(1, "InvoiceLine", width + 2)};
    try testing.expectEqual(@as(usize, 0), record(&cmds, 1).n);
}

test "audit: a hairline between device pixels is a finding, and a snapped one is not" {
    // At 2x a 0.5 pt bar at x=31.5 lands on device pixel 63: whole, so nothing is half-lit.
    const fine = [_]cl.RenderCommand{rect(7, 31.5, 0.5)};
    try testing.expectEqual(@as(usize, 0), record(&fine, 2).n);

    // The same bar at 1x is at device 31.5, which renders as two half-lit columns.
    const off = [_]cl.RenderCommand{rect(7, 31.5, 0.5)};
    const rec = record(&off, 1);
    try testing.expectEqual(Kind.hairline_off_grid, rec.kinds[0]);
}

test "audit: an unbalanced scissor is a finding" {
    var start = rect(1, 0, 10);
    start.command_type = .scissor_start;
    const cmds = [_]cl.RenderCommand{start};
    try testing.expectEqual(Kind.unbalanced_scissor, record(&cmds, 1).kinds[0]);
}

test "audit: a wide rectangle is not a hairline" {
    const cmds = [_]cl.RenderCommand{rect(7, 31.5, 40)};
    try testing.expectEqual(@as(usize, 0), record(&cmds, 2).n);
}
