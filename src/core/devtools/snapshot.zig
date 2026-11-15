// Devtool snapshot: the resolved semantics tree reshaped into parent/child links, and serialised as JSON or text.
const std = @import("std");
const cl = @import("zclay");
const semantics = @import("../semantics.zig");

// The most nodes one snapshot holds; it is the semantics layer's own capacity, so a snapshot never truncates a tree that layer kept.
pub const max_nodes: usize = semantics.cap;

const empty_box = cl.BoundingBox{ .x = 0, .y = 0, .width = 0, .height = 0 };

// One node with resolved geometry, plus where it sits in the tree.
pub const Item = struct {
    // The Clay id hash, which is what a render command and a hit target carry.
    id: u32 = 0,
    tag: []const u8 = "",
    role: semantics.Role = .unknown,
    label: []const u8 = "",
    value: []const u8 = "",
    // Where the widget that declared the node lives, as `file:line`.
    source: []const u8 = "",
    // Where the app declared it, when it passed `.src = @src()`.
    declared: ?semantics.Declared = null,
    actions: semantics.Actions = .{},
    flags: semantics.Flags = .{},
    z: i16 = 0,
    bounds: cl.BoundingBox = empty_box,
    // Intersection of every clipping ancestor with the viewport.
    clip: cl.BoundingBox = empty_box,
    // 0..1 of the node's own area that survives clipping.
    visible: f32 = 0,
    found: bool = false,
    // Index of the parent item, or -1 when the node is a root of this tree.
    parent: i32 = -1,
    first_child: i32 = -1,
    next_sibling: i32 = -1,
    depth: u16 = 0,

    // True when the node exists, the app did not hide it, and some of it is inside its clip.
    pub fn isDisplayed(self: Item) bool {
        return self.found and !self.flags.hidden and self.visible > 0;
    }

    // The part of the node that is actually on screen.
    pub fn visibleRect(self: Item) cl.BoundingBox {
        return intersect(self.bounds, self.clip);
    }
};

