// The devtool's public surface: one inspector to attach to a host, one snapshot to read a tree, one CLI to dump or photograph it.
const std = @import("std");
const cl = @import("zclay");
const host_mod = @import("../host.zig");
const testing = @import("../testing/root.zig");
const software = @import("../render_software.zig");
const inspector_mod = @import("inspector.zig");
const snapshot_mod = @import("snapshot.zig");
const cli_mod = @import("cli.zig");

pub const Inspector = inspector_mod.Inspector;
pub const snapshot = snapshot_mod;
pub const cli = cli_mod;

// Attach the devtool to a host: right-click now inspects, and every frame resolves the tree the devtool reads.
pub fn attach(alloc: std.mem.Allocator, host: *host_mod.Host) ?*Inspector {
    // Process-lifetime by design, like the Clay arena: a devtool outlives every frame and is never torn down mid-run.
    const insp = alloc.create(Inspector) catch return null;
    insp.* = .{};
    host.inspect = insp;
    return insp;
}

// Render the app with the devtool window open into a 32-bit TGA, so the tree can be looked at without a compositor or a right button.
pub fn shoot(
    alloc: std.mem.Allocator,
    opts: cli_mod.Options,
    ctx: ?*anyopaque,
    root_fn: host_mod.RootFn,
    out: *std.Io.Writer,
) !void {
    var driver = try testing.Driver.initOwned(alloc, ctx, root_fn);
    defer driver.deinit();
    driver.headless = true;
    const insp = attach(alloc, driver.host);
    try driver.start(.{ .width = opts.width, .height = opts.height });
    // One frame so the tree is resolved, then open the window on its root: the shot is the devtool looking at the app.
    driver.frame();
    if (insp) |i| {
        i.openOnRoot();
        // A point selects that node instead, so the picture shows the outline, the origin line and the breadcrumb of one component.
        if (opts.pick) |p| {
            driver.host.onPointerEvent(p.x, p.y, false, 0);
            i.startPicking();
            i.takePick();
        }
    }
    var i: usize = 1;
    while (i < opts.frames) : (i += 1) driver.frame();

    var renderer = try software.Renderer.init(alloc);
    defer renderer.deinit();
    renderer.surface.resize(opts.width, opts.height) catch return error.InvalidSize;
    renderer.surface.clear();
    renderer.surface.renderCommands(driver.commands());
    try writeTga(out, opts.width, opts.height, renderer.surface.pixels);
}

// An uncompressed 32-bit TGA, bottom-up BGRA: the same shape the macOS parity test writes, so `convert` or any viewer reads it.
fn writeTga(out: *std.Io.Writer, w: u32, h: u32, rgba: []const u8) !void {
    var header = [_]u8{0} ** 18;
    header[2] = 2;
    std.mem.writeInt(u16, header[12..14], @intCast(w), .little);
    std.mem.writeInt(u16, header[14..16], @intCast(h), .little);
    header[16] = 32;
    header[17] = 8;
    try out.writeAll(&header);
    var row: u32 = h;
    while (row > 0) {
        row -= 1;
        var col: u32 = 0;
        while (col < w) : (col += 1) {
            const i = (@as(usize, row) * w + col) * 4;
            if (i + 3 >= rgba.len) return;
            try out.writeAll(&[_]u8{ rgba[i + 2], rgba[i + 1], rgba[i], rgba[i + 3] });
        }
    }
}

test "attach hands the host a live inspector, and a second call replaces it" {
    var host = try host_mod.Host.init(std.heap.page_allocator, null, noopRoot);
    // No deinit: Clay keeps a global pointer into the arena it was initialised with, and freeing it would crash every later test.
    try std.testing.expect(host.inspect == null);
    const first = attach(std.heap.page_allocator, &host).?;
    try std.testing.expect(host.inspect == first);
    try std.testing.expect(first.isIdle());
    const second = attach(std.heap.page_allocator, &host).?;
    try std.testing.expect(host.inspect == second);
}

test "the TGA carries a matching header and one BGRA pixel per RGBA pixel" {
    // 2x2: red, green, blue, and one semi-transparent white. The file is bottom-up, so the last row is written first.
    const rgba = [_]u8{
        255, 0, 0,   255, 0,   255, 0,   255,
        0,   0, 255, 255, 255, 255, 255, 128,
    };
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeTga(&w, 2, 2, &rgba);
    const out = w.buffered();
    try std.testing.expectEqual(@as(usize, 18 + 16), out.len);
    try std.testing.expectEqual(@as(u8, 2), out[2]);
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, out[12..14], .little));
    try std.testing.expectEqual(@as(u32, 32), out[16]);
    // Bottom row first: blue then white, both as BGRA.
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, out[18..22]);
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 128 }, out[22..26]);
    // Then the top row: red, then green.
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, out[26..30]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, out[30..34]);
}

fn noopRoot(_: ?*anyopaque, _: u32, _: u32) void {}
