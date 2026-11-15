// The in-app devtool: right-click summons a context menu, "Inspect element" opens a floating window onto the component tree.
const std = @import("std");
const cl = @import("zclay");
const Color = @import("../color.zig").Color;
const frame = @import("../frame.zig");
const registry = @import("../components/click_registry.zig");
const input_mod = @import("../components/input.zig");
const semantics = @import("../semantics.zig");
const prop = @import("../props.zig");
const snapshot_mod = @import("snapshot.zig");

const Snapshot = snapshot_mod.Snapshot;

// Nodes the row list will flatten; the rest stay reachable by expanding a narrower branch.
pub const max_rows: usize = 128;

// The search box's semantics id, which is also what `glinlanduidp text` needs to type into it.
pub const search_field_id: []const u8 = "glinlandui.inspector.search";

// One line of the detail panel: what it draws, and the text a click copies.
const DetailLine = struct {
    // The whole line as the panel shows it, label and value.
    text: []const u8,
    // What lands on the clipboard: the value alone, so a path does not arrive wearing its label.
    copy: []const u8,
    color: Color,
    size: prop.Len,
};

// One flattened, currently visible tree row.
pub const Row = struct {
    node: u16 = 0,
    depth: u8 = 0,
    // A hit of the current search; the rows around it are the path that leads to it, drawn dim.
    matched: bool = false,
};

