//! The frame's findable text as a flat snapshot, so a backend with no DOM text of its own can mirror it.
const std = @import("std");
const cl = @import("zclay");
const headless = @import("testing/headless.zig");

/// One text run: the box it was drawn in and its bytes, in CONTENT coordinates of the page scroller.
pub const Entry = extern struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    len: u32,
    flags: u32,
    chars: [text_capacity]u8,
};

/// `flags` bit 0: the run scrolls with the page, so its `y` is a content coordinate; without it the run is chrome.
pub const flag_scrolls: u32 = 1;

/// A run past this length is truncated at a UTF-8 boundary rather than dropped.
pub const text_capacity: usize = 128;

/// Runs kept per frame: a docs page draws a few hundred, and past the cap the overflow is dropped.
pub const capacity: usize = 512;

pub const stride: usize = @sizeOf(Entry);

/// How deep a run's clip chain is followed; past it the innermost offsets are still applied.
pub const clip_depth: usize = 32;

/// What a backend reads: the runs, the page scroller's offset and reach, and a version for its geometry.
pub const Snapshot = struct {
    count: usize = 0,
    entries: [capacity]Entry = undefined,
    page_id: u32 = 0,
    has_page: bool = false,
    page_offset: f32 = 0,
    page_max: f32 = 0,
    version: u32 = 0,
};

/// The scroll state of one clip element. Public because a page's find-in-page is the other reader.
pub fn scrollOf(id: u32) ?cl.ScrollContainerData {
    const data = cl.getScrollContainerData(.{
        .id = id,
        .offset = 0,
        .base_id = 0,
        .string_id = .{ .chars = "", .length = 0, .is_statically_allocated = true },
    });
    if (!data.found) return null;
    return data;
}

/// The shift a clip applied to its children this frame: the same number the layout used.
fn shiftOf(data: cl.ScrollContainerData) struct { x: f32, y: f32 } {
    return .{ .x = @max(-data.config.child_offset.x, 0), .y = @max(-data.config.child_offset.y, 0) };
}

fn verticalReach(data: cl.ScrollContainerData) f32 {
    return @max(0, data.content_dimensions.h - data.scroll_container_dimensions.h);
}

fn copyText(dst: *[text_capacity]u8, s: []const u8) u32 {
    var n = @min(s.len, text_capacity);
    while (n > 0 and n < s.len and (s[n] & 0xc0) == 0x80) n -= 1;
    @memcpy(dst[0..n], s[0..n]);
    return @intCast(n);
}

/// One clip in the walk's stack: the shift it applied this frame, and the scroller it is (0 for a plain clip).
const Clip = struct {
    x: f32 = 0,
    y: f32 = 0,
    id: u32 = 0,
};

/// The scroller the page reads with: the one that reaches furthest, which is the one a mirror's scroll follows.
const Page = struct {
    id: u32 = 0,
    shift_x: f32 = 0,
    shift_y: f32 = 0,
    reach: f32 = 0,
    found: bool = false,
};

fn findPage(commands: []const cl.RenderCommand) Page {
    var page: Page = .{};
    for (commands) |cmd| {
        if (cmd.command_type != .scissor_start) continue;
        const data = scrollOf(cmd.id) orelse continue;
        const reach = verticalReach(data);
        if (!page.found or reach > page.reach) {
            const shift = shiftOf(data);
            page = .{ .id = cmd.id, .shift_x = shift.x, .shift_y = shift.y, .reach = reach, .found = true };
        }
    }
    return page;
}