pub const Snapshot = struct {
    items: [max_nodes]Item = [_]Item{.{}} ** max_nodes,
    count: usize = 0,
    roots: [max_nodes]i32 = [_]i32{-1} ** max_nodes,
    root_count: usize = 0,
    // The viewport the geometry in this snapshot was resolved against.
    width: u32 = 0,
    height: u32 = 0,

    // Build a fresh snapshot from the semantics nodes of the frame resolved most recently.
    pub fn build(width: u32, height: u32) Snapshot {
        var s = Snapshot{ .width = width, .height = height };
        s.rebuild();
        return s;
    }

    // Rebuild in place from the live semantics list, then re-attach what the previous snapshot resolved for the same ids.
    pub fn rebuildPreserving(self: *Snapshot) void {
        const prev = self.*;
        self.rebuild();
        for (self.items[0..self.count]) |*item| {
            const old = prev.find(item.id) orelse continue;
            item.found = old.found;
            item.bounds = old.bounds;
            item.clip = old.clip;
            item.visible = old.visible;
            // Clickability and z are folded in at resolve, so they are one frame old too.
            item.actions = old.actions;
            item.z = old.z;
        }
    }

    // Rebuild the parent/child links and the labels from the live semantics list; geometry stays whatever it already holds.
    pub fn rebuild(self: *Snapshot) void {
        const nodes = semantics.all();
        const n = @min(nodes.len, max_nodes);
        for (nodes[0..n], 0..) |node, i| {
            self.items[i] = .{
                .id = node.id.id,
                .tag = node.tag,
                .role = node.role,
                .label = node.label,
                .value = node.value,
                .source = node.source,
                .declared = node.declared,
                .actions = node.actions,
                .flags = node.flags,
                .z = node.z,
                .bounds = node.bounds,
                .clip = node.clip,
                .visible = node.visible_fraction,
                .found = node.found,
                .parent = -1,
                .first_child = -1,
                .next_sibling = -1,
                .depth = 0,
            };
        }
        self.count = n;
        self.root_count = 0;
        @memset(self.roots[0..], -1);

        // A container registers itself AFTER its children (so it is never its own ancestor), which is why a parent lives at a HIGHER index than its kids.
        var last_child = [_]i32{-1} ** max_nodes;
        for (self.items[0..self.count], 0..) |*item, i| {
            item.parent = self.parentOf(nodes[i]);
            if (item.parent < 0) {
                self.roots[self.root_count] = @intCast(i);
                self.root_count += 1;
                continue;
            }
            const p: usize = @intCast(item.parent);
            if (last_child[p] < 0) {
                self.items[p].first_child = @intCast(i);
            } else {
                self.items[@intCast(last_child[p])].next_sibling = @intCast(i);
            }
            last_child[p] = @intCast(i);
        }
        // Depth needs every parent resolved first: the parent may be declared after the child.
        for (self.items[0..self.count]) |*item| {
            var depth: u16 = 0;
            var p = item.parent;
            while (p >= 0 and depth < max_nodes) : (p = self.items[@intCast(p)].parent) depth += 1;
            item.depth = depth;
        }
    }

    // The parent of a node: the innermost declared ancestor that is itself in this tree, or -1 when there is none.
    fn parentOf(self: *const Snapshot, node: semantics.Node) i32 {
        var a: usize = node.ancestor_len;
        while (a > 0) {
            a -= 1;
            const ancestor_id = node.ancestors[a].id.id;
            for (self.items[0..self.count], 0..) |item, j| {
                if (item.id == ancestor_id and item.id != node.id.id) return @intCast(j);
            }
        }
        return -1;
    }

    // The first item with this Clay id hash, or null.
    pub fn find(self: *const Snapshot, id: u32) ?Item {
        for (self.items[0..self.count]) |item| {
            if (item.id == id) return item;
        }
        return null;
    }

    // Whether the node has children the tree view can expand.
    pub fn hasChildren(self: *const Snapshot, index: usize) bool {
        if (index >= self.count) return false;
        return self.items[index].first_child >= 0;
    }

    // How many direct children the node has.
    pub fn childCount(self: *const Snapshot, index: usize) usize {
        if (index >= self.count) return 0;
        var n: usize = 0;
        var c = self.items[index].first_child;
        while (c >= 0) : (c = self.items[@intCast(c)].next_sibling) n += 1;
        return n;
    }

    // The index of one child by position, or null.
    pub fn childAt(self: *const Snapshot, index: usize, slot: usize) ?usize {
        if (index >= self.count) return null;
        var c = self.items[index].first_child;
        var n: usize = 0;
        while (c >= 0) : (c = self.items[@intCast(c)].next_sibling) {
            if (n == slot) return @intCast(c);
            n += 1;
        }
        return null;
    }

    // The topmost node under a point: highest z, then the DEEPEST node (a container that registered after its children must not win over them), then the last declared.
    pub fn pick(self: *const Snapshot, x: f32, y: f32) ?usize {
        var best: ?usize = null;
        var best_z: i16 = std.math.minInt(i16);
        var best_depth: u16 = 0;
        for (self.items[0..self.count], 0..) |item, i| {
            if (!item.isDisplayed()) continue;
            if (!contains(item.visibleRect(), x, y)) continue;
            const better = if (best == null)
                true
            else
                item.z > best_z or (item.z == best_z and item.depth >= best_depth);
            if (better) {
                best = i;
                best_z = item.z;
                best_depth = item.depth;
            }
        }
        return best;
    }

    // ---- serialisation ----

    pub const JsonOptions = struct {
        // How many levels of children to emit; 0 prints the roots as leaves.
        depth: u16 = 16,
        pretty: bool = true,
    };

    // The whole tree as one JSON document: `{"frame":{...},"roots":[...]}`.
    pub fn writeJson(self: *const Snapshot, w: *std.Io.Writer, opts: JsonOptions) std.Io.Writer.Error!void {
        try w.writeAll("{\"frame\":{\"width\":");
        try w.print("{d}", .{self.width});
        try w.writeAll(",\"height\":");
        try w.print("{d}", .{self.height});
        try w.writeAll(",\"nodes\":");
        try w.print("{d}", .{self.count});
        try w.writeAll("},\"roots\":[");
        for (self.roots[0..self.root_count], 0..) |root, i| {
            if (i > 0) try w.writeAll(",");
            if (opts.pretty) try w.writeAll("\n");
            try self.writeItemJson(w, @intCast(root), opts.depth, opts);
        }
        if (self.root_count > 0 and opts.pretty) try w.writeAll("\n");
        try w.writeAll("]}\n");
    }

    // The node under a point as its own JSON document, so an agent can ask "what is at 120,80?" and get one answer.
    pub fn writeJsonPick(self: *const Snapshot, w: *std.Io.Writer, x: f32, y: f32, opts: JsonOptions) std.Io.Writer.Error!void {
        try w.writeAll("{\"pick\":{\"x\":");
        try w.print("{d:.1}", .{x});
        try w.writeAll(",\"y\":");
        try w.print("{d:.1}", .{y});
        try w.writeAll(",\"frame\":{\"width\":");
        try w.print("{d}", .{self.width});
        try w.writeAll(",\"height\":");
        try w.print("{d}", .{self.height});
        try w.writeAll("},\"node\":");
        if (self.pick(x, y)) |i| {
            try self.writeItemJson(w, i, 0, opts);
        } else {
            try w.writeAll("null");
        }
        try w.writeAll("}}\n");
    }

    fn writeItemJson(self: *const Snapshot, w: *std.Io.Writer, index: usize, depth_left: u16, opts: JsonOptions) std.Io.Writer.Error!void {
        const item = self.items[index];
        try w.writeAll("{\"tag\":");
        try writeJsonString(w, item.tag);
        try w.writeAll(",\"hash\":");
        try w.print("{d}", .{item.id});
        try w.writeAll(",\"role\":");
        try writeJsonString(w, @tagName(item.role));
        if (item.source.len > 0) {
            try w.writeAll(",\"source\":");
            try writeJsonString(w, item.source);
        }
        if (item.declared) |declared| {
            try w.writeAll(",\"declared\":{\"module\":");
            try writeJsonString(w, declared.module);
            try w.writeAll(",\"file\":");
            try writeJsonString(w, declared.file);
            try w.writeAll(",\"line\":");
            try w.print("{d}", .{declared.line});
            try w.writeAll("}");
        }
        try w.writeAll(",\"label\":");
        try writeJsonString(w, item.label);
        if (item.value.len > 0) {
            try w.writeAll(",\"value\":");
            try writeJsonString(w, item.value);
        }
        try w.writeAll(",\"bounds\":");
        try writeRectJson(w, item.bounds);
        try w.writeAll(",\"visible\":");
        try w.print("{d:.3}", .{item.visible});
        var flag_buf: [96]u8 = undefined;
        const flags = flagList(item.flags, &flag_buf);
        if (flags.len > 0) {
            try w.writeAll(",\"flags\":[");
            try writeJsonString(w, flags);
            try w.writeAll("]");
        }
        var action_buf: [96]u8 = undefined;
        const actions = actionList(item.actions, &action_buf);
        if (actions.len > 0) {
            try w.writeAll(",\"actions\":[");
            try writeJsonString(w, actions);
            try w.writeAll("]");
        }
        try w.writeAll(",\"children\":[");
        if (depth_left > 0) {
            var n: usize = 0;
            var c = item.first_child;
            while (c >= 0) : (c = self.items[@intCast(c)].next_sibling) {
                if (n > 0) try w.writeAll(",");
                if (opts.pretty) try w.writeAll("\n");
                try self.writeItemJson(w, @intCast(c), depth_left - 1, opts);
                n += 1;
            }
        }
        try w.writeAll("]}");
    }

    // One human-readable line per node, indented by depth: what a terminal or a log excerpt shows an agent.
    pub fn writeText(self: *const Snapshot, w: *std.Io.Writer, depth: u16) std.Io.Writer.Error!void {
        try w.print("frame {d}x{d}, {d} nodes, {d} roots\n", .{ self.width, self.height, self.count, self.root_count });
        for (self.roots[0..self.root_count]) |root| {
            try self.writeItemText(w, @intCast(root), depth);
        }
    }

    // The node under a point, as one line, so `--pick` reads like an answer rather than a document.
    pub fn writeTextPick(self: *const Snapshot, w: *std.Io.Writer, x: f32, y: f32) std.Io.Writer.Error!void {
        try w.print("pick {d:.1},{d:.1} -> ", .{ x, y });
        if (self.pick(x, y)) |i| {
            try writeTextItem(w, self.items[i]);
            try w.writeAll("\n");
        } else {
            try w.writeAll("nothing\n");
        }
    }

    fn writeItemText(self: *const Snapshot, w: *std.Io.Writer, index: usize, depth: u16) std.Io.Writer.Error!void {
        const item = self.items[index];
        var pad: [32]u8 = undefined;
        const pad_len = @min(@as(usize, item.depth) * 2, pad.len);
        @memset(pad[0..pad_len], ' ');
        try w.writeAll(pad[0..pad_len]);
        try writeTextItem(w, item);
        try w.writeAll("\n");
        if (depth > 0) {
            var c = item.first_child;
            while (c >= 0) : (c = self.items[@intCast(c)].next_sibling) {
                try self.writeItemText(w, @intCast(c), depth - 1);
            }
        }
    }
};