// The devtool's whole state. An app owns one, hands `&inspector` to `Host.inspect`, and never touches it again.
pub const Inspector = struct {
    snapshot: Snapshot = .{},
    // Where the right click landed, in window coordinates, while the context menu is up.
    menu: ?cl.Vector2 = null,
    // Whether the tree window is open.
    open: bool = false,
    // The node under the right click, as the frame it was resolved in saw it.
    picked: ?usize = null,
    // The node whose details the panel is showing.
    selected: ?usize = null,
    expanded: [snapshot_mod.max_nodes]bool = [_]bool{false} ** snapshot_mod.max_nodes,
    rows: [max_rows]Row = [_]Row{.{}} ** max_rows,
    row_count: usize = 0,
    // The search box: the real text field, so typing, the caret, selection, paste and composed text all work.
    search: input_mod.Field = searchField(),
    // The query the arrays below describe, so a new query restarts the walk from its first hit.
    last_query: [input_mod.max_field_len]u8 = [_]u8{0} ** input_mod.max_field_len,
    last_query_len: usize = 0,
    // Per node: is it a hit, and does its subtree hold one? `context` is what keeps a hit inside the tree it belongs to.
    matched: [snapshot_mod.max_nodes]bool = [_]bool{false} ** snapshot_mod.max_nodes,
    context: [snapshot_mod.max_nodes]bool = [_]bool{false} ** snapshot_mod.max_nodes,
    // The rows that are hits, in row order, and where Enter is in that walk.
    hits: [max_rows]u16 = [_]u16{0} ** max_rows,
    hit_count: usize = 0,
    hit_cursor: usize = 0,
    // The detail line whose text is on the clipboard, so the panel can show which one it was.
    copied_line: ?u8 = null,
    // Where a copied line goes: the system clipboard by default, a scripted one in a test.
    clipboard: input_mod.Clipboard = .{},
    // The window the last declare ran against, so a pointer event between frames can clamp the menu into it.
    width: u32 = 0,
    height: u32 = 0,
    // Whether the first declare after opening has already revealed the top of the tree.
    seeded: bool = false,
    // Whether the picker is armed: the node under the pointer is outlined, and the next click takes it.
    picking: bool = false,
    // The last pointer position, in window coordinates, and the node it was over.
    pointer: cl.Vector2 = .{ .x = 0, .y = 0 },
    hover_index: ?usize = null,

    // The width of the panel: a little over half a narrow window, and never so little that a row cannot show its role.
    fn panelWidth(self: *const Inspector) f32 {
        const w: f32 = @floatFromInt(@max(self.width, 1));
        return @min(360, @max(220, w * 0.55));
    }

    // The height of the panel window.
    fn panelHeight(self: *const Inspector) f32 {
        const h: f32 = @floatFromInt(@max(self.height, 1));
        return @max(160, h - 24);
    }

    // What the overlay outlines: the picker's node while it is armed, else the selected row — and nothing at all unless the window is open.
    pub fn outlinedNode(self: *const Inspector) ?usize {
        if (self.picking) return self.hover_index;
        if (!self.open) return null;
        return self.selected;
    }

    // A commit to memory: nothing is open, so the overlay draws nothing at all.
    pub fn isIdle(self: *const Inspector) bool {
        return self.menu == null and !self.open and !self.picking;
    }

    // A right click: snapshot the frame that was resolved most recently, remember the node under the pointer, and summon the menu there.
    pub fn onSecondaryClick(self: *Inspector, x: f32, y: f32) void {
        self.snapshot = Snapshot.build(self.width, self.height);
        self.picked = self.snapshot.pick(x, y);
        self.menu = .{ .x = x, .y = y };
    }

    // Escape closes the picker, then the menu, then the window; true means the key was consumed.
    pub fn onKey(self: *Inspector, keycode: u32) bool {
        if (keycode != key_escape) return false;
        // The search box first: an escape empties the query, and only the next one closes something, so the box is never a trap.
        if (self.search.text().len > 0) {
            self.search.clear();
            self.hit_cursor = 0;
            return true;
        }
        if (self.picking) {
            self.picking = false;
            self.hover_index = null;
            return true;
        }
        if (self.menu != null) {
            self.menu = null;
            return true;
        }
        if (self.open) {
            self.open = false;
            return true;
        }
        return false;
    }

    // Track the pointer between frames: the picker's outline follows it, one frame behind the app's own layout.
    pub fn onPointerMove(self: *Inspector, x: f32, y: f32) void {
        self.pointer = .{ .x = x, .y = y };
        if (self.picking) self.hover_index = self.snapshot.pick(x, y);
    }

    // Arm the picker: whatever is under the pointer is outlined, and the next click opens the window on it.
    pub fn startPicking(self: *Inspector) void {
        self.snapshot = Snapshot.build(self.width, self.height);
        self.picking = true;
        self.menu = null;
        self.hover_index = self.snapshot.pick(self.pointer.x, self.pointer.y);
    }

    // Take the node under the pointer: what a click does while the picker is armed.
    pub fn takePick(self: *Inspector) void {
        self.picking = false;
        if (self.hover_index) |i| {
            self.open = true;
            self.selectNode(i);
        }
        self.hover_index = null;
    }

    // Open the tree window on the node the menu was summoned over.
    pub fn openOnPicked(self: *Inspector) void {
        self.open = true;
        self.menu = null;
        for (self.snapshot.roots[0..self.snapshot.root_count]) |root| {
            self.expanded[@intCast(root)] = true;
        }
        if (self.picked) |i| self.selectNode(i);
    }

    // Open the window on the root of the tree, which is what a screenshot or a demo wants: the whole app, one level in.
    pub fn openOnRoot(self: *Inspector) void {
        self.snapshot = Snapshot.build(self.width, self.height);
        self.open = true;
        self.menu = null;
        for (self.snapshot.roots[0..self.snapshot.root_count]) |root| {
            self.expanded[@intCast(root)] = true;
        }
        if (self.snapshot.root_count > 0) self.selectNode(@intCast(self.snapshot.roots[0]));
    }

    // Select a node and make sure every ancestor is expanded, so the row is on screen.
    pub fn selectNode(self: *Inspector, index: usize) void {
        if (index >= self.snapshot.count) return;
        // Another node means another set of lines, so the copied mark goes with the node it belonged to.
        if (self.selected != index) self.copied_line = null;
        self.selected = index;
        var p = self.snapshot.items[index].parent;
        while (p >= 0) : (p = self.snapshot.items[@intCast(p)].parent) {
            self.expanded[@intCast(p)] = true;
        }
    }

    // A row click: the first click selects, a second click on an expanded row folds it away.
    pub fn clickRow(self: *Inspector, index: usize) void {
        if (index >= self.snapshot.count) return;
        if (self.selected != null and self.selected.? == index and self.snapshot.hasChildren(index)) {
            self.expanded[index] = !self.expanded[index];
            return;
        }
        self.selectNode(index);
    }

    // ---- searching ----

    // The query, as the search box holds it: the draft IS the query, so no second copy can disagree with the text on screen.
    pub fn query(self: *const Inspector) []const u8 {
        return self.search.text();
    }

    // Put a query in the box from outside: bind first, because a draft written into an unbound field is wiped by the bind's own buffer.
    pub fn setQuery(self: *Inspector, query_text: []const u8) void {
        self.search.bind();
        self.search.setText(query_text);
    }

    // Whether a query is narrowing the tree.
    pub fn filtering(self: *const Inspector) bool {
        return self.search.text().len > 0;
    }

    // A node is a hit when the query names its tag, its role, its label, its value, the component that declared it, the app call site or its Clay id.
    fn nodeMatches(self: *const Inspector, index: usize, needle: []const u8) bool {
        const item = self.snapshot.items[index];
        // An id is exact, not a substring: `1234` names one node, and `#1234`/`0x4d2` name the same one.
        if (idFromQuery(needle)) |wanted| {
            if (item.id == wanted) return true;
        }
        if (containsIgnoreCase(item.tag, needle)) return true;
        if (containsIgnoreCase(@tagName(item.role), needle)) return true;
        if (containsIgnoreCase(item.label, needle)) return true;
        if (containsIgnoreCase(item.value, needle)) return true;
        if (containsIgnoreCase(item.source, needle)) return true;
        if (item.declared) |declared| {
            if (containsIgnoreCase(declared.file, needle)) return true;
        }
        return false;
    }

    // Mark every hit and every subtree that holds one: two passes, because a parent may be declared after its children.
    fn computeMatches(self: *Inspector, needle: []const u8) void {
        for (self.snapshot.items[0..self.snapshot.count], 0..) |_, i| {
            self.matched[i] = self.nodeMatches(i, needle);
            self.context[i] = self.matched[i];
        }
        // Walk each hit up its parents, so a hit keeps the path that reaches it and the tree does not become a flat list.
        for (self.snapshot.items[0..self.snapshot.count], 0..) |_, i| {
            if (!self.matched[i]) continue;
            var p = self.snapshot.items[i].parent;
            while (p >= 0) : (p = self.snapshot.items[@intCast(p)].parent) self.context[@intCast(p)] = true;
        }
    }

    // Enter in the search box: select the next hit and bring its row into view.
    pub fn stepHit(self: *Inspector) void {
        if (self.hit_count == 0) return;
        if (self.hit_cursor >= self.hit_count) self.hit_cursor = 0;
        const row = self.hits[self.hit_cursor];
        self.hit_cursor = (self.hit_cursor + 1) % self.hit_count;
        self.selectNode(self.rows[row].node);
        self.revealRow(row);
    }

    // Bring a row into the viewport by nudging the body's scroll offset — the same lever a scroll container pulls.
    fn revealRow(self: *Inspector, row_index: usize) void {
        const data = cl.getScrollContainerData(bodyId());
        if (!data.found) return;
        const viewport = data.scroll_container_dimensions.h;
        // The row list is this frame's; the container's content height is the last frame's, so the larger of the two is the honest one.
        const content = @max(data.content_dimensions.h, @as(f32, @floatFromInt(self.row_count)) * row_h);
        const top = @as(f32, @floatFromInt(row_index)) * row_h;
        const bottom = top + row_h;
        const max_off = @max(0, content - viewport);
        var off = @max(0, -data.scroll_position.y);
        if (top < off) off = top else if (bottom > off + viewport) off = bottom - viewport;
        data.scroll_position.y = -@min(@max(off, 0), max_off);
    }

    // Close the panel, and drop what belonged to it: a filtered tree must not outlive its query, and the app's own fields get the keyboard back.
    pub fn close(self: *Inspector) void {
        self.open = false;
        self.picking = false;
        self.hover_index = null;
        self.search.clear();
        self.hit_cursor = 0;
        self.copied_line = null;
        frame.setFocus(null);
    }

    // ---- drawing ----

    // Declare the overlay. The Host calls this after the app's own root, so the panel paints over everything and the app stays unmodified.
    pub fn declare(self: *Inspector, w: u32, h: u32) void {
        self.width = w;
        self.height = h;
        if (self.isIdle()) return;
        // The app declared its nodes a moment ago; their geometry is the last resolve, which is one frame old and exactly what an overlay can show.
        self.snapshot.rebuildPreserving();
        // A window opened without a picked node still shows the top of the tree, rather than one collapsed row.
        if (!self.seeded) {
            self.seeded = true;
            for (self.snapshot.roots[0..self.snapshot.root_count]) |root| {
                self.expanded[@intCast(root)] = true;
            }
        }
        self.flatten();
        // The overlay is a real widget tree that is not the app's: the search box must not appear in the tree it searches.
        semantics.pause();
        defer semantics.unpause();
        if (self.outlinedNode()) |i| self.declareOutline(i);
        if (self.menu) |m| self.declareMenu(m);
        if (self.open) self.declarePanel();
        if (self.picking) self.declarePickCatcher();
    }

    // Flatten the open branches into the row list the window draws, or — with a query up — only the paths that end in a hit.
    fn flatten(self: *Inspector) void {
        self.row_count = 0;
        self.hit_count = 0;
        const q = self.search.text();
        // A new query restarts the walk, so Enter's cursor never points into the previous result list.
        const same = q.len == self.last_query_len and std.mem.eql(u8, q, self.last_query[0..self.last_query_len]);
        if (!same) {
            self.hit_cursor = 0;
            self.last_query_len = @min(q.len, self.last_query.len);
            @memcpy(self.last_query[0..self.last_query_len], q[0..self.last_query_len]);
        }
        if (q.len == 0) {
            for (self.snapshot.roots[0..self.snapshot.root_count]) |root| self.flattenNode(@intCast(root), 0);
            return;
        }
        self.computeMatches(q);
        for (self.snapshot.roots[0..self.snapshot.root_count]) |root| self.flattenFiltered(@intCast(root), 0);
    }

    // The filtered tree: every hit, inside the ancestor path that leads to it, so a hit is shown where it lives.
    fn flattenFiltered(self: *Inspector, index: usize, depth: u8) void {
        if (self.row_count >= max_rows or depth > 15 or index >= self.snapshot.count) return;
        if (!self.context[index]) return;
        const hit = self.matched[index];
        if (hit and self.hit_count < self.hits.len) {
            self.hits[self.hit_count] = @intCast(self.row_count);
            self.hit_count += 1;
        }
        self.rows[self.row_count] = .{ .node = @intCast(index), .depth = depth, .matched = hit };
        self.row_count += 1;
        var c = self.snapshot.items[index].first_child;
        while (c >= 0) : (c = self.snapshot.items[@intCast(c)].next_sibling) {
            self.flattenFiltered(@intCast(c), depth + 1);
        }
    }

    fn flattenNode(self: *Inspector, index: usize, depth: u8) void {
        if (self.row_count >= max_rows or depth > 15) return;
        self.rows[self.row_count] = .{ .node = @intCast(index), .depth = depth };
        self.row_count += 1;
        if (!self.expanded[index]) return;
        var c = self.snapshot.items[index].first_child;
        while (c >= 0) : (c = self.snapshot.items[@intCast(c)].next_sibling) {
            self.flattenNode(@intCast(c), depth + 1);
        }
    }

    // The outline the pointer puts on a node: a tinted fill and an accent border over the box, plus a badge naming it.
    fn declareOutline(self: *Inspector, index: usize) void {
        if (index >= self.snapshot.count) return;
        const item = self.snapshot.items[index];
        const r = item.visibleRect();
        if (r.width < 1 or r.height < 1) return;
        cl.UI()(.{
            .id = outlineId(),
            .floating = .{
                .attach_to = .to_root,
                .offset = .{ .x = r.x, .y = r.y },
                .z_index = panel_z - 3,
                .pointer_capture_mode = .passthrough,
            },
            .layout = .{ .sizing = .{ .w = .fixed(r.width), .h = .fixed(r.height) } },
            .background_color = tint.toClay(),
            .border = .{ .color = accent.toClay(), .width = .outside(1) },
        })({});
        // The badge sits just above the node, or inside its top-left corner when the node has no room above it.
        const above = r.y >= badge_h + 2;
        cl.UI()(.{
            .id = outlineBadgeId(),
            .floating = .{
                .attach_to = .to_root,
                .offset = .{ .x = r.x, .y = if (above) r.y - badge_h - 1 else r.y + 1 },
                .z_index = panel_z - 2,
                .pointer_capture_mode = .passthrough,
            },
            .layout = .{
                .sizing = .{ .w = .fit, .h = .fixed(badge_h) },
                .padding = .{ .left = 6, .right = 6 },
                .child_alignment = .center,
            },
            .background_color = accent.toClay(),
            .corner_radius = .all(3),
        })({
            const tag = if (item.tag.len > 0) item.tag else "(unnamed)";
            cl.text(frame.formatText("{s}  {s}", .{ tag, @tagName(item.role) }), .{ .font_size = 11, .color = badge_fg.toClay() });
        });
    }

    // A full-window catcher, armed with the picker: a click takes the outlined node and the app never sees it.
    fn declarePickCatcher(self: *Inspector) void {
        const win_w: f32 = @floatFromInt(@max(self.width, 1));
        const win_h: f32 = @floatFromInt(@max(self.height, 1));
        cl.UI()(.{
            .id = pickCatcherId(),
            .floating = .{ .attach_to = .to_root, .offset = .{ .x = 0, .y = 0 }, .z_index = panel_z - 4 },
            .layout = .{ .sizing = .{ .w = .fixed(win_w), .h = .fixed(win_h) } },
            .background_color = Color.rgba(0, 0, 0, 0).toClay(),
        })({});
        // One step under the window's own controls, so an armed picker never makes the panel unusable.
        registry.registerZCursor(pickCatcherId(), onPickCatcher, self, 0, hit_z - 2, .pointer);
    }

    fn declareMenu(self: *Inspector, at: cl.Vector2) void {
        const menu_w: f32 = 244;
        const menu_h: f32 = 46;
        const win_w: f32 = @floatFromInt(@max(self.width, 1));
        const win_h: f32 = @floatFromInt(@max(self.height, 1));
        const x = @min(@max(4, at.x), @max(4, win_w - menu_w - 4));
        const y = @min(@max(4, at.y), @max(4, win_h - menu_h - 4));

        // A transparent full-window catcher, so a click anywhere else dismisses the menu instead of reaching the app.
        cl.UI()(.{
            .id = backdropId(),
            .floating = .{ .attach_to = .to_root, .offset = .{ .x = 0, .y = 0 }, .z_index = panel_z - 2 },
            .layout = .{ .sizing = .{ .w = .fixed(win_w), .h = .fixed(win_h) } },
            .background_color = Color.rgba(0, 0, 0, 0).toClay(),
        })({});
        registry.registerZCursor(backdropId(), onBackdrop, self, 0, hit_z - 1, .default);

        cl.UI()(.{
            .id = menuId(),
            .floating = .{ .attach_to = .to_root, .offset = .{ .x = x, .y = y }, .z_index = panel_z - 1 },
            .layout = .{
                .direction = .top_to_bottom,
                .sizing = .{ .w = .fixed(menu_w), .h = .fixed(menu_h) },
                .padding = .{ .left = 10, .right = 10, .top = 7, .bottom = 7 },
                .child_gap = 2,
            },
            .background_color = bg.toClay(),
            .corner_radius = .all(8),
            .border = .{ .color = divider.toClay(), .width = .outside(1) },
        })({
            cl.text("Inspect element", .{ .font_size = 13, .color = fg.toClay() });
            cl.text(pickedLine(self), .{ .font_size = 11, .color = dim.toClay() });
        });
        registry.registerZCursor(menuId(), onMenuInspect, self, 0, hit_z, .pointer);
    }

    fn declarePanel(self: *Inspector) void {
        const win_w: f32 = @floatFromInt(@max(self.width, 1));
        const pw = self.panelWidth();
        const ph = self.panelHeight();
        const px = @max(12, win_w - pw - 12);
        const py: f32 = 12;

        cl.UI()(.{
            .id = panelId(),
            .floating = .{ .attach_to = .to_root, .offset = .{ .x = px, .y = py }, .z_index = panel_z },
            .layout = .{
                .direction = .top_to_bottom,
                .sizing = .{ .w = .fixed(pw), .h = .fixed(ph) },
                .child_gap = 0,
            },
            .background_color = bg.toClay(),
            .corner_radius = .all(10),
            .border = .{ .color = divider.toClay(), .width = .outside(1) },
        })({
            self.declareHeader();
            self.declareSearch();
            self.declareBody(ph);
            self.declareDetail();
        });
        // The panel swallows clicks on its own face, one step under the rows, so a control behind it never fires and the rows still answer.
        registry.registerZCursor(panelId(), swallow, self, 0, hit_z - 1, .default);
    }

    fn declareHeader(self: *Inspector) void {
        cl.UI()(.{
            .id = headerId(),
            .layout = .{
                .direction = .left_to_right,
                .sizing = .{ .w = .grow, .h = .fixed(30) },
                .padding = .{ .left = 10, .right = 6 },
                .child_alignment = .{ .x = .left, .y = .center },
                .child_gap = 6,
            },
            .background_color = surface.toClay(),
            .corner_radius = .{ .top_left = 10, .top_right = 10 },
        })({
            cl.text(frame.formatText("Inspector  {d} nodes", .{self.snapshot.count}), .{ .font_size = 13, .color = fg.toClay() });
            cl.UI()(.{
                .id = headerSpacerId(),
                .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(1) } },
            })({});
            // The picker: armed, the next click in the app takes the node under the pointer, like a browser's element inspector.
            cl.UI()(.{
                .id = pickButtonId(),
                .layout = .{
                    .sizing = .{ .w = .fixed(34), .h = .fixed(20) },
                    .child_alignment = .center,
                },
                .background_color = (if (self.picking) accent.toClay() else if (cl.hovered()) hover.toClay() else surface.toClay()),
                .corner_radius = .all(5),
            })({
                cl.text("pick", .{ .font_size = 10, .color = if (self.picking) badge_fg.toClay() else fg.toClay() });
            });
            cl.UI()(.{
                .id = closeId(),
                .layout = .{
                    .sizing = .{ .w = .fixed(22), .h = .fixed(20) },
                    .child_alignment = .center,
                },
                .background_color = (if (cl.hovered()) hover.toClay() else surface.toClay()),
                .corner_radius = .all(5),
            })({
                cl.text("x", .{ .font_size = 12, .color = fg.toClay() });
            });
        });
        registry.registerZCursor(closeId(), onClose, self, 0, hit_z, .pointer);
        registry.registerZCursor(pickButtonId(), onPickButton, self, 0, hit_z, .pointer);
    }

    // The search bar: a real field and, while a query is up, how many nodes it names.
    fn declareSearch(self: *Inspector) void {
        // The field answers ABOVE the panel's own click swallow, or every click on it would be eaten by the panel.
        self.search.click_z = hit_z;
        // Enter walks the hits; the handler refuses the draft, so submitting never empties the box it was typed in.
        self.search.on_submit = .{ .f = onSearchSubmit, .ctx = self };
        cl.UI()(.{
            .id = searchBarId(),
            .layout = .{
                .direction = .left_to_right,
                .sizing = .{ .w = .grow, .h = .fixed(search_h) },
                .padding = .{ .left = 8, .right = 8, .bottom = 6 },
                .child_alignment = .{ .x = .left, .y = .center },
                .child_gap = 6,
            },
            .background_color = surface.toClay(),
        })({
            input_mod.textField(&self.search);
            if (self.filtering()) {
                const n = self.hit_count;
                const label = if (n == 0) "no hits" else if (n == 1) "1 hit" else frame.formatText("{d} hits", .{n});
                cl.text(label, .{ .font_size = 10, .color = (if (n == 0) dim else accent).toClay() });
            } else if (self.copied_line != null) {
                // A copy happened and the box is idle: say so, and the marked line shows what it was.
                cl.text("copied", .{ .font_size = 10, .color = accent.toClay() });
            }
        });
    }

    // The scrolling tree. Only the rows inside the viewport are declared, and spacers keep the content as tall as the full list.
    fn declareBody(self: *Inspector, panel_h: f32) void {
        const body_h = panel_h - 30 - search_h - detail_h;
        const offset = @max(0, -cl.getScrollOffsetById(bodyId()).y);
        const shown: usize = @intFromFloat(@max(1, body_h / row_h));
        const first = @min(self.row_count, @as(usize, @intFromFloat(@floor(offset / row_h))));
        const last = @min(self.row_count, first + shown + 1);

        cl.UI()(.{
            .id = bodyId(),
            .layout = .{
                .direction = .top_to_bottom,
                .sizing = .{ .w = .grow, .h = .fixed(@max(0, body_h)) },
            },
            .clip = .{ .vertical = true, .child_offset = cl.getScrollOffsetById(bodyId()) },
        })({
            if (first > 0) spacer(topSpacerId(), @as(f32, @floatFromInt(first)) * row_h);
            for (self.rows[first..last], first..) |row, i| self.declareRow(row, i);
            if (last < self.row_count) spacer(bottomSpacerId(), @as(f32, @floatFromInt(self.row_count - last)) * row_h);
        });
    }

    fn declareRow(self: *Inspector, row: Row, index: usize) void {
        const item = self.snapshot.items[row.node];
        const is_selected = self.selected != null and self.selected.? == row.node;
        const caret = if (!self.snapshot.hasChildren(row.node)) " " else if (self.expanded[row.node]) "-" else "+";
        const tag = if (item.tag.len > 0) item.tag else "(unnamed)";
        cl.UI()(.{
            .id = rowId(row.node),
            .layout = .{
                .direction = .left_to_right,
                .sizing = .{ .w = .grow, .h = .fixed(row_h) },
                .padding = .{ .left = 6 + @as(u16, row.depth) * 11, .right = 6 },
                .child_alignment = .{ .x = .left, .y = .center },
                .child_gap = 5,
            },
            .background_color = (if (is_selected) sel_bg.toClay() else if (cl.hovered()) hover.toClay() else bg.toClay()),
            .border = .{ .color = (if (is_selected) accent.toClay() else Color.rgba(0, 0, 0, 0).toClay()), .width = .{ .left = 2 } },
        })({
            cl.text(caret, .{ .font_size = 11, .color = dim.toClay() });
            cl.text(tag, .{ .font_size = 12, .color = (if (is_selected) fg else if (row.matched) accent else text).toClay() });
            cl.text(@tagName(item.role), .{ .font_size = 10, .color = dim.toClay() });
        });
        registry.registerZCursor(rowId(row.node), onRow, self, index, hit_z, .pointer);
    }

    fn declareDetail(self: *Inspector) void {
        cl.UI()(.{
            .id = detailId(),
            .layout = .{
                .direction = .top_to_bottom,
                .sizing = .{ .w = .grow, .h = .fixed(detail_h) },
                .padding = .{ .left = 10, .right = 10, .top = 6, .bottom = 6 },
                .child_gap = 2,
            },
            .background_color = surface.toClay(),
            .corner_radius = .{ .bottom_left = 10, .bottom_right = 10 },
            .border = .{ .color = divider.toClay(), .width = .{ .top = 1 } },
        })({
            if (self.selected) |i| {
                const it = self.snapshot.items[i];
                // One row per line, so a line can be hovered, clicked and copied: a text run alone has no box to hit.
                var slot: usize = 0;
                while (slot < detail_lines) : (slot += 1) {
                    const line = self.detailLine(it, i, slot) orelse continue;
                    self.declareDetailLine(slot, line);
                }
            } else {
                cl.text("Right-click the app, then Inspect element.", .{ .font_size = 11, .color = dim.toClay() });
            }
        });
    }

    // The detail's lines, by slot: what to draw, and what a click copies. A slot that does not apply is null.
    fn detailLine(self: *const Inspector, it: snapshot_mod.Item, index: usize, slot: usize) ?DetailLine {
        const tag = if (it.tag.len > 0) it.tag else "(unnamed)";
        return switch (slot) {
            0 => .{ .text = frame.formatText("{s}  ({s})", .{ tag, @tagName(it.role) }), .copy = tag, .color = fg, .size = .{ .px = 12 } },
            // The Clay id, in the same decimal the JSON dump prints as `hash`, so it can be pasted into the search box.
            1 => .{ .text = frame.formatText("id {d}", .{it.id}), .copy = frame.formatText("{d}", .{it.id}), .color = dim, .size = .{ .px = 10 } },
            2 => .{ .text = frame.formatText("box {d:.0},{d:.0}  {d:.0}x{d:.0}   visible {d:.0}%", .{
                it.bounds.x, it.bounds.y, it.bounds.width, it.bounds.height, it.visible * 100,
            }), .copy = frame.formatText("{d:.0},{d:.0} {d:.0}x{d:.0}", .{ it.bounds.x, it.bounds.y, it.bounds.width, it.bounds.height }), .color = text, .size = .{ .px = 11 } },
            3 => .{ .text = frame.formatText("clip {d:.0},{d:.0}  {d:.0}x{d:.0}   z {d}", .{
                it.clip.x, it.clip.y, it.clip.width, it.clip.height, it.z,
            }), .copy = frame.formatText("clip {d:.0},{d:.0} {d:.0}x{d:.0} z {d}", .{ it.clip.x, it.clip.y, it.clip.width, it.clip.height, it.z }), .color = dim, .size = .{ .px = 11 } },
            4 => blk: {
                var action_buf: [96]u8 = undefined;
                var flag_buf: [96]u8 = undefined;
                const actions = snapshot_mod.actionList(it.actions, &action_buf);
                const flags = snapshot_mod.flagList(it.flags, &flag_buf);
                break :blk .{ .text = frame.formatText("actions [{s}]  flags [{s}]", .{ actions, flags }), .copy = frame.formatText("actions [{s}] flags [{s}]", .{ actions, flags }), .color = dim, .size = .{ .px = 11 } };
            },
            // Where the code lives: the widget that drew the node, and — when the app passed `.src = @src()` — its call site.
            5 => if (it.source.len > 0) .{ .text = frame.formatText("component  {s}", .{it.source}), .copy = it.source, .color = accent, .size = .{ .px = 11 } } else null,
            6 => if (it.declared) |declared| .{
                .text = frame.formatText("declared   {s}/{s}:{d}", .{ declared.module, declared.file, declared.line }),
                .copy = frame.formatText("{s}/{s}:{d}", .{ declared.module, declared.file, declared.line }),
                .color = accent,
                .size = .{ .px = 11 },
            } else null,
            7 => if (it.label.len > 0) .{ .text = frame.formatText("\"{s}\"", .{it.label}), .copy = it.label, .color = accent, .size = .{ .px = 11 } } else null,
            // Its path from the root, so the selection has a place in the app and not only a parent.
            8 => blk: {
                const path = self.ancestryText(index);
                break :blk if (path.len > 0) .{ .text = path, .copy = path, .color = dim, .size = .{ .px = 10 } } else null;
            },
            else => null,
        };
    }

    // One clickable line: hovering lights it, and a click highlights it and puts its text on the clipboard.
    fn declareDetailLine(self: *Inspector, slot: usize, line: DetailLine) void {
        const is_copied = self.copied_line != null and self.copied_line.? == @as(u8, @intCast(slot));
        cl.UI()(.{
            .id = detailLineId(slot),
            .layout = .{
                .direction = .left_to_right,
                .sizing = .{ .w = .grow, .h = .fit },
                .padding = .{ .left = 3, .right = 3 },
                .child_alignment = .{ .x = .left, .y = .center },
            },
            // The copied line stays marked, so the panel answers "what did I just put on the clipboard?".
            .background_color = (if (is_copied) sel_bg else if (cl.hovered()) hover else Color.rgba(0, 0, 0, 0)).toClay(),
            .corner_radius = .all(3),
        })({
            cl.text(line.text, .{ .font_size = line.size.whole(), .color = line.color.toClay() });
        });
        registry.registerZCursor(detailLineId(slot), onDetailLine, self, slot, hit_z, .pointer);
    }

    // Click a detail line: the line's value goes to the clipboard, and the line keeps the mark.
    pub fn copyLine(self: *Inspector, slot: usize) void {
        const i = self.selected orelse return;
        const line = self.detailLine(self.snapshot.items[i], i, slot) orelse return;
        self.clipboard.write(line.copy);
        self.copied_line = @intCast(slot);
    }

    // The selected node's nearest ancestors, as one line: where the row sits, without a path too long to draw.
    fn ancestryText(self: *const Inspector, index: usize) []const u8 {
        if (index >= self.snapshot.count) return "";
        const buf = frame.claimText(240);
        if (buf.len == 0) return "";
        var w = std.Io.Writer.fixed(buf);
        var chain: [16]usize = undefined;
        var n: usize = 0;
        var p = self.snapshot.items[index].parent;
        while (p >= 0 and n < chain.len) : (p = self.snapshot.items[@intCast(p)].parent) {
            chain[n] = @intCast(p);
            n += 1;
        }
        // The three nearest parents, outermost first: the deepest are what identify the row, the root is implied.
        const shown = @min(n, 3);
        if (n > shown) w.writeAll("... > ") catch return w.buffered();
        var i = shown;
        while (i > 0) {
            i -= 1;
            const ancestor = self.snapshot.items[chain[i]];
            w.writeAll(if (ancestor.tag.len > 0) ancestor.tag else "(unnamed)") catch return w.buffered();
            if (i > 0) w.writeAll(" > ") catch return w.buffered();
        }
        return w.buffered();
    }

    // ---- ids, colours, constants ----

    const row_h: f32 = 21;
    const detail_h: f32 = 152;
    const search_h: f32 = 30;
    // The detail's slots: tag, id, box, clip, actions, component, declared, label, path.
    const detail_lines: usize = 9;
    const badge_h: f32 = 18;
    // Render z of the overlay: above any app float, which keeps the panel on top of popovers and dropdowns.
    const panel_z: i16 = 4000;
    // Click priority: above every app target (which register at z 0 or a small float z), so the panel answers first.
    const hit_z: i16 = 1000;
    const key_escape: u32 = 1;

    const bg = Color.hexC("#1c1c22");
    const surface = Color.hexC("#26262e");
    const hover = Color.hexC("#2f2f39");
    const divider = Color.hexC("#3a3a46");
    const fg = Color.hexC("#e4e4ea");
    const text = Color.hexC("#c8c8d0");
    const dim = Color.hexC("#8a8a94");
    const accent = Color.hexC("#7aa2c4");
    const sel_bg = Color.hexC("#233043");
    // The outline's fill: the accent at 15 %, so the node stays readable under it.
    const tint = Color.rgba(0x7a, 0xa2, 0xc4, 38);
    const badge_fg = Color.hexC("#101014");
};