/// Snapshot the text runs of one frame's commands.
pub fn capture(commands: []const cl.RenderCommand, snap: *Snapshot) void {
    snap.count = 0;
    const page = findPage(commands);
    snap.has_page = page.found and page.reach > 0;
    snap.page_id = if (snap.has_page) page.id else 0;
    snap.page_offset = if (snap.has_page) page.shift_y else 0;
    snap.page_max = if (snap.has_page) page.reach else 0;

    var stack: [clip_depth]Clip = undefined;
    var depth: usize = 0;
    // A run's box is already where it was drawn; the page's shift is the only one a layer needs back.
    var page_in_stack: usize = 0;
    var page_x: f32 = 0;
    var page_y: f32 = 0;

    for (commands) |cmd| switch (cmd.command_type) {
        .scissor_start => {
            var clip: Clip = .{};
            if (scrollOf(cmd.id)) |data| {
                const shift = shiftOf(data);
                clip = .{ .x = shift.x, .y = shift.y, .id = cmd.id };
            }
            if (depth < clip_depth) {
                stack[depth] = clip;
                depth += 1;
                if (snap.has_page and clip.id == page.id) {
                    page_in_stack += 1;
                    page_x = clip.x;
                    page_y = clip.y;
                }
            }
        },
        .scissor_end => {
            if (depth > 0) {
                depth -= 1;
                if (snap.has_page and stack[depth].id == page.id) {
                    page_in_stack -= 1;
                    page_x = 0;
                    page_y = 0;
                }
            }
        },
        .text => {
            if (snap.count >= capacity) continue;
            const text = cmd.render_data.text.string_contents;
            if (text.length <= 0) continue;
            const box = cmd.bounding_box;
            if (box.width <= 0 or box.height <= 0) continue;
            const on_page = page_in_stack > 0;
            var entry: Entry = .{
                .x = box.x + if (on_page) page_x else 0,
                .y = box.y + if (on_page) page_y else 0,
                .w = box.width,
                .h = box.height,
                .len = 0,
                .flags = if (on_page) flag_scrolls else 0,
                .chars = undefined,
            };
            entry.len = copyText(&entry.chars, text.chars[0..@intCast(text.length)]);
            if (entry.len == 0) continue;
            snap.entries[snap.count] = entry;
            snap.count += 1;
        },
        else => {},
    };

    snap.version = fingerprint(snap);
}

/// FNV-1a over everything a mirror draws, so a rebuild happens only when the text or its box moved.
pub fn fingerprint(snap: *const Snapshot) u32 {
    var h: u32 = 0x811c9dc5;
    h = mix(h, @intCast(snap.count));
    h = mixCoord(h, snap.page_max);
    for (snap.entries[0..snap.count]) |e| {
        h = mixCoord(h, e.x);
        h = mixCoord(h, e.y);
        h = mixCoord(h, e.w);
        h = mixCoord(h, e.h);
        h = mix(h, e.len);
        for (e.chars[0..e.len]) |c| h = mix(h, c);
    }
    return h;
}

/// Whole pixels only: a sub-pixel wobble is not a change a mirror has to redraw for.
fn mixCoord(h: u32, v: f32) u32 {
    const r: i32 = @intFromFloat(@round(std.math.clamp(v, -100_000, 100_000)));
    return mix(h, @bitCast(r));
}

fn mix(h: u32, v: u32) u32 {
    return (h ^ v) *% 0x01000193;
}

// ---- the test's own page ----

var test_shift: f32 = 0;

const long_run = "abcdefghij" ** 13;

fn declarePage() void {
    cl.UI()(.{
        .id = .ID("ti.page"),
        .layout = .{ .sizing = .{ .w = .fixed(200), .h = .fixed(100) } },
        .clip = .{ .vertical = true, .child_offset = .{ .x = 0, .y = -test_shift } },
    })({
        cl.UI()(.{
            .id = .ID("ti.row"),
            .layout = .{ .direction = .top_to_bottom, .sizing = .{ .w = .fixed(200), .h = .fixed(400) } },
        })({
            cl.UI()(.{ .id = .ID("ti.spacer"), .layout = .{ .sizing = .{ .w = .{}, .h = .fixed(200) } } })({});
            cl.text("Text field", .{ .font_size = 14 });
        });
    });
}

fn declarePageAndChrome() void {
    cl.UI()(.{
        .id = .ID("ti.root"),
        .layout = .{ .direction = .left_to_right, .sizing = .{ .w = .fixed(720), .h = .fixed(480) } },
    })({
        cl.UI()(.{ .id = .ID("ti.nav"), .layout = .{ .sizing = .{ .w = .fixed(100), .h = .fixed(480) } } })({
            cl.text("catalog nav", .{ .font_size = 14 });
        });
        declarePage();
    });
}

fn declareMany() void {
    cl.UI()(.{
        .id = .ID("ti.many"),
        .layout = .{ .direction = .top_to_bottom, .sizing = .{ .w = .fixed(200), .h = .fixed(4_000) } },
    })({
        for (0..capacity + 8) |_| cl.text("row", .{ .font_size = 10 });
    });
}