fn writeTextItem(w: *std.Io.Writer, item: Item) std.Io.Writer.Error!void {
    try w.writeAll(if (item.tag.len > 0) item.tag else "(unnamed)");
    try w.print("  {s}", .{@tagName(item.role)});
    if (item.label.len > 0) {
        try w.writeAll(" \"");
        try w.writeAll(item.label);
        try w.writeAll("\"");
    }
    const r = item.visibleRect();
    try w.print("  {d:.0},{d:.0} {d:.0}x{d:.0}", .{ r.x, r.y, r.width, r.height });
    if (item.visible > 0 and item.visible < 1) try w.print(" vis={d:.2}", .{item.visible});
    var action_buf: [96]u8 = undefined;
    const actions = actionList(item.actions, &action_buf);
    if (actions.len > 0) try w.print(" [{s}]", .{actions});
    if (item.source.len > 0) try w.print("  src={s}", .{item.source});
    if (item.declared) |declared| try w.print("  app={s}/{s}:{d}", .{ declared.module, declared.file, declared.line });
}

fn writeRectJson(w: *std.Io.Writer, r: cl.BoundingBox) std.Io.Writer.Error!void {
    try w.writeAll("{\"x\":");
    try w.print("{d:.1}", .{r.x});
    try w.writeAll(",\"y\":");
    try w.print("{d:.1}", .{r.y});
    try w.writeAll(",\"w\":");
    try w.print("{d:.1}", .{r.width});
    try w.writeAll(",\"h\":");
    try w.print("{d:.1}", .{r.height});
    try w.writeAll("}");
}