// The search box's look: a compact field with a placeholder, so it says what it does before anything is typed.
fn searchField() input_mod.Field {
    return .{
        .id = .{ .text = search_field_id },
        .placeholder = "search components",
        .font_size = .{ .px = 12 },
        .h = .{ .fixed = 24 },
        .pad = prop.Pad.axes(0, 7),
        .radius = prop.Radius.all(5),
        .bg = Inspector.surface,
        .fg = Inspector.fg,
        .sel_bg = Inspector.sel_bg,
        .caret_fg = Inspector.accent,
        .placeholder_fg = Inspector.dim,
        .border = .{ .width = .{ .px = 1 }, .color = Inspector.divider },
    };
}

// A query that IS a number names a Clay id: `1293847561`, `#1293847561` and `0x4d2b8c19` all answer the same node.
fn idFromQuery(query: []const u8) ?u32 {
    var q = std.mem.trim(u8, query, " ");
    if (q.len > 0 and q[0] == '#') q = q[1..];
    if (q.len > 2 and q[0] == '0' and (q[1] == 'x' or q[1] == 'X')) {
        return std.fmt.parseInt(u32, q[2..], 16) catch null;
    }
    return std.fmt.parseInt(u32, q, 10) catch null;
}

// Case-insensitive substring search: a query that cared about case would miss `Button` for `button`.
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn pickedLine(self: *const Inspector) []const u8 {
    const i = self.picked orelse return "nothing under the pointer";
    const item = self.snapshot.items[i];
    const tag = if (item.tag.len > 0) item.tag else "(unnamed)";
    return frame.formatText("{s}  {s}", .{ tag, @tagName(item.role) });
}