fn declareLongRun() void {
    cl.text(long_run, .{ .font_size = 14 });
}

test "a run the frame draws is captured with the box it was drawn in" {
    test_shift = 0;
    var snap: Snapshot = .{};
    capture(try headless.frameCommands(declarePage), &snap);

    try std.testing.expectEqual(@as(usize, 1), snap.count);
    const e = snap.entries[0];
    try std.testing.expectEqualStrings("Text field", e.chars[0..e.len]);
    try std.testing.expect(e.w > 0);
    try std.testing.expect(e.h > 0);
}

test "a query the page draws is in the snapshot, in the bytes the page spelled" {
    test_shift = 0;
    var snap: Snapshot = .{};
    capture(try headless.frameCommands(declarePage), &snap);

    var found = false;
    for (snap.entries[0..snap.count]) |e| {
        if (std.mem.indexOf(u8, e.chars[0..e.len], "Text field") != null) found = true;
    }
    try std.testing.expect(found);
}

test "the page scroller's shift is reported as its offset and its reach as page_max" {
    test_shift = 40;
    var snap: Snapshot = .{};
    capture(try headless.frameCommands(declarePage), &snap);

    try std.testing.expect(snap.has_page);
    try std.testing.expectApproxEqAbs(@as(f32, 40), snap.page_offset, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 300), snap.page_max, 0.01);
    try std.testing.expectEqual(flag_scrolls, snap.entries[0].flags & flag_scrolls);
}

test "a run outside the page scroller is chrome: drawn where it is, and flagged as not scrolling" {
    test_shift = 40;
    var snap: Snapshot = .{};
    capture(try headless.frameCommands(declarePageAndChrome), &snap);

    var page_runs: usize = 0;
    var chrome_runs: usize = 0;
    for (snap.entries[0..snap.count]) |e| {
        const text = e.chars[0..e.len];
        if (std.mem.eql(u8, text, "Text field")) {
            page_runs += 1;
            try std.testing.expectEqual(flag_scrolls, e.flags & flag_scrolls);
        }
        if (std.mem.eql(u8, text, "catalog nav")) {
            chrome_runs += 1;
            try std.testing.expectEqual(@as(u32, 0), e.flags & flag_scrolls);
            try std.testing.expectApproxEqAbs(@as(f32, 0), e.y, 0.01);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), page_runs);
    try std.testing.expectEqual(@as(usize, 1), chrome_runs);
}

test "scrolling the page does not move the text, only the offset" {
    test_shift = 0;
    var top: Snapshot = .{};
    capture(try headless.frameCommands(declarePage), &top);

    test_shift = 40;
    var scrolled: Snapshot = .{};
    capture(try headless.frameCommands(declarePage), &scrolled);
    test_shift = 0;

    try std.testing.expectApproxEqAbs(top.entries[0].y, scrolled.entries[0].y, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 40), scrolled.page_offset - top.page_offset, 0.01);
    try std.testing.expectEqual(top.version, scrolled.version);
}

test "a run past the byte budget is truncated at a UTF-8 boundary, not dropped" {
    var snap: Snapshot = .{};
    capture(try headless.frameCommands(declareLongRun), &snap);

    try std.testing.expectEqual(@as(usize, 1), snap.count);
    try std.testing.expectEqual(@as(u32, text_capacity), snap.entries[0].len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(snap.entries[0].chars[0..snap.entries[0].len]));
}

test "the version moves when the text does and holds when it does not" {
    test_shift = 0;
    var one: Snapshot = .{};
    capture(try headless.frameCommands(declarePage), &one);
    var two: Snapshot = .{};
    capture(try headless.frameCommands(declarePage), &two);
    try std.testing.expectEqual(one.version, two.version);

    var three: Snapshot = .{};
    capture(try headless.frameCommands(declareLongRun), &three);
    try std.testing.expect(one.version != three.version);
}

test "a page with more runs than the snapshot holds keeps the first capacity of them" {
    var snap: Snapshot = .{};
    // Culling off, exactly as the browser backend runs: a run below the fold still has to be findable.
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
    cl.setCullingEnabled(false);
    cl.beginLayout();
    declareMany();
    capture(cl.endLayout(), &snap);

    try std.testing.expectEqual(capacity, snap.count);
    for (snap.entries[0..snap.count]) |e| try std.testing.expectEqualStrings("row", e.chars[0..e.len]);
}