// A JSON string: quotes and backslashes escaped, control bytes as \u00XX, and everything above 0x1f passed through as the UTF-8 it already is.
pub fn writeJsonString(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
    try w.writeByte('"');
}

// The actions a node offers, comma-separated, into the caller's buffer.
pub fn actionList(a: semantics.Actions, buf: []u8) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    var first = true;
    if (a.click) appendName(&w, &first, "click");
    if (a.scroll) appendName(&w, &first, "scroll");
    if (a.set_text) appendName(&w, &first, "set_text");
    if (a.drag) appendName(&w, &first, "drag");
    return w.buffered();
}

// The state flags a node reports, comma-separated, into the caller's buffer.
pub fn flagList(f: semantics.Flags, buf: []u8) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    var first = true;
    if (f.enabled) appendName(&w, &first, "enabled");
    if (f.checked) appendName(&w, &first, "checked");
    if (f.selected) appendName(&w, &first, "selected");
    if (f.focused) appendName(&w, &first, "focused");
    if (f.hidden) appendName(&w, &first, "hidden");
    return w.buffered();
}

fn appendName(w: *std.Io.Writer, first: *bool, name: []const u8) void {
    if (!first.*) w.writeAll(",") catch return;
    w.writeAll(name) catch return;
    first.* = false;
}

fn contains(r: cl.BoundingBox, x: f32, y: f32) bool {
    return x >= r.x and x < r.x + r.width and y >= r.y and y < r.y + r.height;
}

fn intersect(a: cl.BoundingBox, b: cl.BoundingBox) cl.BoundingBox {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.width, b.x + b.width);
    const y1 = @min(a.y + a.height, b.y + b.height);
    return .{ .x = x0, .y = y0, .width = @max(0, x1 - x0), .height = @max(0, y1 - y0) };
}

// ---- Test doubles ----

fn registerNode(id: []const u8, role: semantics.Role, parent: ?[]const u8) void {
    if (parent) |p| semantics.pushAncestor(cl.getElementId(p), false);
    semantics.register(.{ .id = cl.getElementId(id), .tag = id, .role = role, .label = id });
    if (parent != null) semantics.popAncestor();
}