fn backdropId() cl.ElementId {
    return .ID("glinlandui.inspector.backdrop");
}

fn menuId() cl.ElementId {
    return .ID("glinlandui.inspector.menu");
}

fn panelId() cl.ElementId {
    return .ID("glinlandui.inspector.panel");
}

fn searchBarId() cl.ElementId {
    return .ID("glinlandui.inspector.search.bar");
}

fn headerId() cl.ElementId {
    return .ID("glinlandui.inspector.header");
}

fn headerSpacerId() cl.ElementId {
    return .ID("glinlandui.inspector.header.spacer");
}

fn closeId() cl.ElementId {
    return .ID("glinlandui.inspector.close");
}

fn pickButtonId() cl.ElementId {
    return .ID("glinlandui.inspector.pick");
}

fn pickCatcherId() cl.ElementId {
    return .ID("glinlandui.inspector.pick.catcher");
}

fn outlineId() cl.ElementId {
    return .ID("glinlandui.inspector.outline");
}

fn outlineBadgeId() cl.ElementId {
    return .ID("glinlandui.inspector.outline.badge");
}

fn bodyId() cl.ElementId {
    return .ID("glinlandui.inspector.body");
}

fn detailId() cl.ElementId {
    return .ID("glinlandui.inspector.detail");
}

fn detailLineId(slot: usize) cl.ElementId {
    return .IDI("glinlandui.inspector.detail.line", @as(u32, @intCast(slot)) + 1);
}

fn topSpacerId() cl.ElementId {
    return .ID("glinlandui.inspector.rows.top");
}

fn bottomSpacerId() cl.ElementId {
    return .ID("glinlandui.inspector.rows.bottom");
}

fn rowId(node: u16) cl.ElementId {
    return .IDI("glinlandui.inspector.row", @as(u32, node) + 1);
}

fn spacer(id: cl.ElementId, h: f32) void {
    cl.UI()(.{
        .id = id,
        .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(h) } },
    })({});
}

fn onBackdrop(ctx: ?*anyopaque, _: usize) void {
    const self: *Inspector = @ptrCast(@alignCast(ctx.?));
    self.menu = null;
}

fn onMenuInspect(ctx: ?*anyopaque, _: usize) void {
    const self: *Inspector = @ptrCast(@alignCast(ctx.?));
    self.openOnPicked();
}

fn onClose(ctx: ?*anyopaque, _: usize) void {
    const self: *Inspector = @ptrCast(@alignCast(ctx.?));
    self.close();
}

// The header's pick button: arm the picker, or stand it down when it is already armed.
fn onPickButton(ctx: ?*anyopaque, _: usize) void {
    const self: *Inspector = @ptrCast(@alignCast(ctx.?));
    if (self.picking) {
        self.picking = false;
        self.hover_index = null;
        return;
    }
    self.startPicking();
}

fn onPickCatcher(ctx: ?*anyopaque, _: usize) void {
    const self: *Inspector = @ptrCast(@alignCast(ctx.?));
    self.takePick();
}

// Enter in the search box: step to the next hit. False, because the draft IS the query and the box must keep it.
fn onSearchSubmit(ctx: ?*anyopaque, _: []const u8) bool {
    const self: *Inspector = @ptrCast(@alignCast(ctx.?));
    self.stepHit();
    return false;
}

fn onDetailLine(ctx: ?*anyopaque, slot: usize) void {
    const self: *Inspector = @ptrCast(@alignCast(ctx.?));
    self.copyLine(slot);
}

fn onRow(ctx: ?*anyopaque, index: usize) void {
    const self: *Inspector = @ptrCast(@alignCast(ctx.?));
    const row = if (index < self.row_count) self.rows[index] else return;
    self.clickRow(row.node);
}

fn swallow(_: ?*anyopaque, _: usize) void {}

// ---- Tests: the whole flow, through a real Host frame ----

const host_mod = @import("../host.zig");
const frame_mod = @import("../frame.zig");
const button_mod = @import("../components/button.zig");
const box_mod = @import("../components/box.zig");
const dispatch = @import("../components/dispatch.zig");