// A root container with two semantic children, declared the way a component would.
fn buildTree() Snapshot {
    semantics.beginFrame();
    registerNode("root", .container, null);
    semantics.pushAncestor(cl.getElementId("root"), false);
    registerNode("ok", .button, null);
    registerNode("field", .text_field, null);
    semantics.popAncestor();
    return Snapshot.build(480, 360);
}

test "a snapshot links each node to the registered ancestor that contains it" {
    const s = buildTree();

    try std.testing.expectEqual(@as(usize, 3), s.count);
    try std.testing.expectEqual(@as(usize, 1), s.root_count);
    try std.testing.expectEqual(@as(i32, 0), s.roots[0]);
    try std.testing.expectEqual(@as(i32, 0), s.items[1].parent);
    try std.testing.expectEqual(@as(i32, 0), s.items[2].parent);
    try std.testing.expectEqual(@as(u16, 1), s.items[1].depth);
    // Two children hang off the root, in declaration order.
    try std.testing.expectEqual(@as(i32, 1), s.items[0].first_child);
    try std.testing.expectEqual(@as(i32, 2), s.items[1].next_sibling);
    try std.testing.expectEqual(@as(usize, 2), s.childCount(0));
    try std.testing.expect(s.hasChildren(0));
    try std.testing.expect(!s.hasChildren(1));
    try std.testing.expectEqual(@as(?usize, 2), s.childAt(0, 1));
    try std.testing.expectEqual(@as(?usize, null), s.childAt(0, 2));
}

test "a node whose ancestors were never registered is a root" {
    semantics.beginFrame();
    registerNode("orphan", .text, "no-such-parent");
    const s = Snapshot.build(100, 100);
    try std.testing.expectEqual(@as(usize, 1), s.root_count);
    try std.testing.expectEqual(@as(i32, -1), s.items[0].parent);
}

test "pick returns the node whose visible rect contains the point" {
    var s = buildTree();
    // Geometry comes from the resolve, so it is filled in here rather than guessed.
    s.items[0].found = true;
    s.items[0].bounds = .{ .x = 0, .y = 0, .width = 480, .height = 360 };
    s.items[0].clip = s.items[0].bounds;
    s.items[0].visible = 1;
    s.items[1].found = true;
    s.items[1].bounds = .{ .x = 10, .y = 10, .width = 100, .height = 40 };
    s.items[1].clip = s.items[0].bounds;
    s.items[1].visible = 1;

    try std.testing.expectEqual(@as(?usize, 1), s.pick(50, 20));
    // Inside the root only: the deeper node is not under the point.
    try std.testing.expectEqual(@as(?usize, 0), s.pick(300, 200));
    // Outside everything.
    try std.testing.expectEqual(@as(?usize, null), s.pick(600, 500));
}

test "pick ignores a node the app hid, and the clipped-away part of a node" {
    semantics.beginFrame();
    registerNode("half", .container, null);
    var s = Snapshot.build(480, 360);
    s.items[0].found = true;
    s.items[0].bounds = .{ .x = 0, .y = 0, .width = 100, .height = 400 };
    s.items[0].clip = .{ .x = 0, .y = 0, .width = 100, .height = 50 };
    s.items[0].visible = 0.125;

    try std.testing.expectEqual(@as(?usize, 0), s.pick(50, 20));
    // y=200 is inside the node's own box but outside everything it can see.
    try std.testing.expectEqual(@as(?usize, null), s.pick(50, 200));

    s.items[0].flags.hidden = true;
    try std.testing.expectEqual(@as(?usize, null), s.pick(50, 20));
}

test "a later declaration wins a tie at the same z, and a higher z wins outright" {
    semantics.beginFrame();
    registerNode("under", .container, null);
    registerNode("over", .container, null);
    var s = Snapshot.build(100, 100);
    for (s.items[0..2]) |*item| {
        item.found = true;
        item.bounds = .{ .x = 0, .y = 0, .width = 100, .height = 100 };
        item.clip = item.bounds;
        item.visible = 1;
    }
    try std.testing.expectEqual(@as(?usize, 1), s.pick(50, 50));
    s.items[0].z = 4;
    try std.testing.expectEqual(@as(?usize, 0), s.pick(50, 50));
}