const TestApp = struct {
    clicks: u32 = 0,
    // Extra buttons under the first, so a test can overflow the panel and watch a hit scroll into view.
    extra: usize = 0,

    fn root(ctx: ?*anyopaque, _: u32, _: u32) void {
        box_mod.box(.{
            .id = .{ .text = "dev.root" },
            .src = @src(),
            .direction = .column,
            .w = .grow,
            .h = .grow,
        }, ctx, children);
    }

    fn children(ctx: ?*anyopaque) void {
        const self: *TestApp = @ptrCast(@alignCast(ctx.?));
        button_mod.button(.{
            .id = .{ .text = "dev.btn" },
            .label = .{ .text = "OK" },
            .w = .{ .fixed = 120 },
            .h = .{ .fixed = 40 },
            .pad = .{},
            .on_click = .{ .f = onClick, .ctx = self },
        });
        var i: usize = 0;
        while (i < self.extra) : (i += 1) {
            button_mod.button(.{
                .id = prop.Id.at("dev.extra", i),
                .label = .{ .text = "OK" },
                .w = .{ .fixed = 120 },
                .h = .{ .fixed = 40 },
                .pad = .{},
            });
        }
    }

    fn onClick(ctx: ?*anyopaque) void {
        const self: *TestApp = @ptrCast(@alignCast(ctx.?));
        self.clicks += 1;
    }
};

// The frame probe: the ids of the rectangles one frame actually emitted, which is the only honest "is it on screen" answer.
fn captureRects(user_data: ?*anyopaque, commands: []const cl.RenderCommand, _: u32, _: u32) void {
    const self: *Harness = @ptrCast(@alignCast(user_data.?));
    self.rect_len = 0;
    for (commands) |cmd| {
        if (cmd.command_type != .rectangle) continue;
        if (self.rect_len >= self.rects.len) return;
        self.rects[self.rect_len] = cmd.id;
        self.rect_len += 1;
    }
}

const Harness = struct {
    app: TestApp = .{},
    insp: Inspector = .{},
    host: host_mod.Host = undefined,
    // The ids of the last frame's rectangles, so a test can distinguish "drawn" from "still in Clay's id map".
    rects: [512]u32 = undefined,
    rect_len: usize = 0,

    fn init(self: *Harness) !void {
        // page_allocator, matching every other Host test: the Clay arena is process-lifetime by design.
        self.host = try host_mod.Host.init(std.heap.page_allocator, &self.app, TestApp.root);
        self.host.inspect = &self.insp;
    }

    fn frame(self: *Harness, w: u32, h: u32) void {
        self.rect_len = 0;
        var options = frame_mod.FrameOptions{
            .resolve_semantics = true,
            .probe = captureRects,
            .probe_user_data = @ptrCast(self),
        };
        _ = self.host.frameWithOptions(w, h, &options);
    }

    fn drewRect(self: *const Harness, id: cl.ElementId) bool {
        for (self.rects[0..self.rect_len]) |drawn| {
            if (drawn == id.id) return true;
        }
        return false;
    }

    fn rightClick(self: *Harness, x: f32, y: f32) void {
        self.host.onPointerEvent(x, y, true, dispatch.BTN_RIGHT);
        self.host.onPointerEvent(x, y, false, dispatch.BTN_RIGHT);
    }

    fn click(self: *Harness, x: f32, y: f32) void {
        self.host.onPointerEvent(x, y, true, dispatch.BTN_LEFT);
        self.host.onPointerEvent(x, y, false, dispatch.BTN_LEFT);
    }
};

// The centre of an element the last frame laid out, which is where a click has to land to hit it.
fn centreOf(id: cl.ElementId) cl.Vector2 {
    const bb = cl.getElementData(id).bounding_box;
    return .{ .x = bb.x + bb.width * 0.5, .y = bb.y + bb.height * 0.5 };
}

test "a right click summons the menu and never reaches the app" {
    var h = Harness{};
    try h.init();
    h.frame(480, 360);
    // The point is over the app's own button.
    h.rightClick(20, 20);
    try std.testing.expectEqual(@as(u32, 0), h.app.clicks);
    try std.testing.expect(h.insp.menu != null);
    try std.testing.expect(!h.insp.isIdle());
    h.frame(480, 360);
    try std.testing.expect(cl.getElementData(menuId()).found);
    // The node under the pointer was picked, so the menu can name it.
    try std.testing.expect(h.insp.picked != null);
    try std.testing.expectEqualStrings("dev.btn", h.insp.snapshot.items[h.insp.picked.?].tag);
}

test "clicking the menu opens the tree window, and the window draws its rows" {
    var h = Harness{};
    try h.init();
    h.frame(480, 360);
    h.rightClick(20, 20);
    h.frame(480, 360);

    const item = centreOf(menuId());
    h.click(item.x, item.y);
    try std.testing.expect(h.insp.open);
    try std.testing.expect(h.insp.menu == null);

    h.frame(480, 360);
    try std.testing.expect(cl.getElementData(panelId()).found);
    try std.testing.expect(cl.getElementData(bodyId()).found);
    // The picked node's ancestors are expanded, so its row is on screen and clickable.
    const row = h.insp.snapshot.find(cl.getElementId("dev.btn").id).?;
    const index = for (h.insp.snapshot.items[0..h.insp.snapshot.count], 0..) |it, i| {
        if (it.id == row.id) break i;
    } else return error.TestUnexpectedResult;
    try std.testing.expect(cl.getElementData(rowId(@intCast(index))).found);
}

test "escape closes the window and is not the app's close intent" {
    var h = Harness{};
    try h.init();
    h.frame(480, 360);
    h.rightClick(20, 20);
    h.frame(480, 360);
    const item = centreOf(menuId());
    h.click(item.x, item.y);
    h.frame(480, 360);
    try std.testing.expect(h.insp.open);

    try std.testing.expect(!h.host.onKeyEvent(1, true));
    try std.testing.expect(!h.insp.open);
    // With nothing of the devtool's open, and no app handler asking to close, a later key is still not a close intent.
    try std.testing.expect(!h.host.onKeyEvent(1, true));
}

test "the app stays usable while the window is up: a click away from it reaches the button" {
    var h = Harness{};
    try h.init();
    h.frame(480, 360);
    h.rightClick(20, 20);
    h.frame(480, 360);
    const item = centreOf(menuId());
    h.click(item.x, item.y);
    h.frame(480, 360);

    // The panel is docked to the right, so the button at 0..120 x 0..40 is clear of it.
    const b = centreOf(cl.getElementId("dev.btn"));
    h.click(b.x, b.y);
    try std.testing.expectEqual(@as(u32, 1), h.app.clicks);
}

test "a right click on a menu that is already up just moves it" {
    var h = Harness{};
    try h.init();
    h.frame(480, 360);
    h.rightClick(20, 20);
    h.frame(480, 360);
    const first = h.insp.menu.?;
    h.rightClick(120, 90);
    try std.testing.expectApproxEqAbs(@as(f32, 120), h.insp.menu.?.x, 0.001);
    try std.testing.expect(first.x != h.insp.menu.?.x);
}

test "the picker outlines the node under the pointer, and a click opens the window on it" {
    var h = Harness{};
    try h.init();
    h.frame(480, 360);

    // Arm the picker, then walk over the button and over the container behind it: the outline follows the deepest node.
    h.insp.startPicking();
    h.host.onPointerEvent(20, 20, false, 0);
    h.frame(480, 360);
    const over_button = cl.getElementData(outlineId()).bounding_box;
    const btn = cl.getElementData(cl.getElementId("dev.btn")).bounding_box;
    try std.testing.expectApproxEqAbs(btn.x, over_button.x, 0.5);
    try std.testing.expectApproxEqAbs(btn.width, over_button.width, 0.5);
    // The badge names what is about to be taken.
    try std.testing.expect(cl.getElementData(outlineBadgeId()).found);
    try std.testing.expectEqualStrings("dev.btn", h.insp.snapshot.items[h.insp.hover_index.?].tag);

    h.host.onPointerEvent(300, 300, false, 0);
    h.frame(480, 360);
    const over_root = cl.getElementData(outlineId()).bounding_box;
    try std.testing.expectEqualStrings("dev.root", h.insp.snapshot.items[h.insp.hover_index.?].tag);
    try std.testing.expectApproxEqAbs(@as(f32, 480), over_root.width, 0.5);

    // Back over the button, then click: that node is taken and the window opens; the app's own button never fires.
    h.host.onPointerEvent(20, 20, false, 0);
    h.frame(480, 360);
    h.click(20, 20);
    try std.testing.expect(h.insp.open);
    try std.testing.expect(!h.insp.picking);
    try std.testing.expectEqual(@as(u32, 0), h.app.clicks);
    try std.testing.expectEqualStrings("dev.btn", h.insp.snapshot.items[h.insp.selected.?].tag);

    h.frame(480, 360);
    try std.testing.expect(cl.getElementData(panelId()).found);
}