test "rebuildPreserving keeps the geometry the last resolve produced" {
    const resolved = buildTree();
    var live = resolved;
    live.items[0].found = true;
    live.items[0].bounds = .{ .x = 5, .y = 6, .width = 70, .height = 80 };
    live.items[0].clip = live.items[0].bounds;
    live.items[0].visible = 1;

    live.rebuildPreserving();
    try std.testing.expect(live.items[0].found);
    try std.testing.expectEqual(@as(f32, 70), live.items[0].bounds.width);
    try std.testing.expectApproxEqAbs(@as(f32, 1), live.items[0].visible, 0.001);
}

test "the JSON document carries the frame, the roles and the child links" {
    var s = buildTree();
    s.items[1].found = true;
    s.items[1].bounds = .{ .x = 16, .y = 60, .width = 180, .height = 40 };
    s.items[1].clip = .{ .x = 0, .y = 0, .width = 480, .height = 360 };
    s.items[1].visible = 1;

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try s.writeJson(&w, .{});
    const out = w.buffered();

    try std.testing.expect(std.mem.indexOf(u8, out, "\"frame\":{\"width\":480,\"height\":360,\"nodes\":3}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"role\":\"button\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"bounds\":{\"x\":16.0,\"y\":60.0,\"w\":180.0,\"h\":40.0}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"tag\":\"ok\"") != null);
}

test "the JSON depth option stops the recursion" {
    const s = buildTree();
    var full: [4096]u8 = undefined;
    var shallow: [4096]u8 = undefined;
    var wf = std.Io.Writer.fixed(&full);
    var ws = std.Io.Writer.fixed(&shallow);
    try s.writeJson(&wf, .{ .depth = 16, .pretty = false });
    try s.writeJson(&ws, .{ .depth = 0, .pretty = false });
    try std.testing.expect(wf.buffered().len > ws.buffered().len);
    try std.testing.expect(std.mem.indexOf(u8, ws.buffered(), "\"tag\":\"ok\"") == null);
}

test "JSON strings escape quotes, backslashes and control bytes" {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeJsonString(&w, "a\"b\\c\nd\x01");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\u0001\"", w.buffered());
}

test "the text dump indents by depth and names the role" {
    const s = buildTree();
    var buf: [2048]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try s.writeText(&w, 16);
    const out = w.buffered();
    try std.testing.expect(std.mem.startsWith(u8, out, "frame 480x360, 3 nodes, 1 roots\n"));
    try std.testing.expect(std.mem.indexOf(u8, out, "\nroot  container") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\n  ok  button") != null);
}

test "a pick with nothing under the point still answers" {
    const s = buildTree();
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try s.writeTextPick(&w, 5, 5);
    try std.testing.expectEqualStrings("pick 5.0,5.0 -> nothing\n", w.buffered());
}

test "the app's own call site is a separate field from the component's" {
    var s = buildTree();
    s.items[1].source = "core/components/button.zig:52";
    s.items[1].declared = .{ .module = "catalog", .file = "view.zig", .line = 126 };

    var json_buf: [4096]u8 = undefined;
    var jw = std.Io.Writer.fixed(&json_buf);
    try s.writeJson(&jw, .{ .pretty = false });
    try std.testing.expect(std.mem.indexOf(u8, jw.buffered(), "\"source\":\"core/components/button.zig:52\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, jw.buffered(), "\"declared\":{\"module\":\"catalog\",\"file\":\"view.zig\",\"line\":126}") != null);

    var text_buf: [2048]u8 = undefined;
    var tw = std.Io.Writer.fixed(&text_buf);
    try s.writeText(&tw, 16);
    try std.testing.expect(std.mem.indexOf(u8, tw.buffered(), "src=core/components/button.zig:52") != null);
    try std.testing.expect(std.mem.indexOf(u8, tw.buffered(), "app=catalog/view.zig:126") != null);
}

test "the action and flag lists name only what is set" {
    var buf: [96]u8 = undefined;
    try std.testing.expectEqualStrings("click,scroll", actionList(.{ .click = true, .scroll = true }, &buf));
    try std.testing.expectEqualStrings("", actionList(.{}, &buf));
    try std.testing.expectEqualStrings("enabled,focused", flagList(.{ .focused = true }, &buf));
}