test "escape stands the picker down before it closes anything else" {
    var h = Harness{};
    try h.init();
    h.frame(480, 360);
    h.insp.startPicking();
    try std.testing.expect(!h.host.onKeyEvent(1, true));
    try std.testing.expect(!h.insp.picking);
    // The app is not closed by the key, and the devtool has nothing else to close.
    try std.testing.expect(!h.host.isQuit());
}

test "clicking a tree row outlines the component that row names" {
    var h = Harness{};
    try h.init();
    h.frame(480, 360);

    // Right-click the button and open the window on it: the row for it is selected, so the outline is already on it.
    h.rightClick(20, 20);
    h.frame(480, 360);
    const menu_item = centreOf(menuId());
    h.click(menu_item.x, menu_item.y);
    h.frame(480, 360);
    const btn = cl.getElementData(cl.getElementId("dev.btn")).bounding_box;
    try std.testing.expectApproxEqAbs(btn.x, cl.getElementData(outlineId()).bounding_box.x, 0.5);
    try std.testing.expectApproxEqAbs(btn.width, cl.getElementData(outlineId()).bounding_box.width, 0.5);

    // Click the ROOT's row: the outline moves to the container, which is what that row names.
    const root = @as(usize, @intCast(h.insp.snapshot.roots[0]));
    const row = centreOf(rowId(@intCast(root)));
    h.click(row.x, row.y);
    h.frame(480, 360);
    try std.testing.expectEqualStrings("dev.root", h.insp.snapshot.items[h.insp.selected.?].tag);
    const outlined = cl.getElementData(outlineId()).bounding_box;
    try std.testing.expectApproxEqAbs(@as(f32, 0), outlined.x, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 480), outlined.width, 0.5);
    // The badge names the selected node too, not only the picker's.
    try std.testing.expect(cl.getElementData(outlineBadgeId()).found);
}

test "a right click paints the menu, and no outline until the window is open" {
    var h = Harness{};
    try h.init();
    h.frame(480, 360);

    h.rightClick(20, 20);
    h.frame(480, 360);
    // The menu is up and names the node under the pointer...
    try std.testing.expect(h.drewRect(menuId()));
    // ...but nothing is painted over the app: the outline belongs to the window, and no window is open yet.
    try std.testing.expect(!h.drewRect(outlineId()));
    try std.testing.expect(!h.drewRect(outlineBadgeId()));
    try std.testing.expect(h.insp.outlinedNode() == null);

    // Opening the window is what starts the outline, and it frames the node that was inspected.
    const menu_item = centreOf(menuId());
    h.click(menu_item.x, menu_item.y);
    h.frame(480, 360);
    try std.testing.expect(h.drewRect(outlineId()));
    const btn = cl.getElementData(cl.getElementId("dev.btn")).bounding_box;
    try std.testing.expectApproxEqAbs(btn.width, cl.getElementData(outlineId()).bounding_box.width, 0.5);

    // Closing the window takes the outline with it.
    h.click(centreOf(closeId()).x, centreOf(closeId()).y);
    h.frame(480, 360);
    try std.testing.expect(!h.insp.open);
    try std.testing.expect(!h.drewRect(outlineId()));
}

test "every node names the component that declared it" {
    var h = Harness{};
    try h.init();
    h.frame(480, 360);

    const snap = Snapshot.build(480, 360);
    const btn = snap.find(cl.getElementId("dev.btn").id).?;
    // The file and line Zig reports for the component, whichever separator the host puts between them.
    try std.testing.expect(std.mem.indexOf(u8, btn.source, "button.zig:") != null);
    const root = snap.find(cl.getElementId("dev.root").id).?;
    try std.testing.expect(std.mem.indexOf(u8, root.source, "box.zig:") != null);
    // ...and the box that passed `.src = @src()` also names the app's own call site.
    try std.testing.expect(root.declared != null);
    try std.testing.expect(std.mem.endsWith(u8, root.declared.?.file, "inspector.zig"));
    // The module name is whatever the build called it, so only its presence is asserted here.
    try std.testing.expect(root.declared.?.module.len > 0);
    try std.testing.expect(btn.declared == null);
}

// ---- Tests: the search box ----

// Open the panel on the whole tree, the way a screenshot or a demo does, and settle one frame so the rows exist.
fn openTree(h: *Harness) void {
    h.insp.openOnRoot();
    h.frame(480, 360);
}

test "a query keeps its hits and the ancestor path that leads to them" {
    var h = Harness{};
    try h.init();
    h.frame(480, 360);
    openTree(&h);
    h.insp.search.setText("btn");
    h.frame(480, 360);

    // One hit, and the root above it as context: a hit is shown in the tree it belongs to, not in a flat list.
    try std.testing.expectEqual(@as(usize, 1), h.insp.hit_count);
    try std.testing.expectEqual(@as(usize, 2), h.insp.row_count);
    try std.testing.expect(!h.insp.rows[0].matched);
    try std.testing.expect(h.insp.rows[1].matched);
    try std.testing.expectEqualStrings("dev.root", h.insp.snapshot.items[h.insp.rows[0].node].tag);
    try std.testing.expectEqualStrings("dev.btn", h.insp.snapshot.items[h.insp.rows[1].node].tag);
    // The bar is on screen, so the query has somewhere to live.
    try std.testing.expect(cl.getElementData(searchBarId()).found);
}

test "a query matches a role, a component file and the app's call site, and a miss empties the tree" {
    var h = Harness{};
    try h.init();
    h.frame(480, 360);
    openTree(&h);

    // The role name.
    h.insp.search.setText("button");
    h.frame(480, 360);
    try std.testing.expect(h.insp.hit_count >= 1);
    // The file the widget itself lives in.
    h.insp.search.setText("button.zig");
    h.frame(480, 360);
    try std.testing.expectEqual(@as(usize, 1), h.insp.hit_count);
    // The app's own call site, which is the `.src = @src()` the root passed in this file.
    h.insp.search.setText("inspector.zig");
    h.frame(480, 360);
    try std.testing.expectEqual(@as(usize, 1), h.insp.hit_count);
    try std.testing.expectEqualStrings("dev.root", h.insp.snapshot.items[h.insp.rows[h.insp.hits[0]].node].tag);

    // A query nothing answers leaves no rows at all; the bar stays, so the query can be corrected.
    h.insp.search.setText("no-such-node");
    h.frame(480, 360);
    try std.testing.expectEqual(@as(usize, 0), h.insp.hit_count);
    try std.testing.expectEqual(@as(usize, 0), h.insp.row_count);
    try std.testing.expect(cl.getElementData(searchBarId()).found);
}

test "a numeric query names a node by its Clay id, in decimal, with #, or as 0x hex" {
    var h = Harness{};
    try h.init();
    h.frame(480, 360);
    openTree(&h);

    const btn = h.insp.snapshot.find(cl.getElementId("dev.btn").id).?;
    var dec: [16]u8 = undefined;
    var hex: [16]u8 = undefined;
    var hash: [18]u8 = undefined;
    const queries = [_][]const u8{
        try std.fmt.bufPrint(&dec, "{d}", .{btn.id}),
        try std.fmt.bufPrint(&hex, "0x{x}", .{btn.id}),
        try std.fmt.bufPrint(&hash, "#{d}", .{btn.id}),
    };
    for (queries) |q| {
        h.insp.search.setText(q);
        h.frame(480, 360);
        try std.testing.expectEqual(@as(usize, 1), h.insp.hit_count);
        try std.testing.expectEqual(btn.id, h.insp.snapshot.items[h.insp.rows[h.insp.hits[0]].node].id);
    }
}

test "the id parser takes the three spellings and refuses a word" {
    try std.testing.expectEqual(@as(?u32, 42), idFromQuery("42"));
    try std.testing.expectEqual(@as(?u32, 42), idFromQuery("#42"));
    try std.testing.expectEqual(@as(?u32, 0x2a), idFromQuery("0x2a"));
    try std.testing.expectEqual(@as(?u32, 0x2a), idFromQuery("0X2A"));
    try std.testing.expectEqual(@as(?u32, 42), idFromQuery(" 42 "));
    try std.testing.expectEqual(@as(?u32, null), idFromQuery("dev.btn"));
    try std.testing.expectEqual(@as(?u32, null), idFromQuery(""));
}

test "escape empties the query before it closes, and closing drops the query with the keyboard" {
    var h = Harness{};
    try h.init();
    h.frame(480, 360);
    openTree(&h);
    h.insp.search.setText("btn");
    h.frame(480, 360);
    // The hit and the root above it: two rows, not the whole tree.
    try std.testing.expectEqual(@as(usize, 2), h.insp.row_count);

    // First escape: the box empties and the tree comes back whole.
    try std.testing.expect(!h.host.onKeyEvent(1, true));
    try std.testing.expect(h.insp.open);
    try std.testing.expectEqual(@as(usize, 0), h.insp.query().len);
    h.frame(480, 360);
    try std.testing.expectEqual(@as(usize, 2), h.insp.row_count);

    // Second escape: with an empty box the panel is what closes.
    try std.testing.expect(!h.host.onKeyEvent(1, true));
    try std.testing.expect(!h.insp.open);

    // The close button drops the query and the keyboard together, so no field is left holding a focus nobody shows.
    openTree(&h);
    h.insp.search.setText("dev");
    h.frame(480, 360);
    const close = centreOf(closeId());
    h.click(close.x, close.y);
    try std.testing.expect(!h.insp.open);
    try std.testing.expectEqual(@as(usize, 0), h.insp.query().len);
    try std.testing.expect(frame_mod.focusedId() == null);
}

test "typing reaches the search box through the engine, above the panel's own click swallow" {
    var h = Harness{};
    try h.init();
    h.frame(480, 360);
    openTree(&h);

    const box = centreOf(cl.getElementId(search_field_id));
    h.click(box.x, box.y);
    h.frame(480, 360);
    // The click landed on the field and not on the panel under it, and the field took the keyboard.
    try std.testing.expect(frame_mod.isFocused(search_field_id));
    // Composed text — what macOS sends — types into it; nobody routed a key.
    try std.testing.expect(h.host.onTextEvent("btn"));
    h.frame(480, 360);
    try std.testing.expectEqualStrings("btn", h.insp.query());
    try std.testing.expectEqual(@as(usize, 1), h.insp.hit_count);
    // The keycode route edits the same box: Backspace deletes, and the tree widens again.
    try std.testing.expect(!h.host.onKeyEvent(14, true));
    h.frame(480, 360);
    try std.testing.expectEqualStrings("bt", h.insp.query());
}

test "a query handed in from outside becomes the box's draft on its first declare" {
    var h = Harness{};
    try h.init();
    h.frame(480, 360);
    // What `--query` does: set the value before the field has ever been declared or bound, which is the road a model edit takes.
    h.insp.openOnRoot();
    h.insp.setQuery("btn");
    h.frame(480, 360);
    try std.testing.expectEqualStrings("btn", h.insp.query());
    try std.testing.expectEqual(@as(usize, 1), h.insp.hit_count);
}

test "the inspector's own widgets never appear in the tree they search" {
    var h = Harness{};
    try h.init();
    h.frame(480, 360);
    openTree(&h);
    h.insp.search.setText("inspector");
    h.frame(480, 360);

    // The box is a real field with a semantics node of its own; the overlay's declare pauses registration, so the tree holds the app's two nodes and never the box.
    try std.testing.expect(h.insp.snapshot.find(cl.getElementId(search_field_id).id) == null);
    try std.testing.expectEqual(@as(usize, 2), h.insp.snapshot.count);
    try std.testing.expect(h.insp.snapshot.find(cl.getElementId("dev.btn").id) != null);
}

test "enter walks the hits and scrolls a far one into view" {
    var h = Harness{};
    try h.init();
    h.app.extra = 40;
    h.frame(480, 360);
    openTree(&h);
    h.insp.search.setText("dev.extra");
    h.frame(480, 360);
    try std.testing.expectEqual(@as(usize, 40), h.insp.hit_count);

    // The last hit's row is far below the viewport, so nothing of it is drawn yet.
    const last_row = h.insp.hits[h.insp.hit_count - 1];
    const last_node = h.insp.rows[last_row].node;
    try std.testing.expect(!h.drewRect(rowId(last_node)));

    // Enter walks down: 40 steps reach the last hit, and its row is scrolled into view.
    var i: usize = 0;
    while (i < 40) : (i += 1) h.insp.stepHit();
    h.frame(480, 360);
    try std.testing.expect(h.insp.selected != null);
    try std.testing.expectEqualStrings("dev.extra.39", h.insp.snapshot.items[h.insp.selected.?].tag);
    try std.testing.expect(cl.getScrollOffsetById(bodyId()).y < 0);
    try std.testing.expect(h.drewRect(rowId(last_node)));
}

// ---- Tests: the detail lines ----

var clip_buf: [512]u8 = undefined;
var clip_len: usize = 0;

fn fakeClipWrite(_: ?*anyopaque, text: []const u8) void {
    clip_len = @min(text.len, clip_buf.len);
    @memcpy(clip_buf[0..clip_len], text[0..clip_len]);
}

fn fakeClipRead(_: ?*anyopaque, buf: []u8) []const u8 {
    const n = @min(clip_len, buf.len);
    @memcpy(buf[0..n], clip_buf[0..n]);
    return buf[0..n];
}

// A pasteboard that lives in this file, and starts empty.
fn fakeClipboard() input_mod.Clipboard {
    clip_len = 0;
    return .{ .read_fn = fakeClipRead, .write_fn = fakeClipWrite };
}

fn clipboardText() []const u8 {
    return clip_buf[0..clip_len];
}

test "a detail line is clickable: it marks itself and copies its value, not its label" {
    var h = Harness{};
    try h.init();
    h.frame(480, 360);
    h.insp.clipboard = fakeClipboard();
    openTree(&h);

    // Slot 5 is the component line; with no copy and no hover it draws nothing of its own.
    try std.testing.expect(!h.drewRect(detailLineId(5)));
    const line = centreOf(detailLineId(5));
    h.click(line.x, line.y);
    h.frame(480, 360);

    // What lands on the clipboard is the value alone: the `component` label stays on screen, not in the paste.
    const selected = h.insp.selected.?;
    const source = h.insp.snapshot.items[selected].source;
    try std.testing.expect(std.mem.indexOf(u8, source, "box.zig:") != null);
    try std.testing.expectEqualStrings(source, clipboardText());
    try std.testing.expectEqual(@as(?u8, 5), h.insp.copied_line);
    // The mark is a fill, so the line now draws a rectangle of its own.
    try std.testing.expect(h.drewRect(detailLineId(5)));
}

test "the copied mark follows the last line clicked, and a new node drops it" {
    var h = Harness{};
    try h.init();
    h.frame(480, 360);
    h.insp.clipboard = fakeClipboard();
    openTree(&h);

    const comp = centreOf(detailLineId(5));
    h.click(comp.x, comp.y);
    h.frame(480, 360);
    try std.testing.expectEqual(@as(?u8, 5), h.insp.copied_line);

    // Another line on the same node: the mark moves and the clipboard holds the other value.
    const id_line = centreOf(detailLineId(1));
    h.click(id_line.x, id_line.y);
    h.frame(480, 360);
    try std.testing.expectEqual(@as(?u8, 1), h.insp.copied_line);
    const selected = h.insp.selected.?;
    var want: [16]u8 = undefined;
    const want_text = try std.fmt.bufPrint(&want, "{d}", .{h.insp.snapshot.items[selected].id});
    try std.testing.expectEqualStrings(want_text, clipboardText());

    // Another node: the lines are a different list, so nothing is marked as copied any more.
    const btn = h.insp.snapshot.find(cl.getElementId("dev.btn").id).?;
    const index = for (h.insp.snapshot.items[0..h.insp.snapshot.count], 0..) |it, i| {
        if (it.id == btn.id) break i;
    } else return error.TestUnexpectedResult;
    const row = centreOf(rowId(@intCast(index)));
    h.click(row.x, row.y);
    h.frame(480, 360);
    try std.testing.expectEqual(@as(?u8, null), h.insp.copied_line);
    // The clipboard keeps what it was given; only the mark is about the panel.
    try std.testing.expectEqualStrings(want_text, clipboardText());
}
