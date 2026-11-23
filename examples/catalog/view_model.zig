// The ViewModel and the only writer: every public function here is an intent, and it knows nothing of a window.
const std = @import("std");
const glinlandui = @import("glinlandui");
const frame = glinlandui.frame;
const input = glinlandui.components.input;
const scroll_mod = glinlandui.components.scroll;
const clipboard = glinlandui.clipboard;
const route = glinlandui.route;
const split_mod = glinlandui.components.split;
const sidebar_mod = glinlandui.components.sidebar;
const state_mod = @import("state.zig");

// Persistence: the document an app keeps, and the backend the host keeps it in.
const storage = glinlandui.storage;
const store = glinlandui.storage_backend;

const CatalogUiState = state_mod.CatalogUiState;
const Theme = glinlandui.theme.Theme;

// The ids the model itself needs: the field that takes the keyboard, the slider track an intent measures, and the page an anchor scrolls.
pub const field_id = "catalog.field";
pub const dd_field_id = "catalog.dd.field";
pub const slider_id = "catalog.slider";
pub const page_id = "catalog.scroll";

// Whether the page has been laid out yet: a box belongs to a frame that has already happened.
fn layoutKnown() bool {
    return frame.bounds(frame.clayId(page_id)) != null;
}

// The section lands at the top of the page: the boxes are the previous frame's, which is what the reader sees.
pub fn scrollToSection(index: usize) void {
    if (index >= state_mod.sections.len) return;
    const target = frame.bounds(frame.clayId(state_mod.sections[index].id)) orelse return;
    const pane = frame.bounds(frame.clayId(page_id)) orelse return;
    scroll_mod.scrollBy(page_id, 0, target.y - pane.y - 16);
}

// The whole page moves: an empty address is the top of the reference, which is where the reader starts.
fn scrollToTop() void {
    scroll_mod.scrollBy(page_id, 0, -1_000_000);
}

// Put the page where an address says. False when there is no layout yet, so the caller keeps the address pending.
fn applyRoute(here: route.Route) bool {
    if (!layoutKnown()) return false;
    if (here.isEmpty()) {
        scrollToTop();
        return true;
    }
    for (state_mod.sections, 0..) |s, i| {
        if (here.is(s.slug)) {
            scrollToSection(i);
            return true;
        }
    }
    // An address this page has no section for: the top is the only honest answer.
    scrollToTop();
    return true;
}

pub const CatalogViewModel = struct {
    // The state, as a plain value: an intent replaces it, and the next frame reads whatever it says.
    state: CatalogUiState = .{},

    // Compose keeps these in `remember`: a field owns a buffer, a caret and a draft, and every one of them outlives a frame.
    field: input.Field = .{ .id = .{ .text = field_id } },
    dd_field: input.Field = .{ .id = .{ .text = dd_field_id } },

    // A radio's click carries only a context, so each one gets a context the model owns.
    radio_ctxs: [state_mod.radio_count]RadioCtx = undefined,

    // The route generation this screen last acted on, the address it still has to move to, and the context each nav
    // row clicks with.
    seen_route: u32 = 0,
    pending: ?route.Route = null,
    goto_ctxs: [state_mod.sections.len]GotoCtx = undefined,

    // The two surfaces whose size the pointer owns: the widget keeps the gesture, the model keeps the number.
    split_state: split_mod.State = .{ .size = 150 },
    sidebar_state: sidebar_mod.State = .{ .width = 240, .expanded_width = 240 },

    // The toolkit forgets focus when a host starts, so the screen claims the keyboard once, on its first frame.
    focus_claimed: bool = false,

    // Which spacing kit the window is drawn with: the Activity reads this and hands the Host one theme or the other.
    dense: bool = false,

    // The host's document has been taken (or there was none), and whether this frame's intents owe a write.
    restored: bool = false,
    persist_dirty: bool = false,

    pub const RadioCtx = struct {
        vm: *CatalogViewModel,
        index: usize,
    };

    pub const GotoCtx = struct {
        vm: *CatalogViewModel,
        index: usize,
    };

    pub fn init() CatalogViewModel {
        return .{};
    }

    // `onCreate`: the two fields take their look and their intents, once, and the radio contexts point home.
    pub fn start(self: *CatalogViewModel, t: Theme) void {
        self.field = .{
            .id = .{ .text = field_id },
            .font_size = t.type_scale.body,
            .fg = t.colors.text,
            .bg = t.colors.background,
            .sel_fg = t.colors.text,
            .sel_bg = glinlandui.theme.selected,
            .caret_fg = t.colors.primary,
            .border = .{ .width = .{ .px = 1 }, .color = t.colors.divider },
            .on_change = .{ .f = onDraft, .ctx = self },
        };
        self.field.bind();

        // The dropdown paints its own look over this field each frame; the selection and the caret are what it leaves alone.
        self.dd_field = .{
            .id = .{ .text = dd_field_id },
            .sel_bg = glinlandui.theme.selected,
            .caret_fg = t.colors.primary,
            .on_change = .{ .f = onFilter, .ctx = self },
        };
        self.dd_field.bind();

        for (&self.radio_ctxs, 0..) |*rc, i| rc.* = .{ .vm = self, .index = i };
        for (&self.goto_ctxs, 0..) |*g, i| g.* = .{ .vm = self, .index = i };
    }

    // `val active by route`: the nav's star and the top bar's breadcrumb both read the address, so a back button moves them.
    pub fn isActive(self: *const CatalogViewModel, index: usize) bool {
        _ = self;
        if (index >= state_mod.sections.len) return false;
        return route.current().is(state_mod.sections[index].slug);
    }

    pub fn activeTitle(self: *const CatalogViewModel) []const u8 {
        _ = self;
        const here = route.current();
        for (state_mod.sections) |s| {
            if (here.is(s.slug)) return s.title;
        }
        return "overview";
    }

    // A click is an INTENT, not a scroll: it changes the address, and `syncRoute` is what moves the page — the same
    // path a deep link and the browser's back button take.
    pub fn gotoSection(self: *CatalogViewModel, index: usize) void {
        if (index >= state_mod.sections.len) return;
        const slug = state_mod.sections[index].slug;
        route.navigate(slug);
        // Opening a section is what the nav's "recently viewed" list records, and what makes the document worth writing.
        self.pushRecent(index);
        self.persist_dirty = true;
        // The address was already this one (a second click on the row the reader is on), so the intent still has to move.
        if (self.seen_route == route.generation()) scrollToSection(index);
    }

    // The address changed under the app — a deep link, Back, or the app's own intent: put the page where it says. A
    // window's first frame has no boxes yet, so an address that arrives before layout is held until the next frame.
    pub fn syncRoute(self: *CatalogViewModel) void {
        const generation = route.generation();
        if (generation != self.seen_route) {
            self.seen_route = generation;
            self.pending = route.current();
        }
        const here = self.pending orelse return;
        if (applyRoute(here)) {
            self.pending = null;
            return;
        }
        // There is no layout yet: ask for the frame that will have one, which is where a boot deep link lands.
        frame.requestFrame();
    }

    // The whole of persistence from the model's side: the host's document in once, and this frame's intents out.
    pub fn syncStorage(self: *CatalogViewModel) void {
        if (!self.restored) {
            self.restored = true;
            var buf: [storage.max_document_bytes]u8 = undefined;
            if (store.takeAdopted(&buf)) |bytes| {
                if (storage.Document.decode(bytes)) |doc| self.applyDocument(&doc);
            }
        }
        if (!self.persist_dirty) return;
        var buf: [storage.max_document_bytes]u8 = undefined;
        const bytes = self.document().encode(&buf) orelse return;
        // The debt is only paid once the bytes are actually in the slot: a stage that refuses them keeps it owed.
        if (store.stage(bytes)) self.persist_dirty = false;
    }

    // The settings a reader would notice were gone: the theme, the address, the picked controls, and where they have been.
    pub fn document(self: *const CatalogViewModel) storage.Document {
        var doc = storage.Document{};
        _ = doc.setBool("dense", self.dense);
        _ = doc.set("route", route.address());
        _ = doc.setInt("tab", @intCast(self.state.tab));
        _ = doc.setInt("tree", @intCast(self.state.tree_row));
        _ = doc.setInt("radio", @intCast(self.state.radio));
        _ = doc.setInt("slider", @intFromFloat(@round(std.math.clamp(self.state.slider, 0, 100))));
        _ = doc.setBool("checked", self.state.checked);
        _ = doc.setBool("toggled", self.state.toggled);
        var recent_buf: [storage.max_value]u8 = undefined;
        _ = doc.set("recent", self.recentText(&recent_buf));
        return doc;
    }

    // What the host kept, put back: every setting that is present, and nothing invented for the ones that are not.
    fn applyDocument(self: *CatalogViewModel, doc: *const storage.Document) void {
        if (doc.getBool("dense")) |on| self.dense = on;
        if (doc.getBool("checked")) |on| self.state = self.state.withChecked(on);
        if (doc.getBool("toggled")) |on| self.state = self.state.withToggled(on);
        if (doc.getInt("radio")) |v| {
            if (v < state_mod.radio_count) self.state = self.state.withRadio(@intCast(v));
        }
        if (doc.getInt("tab")) |v| self.state = self.state.withTab(@intCast(v));
        if (doc.getInt("tree")) |v| self.state = self.state.withTreeRow(@intCast(v));
        if (doc.getInt("slider")) |v| {
            if (v <= 100) self.state = self.state.withSlider(@floatFromInt(v));
        }
        if (doc.get("recent")) |raw| self.applyRecent(raw);
        // A deep link outranks a remembered address: a reader who typed one asked for that screen, not this one.
        if (doc.get("route")) |slug| {
            if (slug.len > 0 and route.current().isEmpty()) route.adopt(slug);
        }
    }

    // The recent list as the document stores it: the slugs, comma separated, most recent first.
    fn recentText(self: *const CatalogViewModel, buf: []u8) []const u8 {
        var n: usize = 0;
        for (self.state.recent[0..self.state.recent_len]) |index| {
            if (index >= state_mod.sections.len) continue;
            const slug = state_mod.sections[index].slug;
            if (n != 0 and n < buf.len) {
                buf[n] = ',';
                n += 1;
            }
            const take = @min(slug.len, buf.len - n);
            @memcpy(buf[n..][0..take], slug[0..take]);
            n += take;
        }
        return buf[0..n];
    }

    // The slugs a document remembered, resolved back to sections: a slug this build no longer has is simply skipped.
    fn applyRecent(self: *CatalogViewModel, raw: []const u8) void {
        var indices: [state_mod.max_recent]usize = undefined;
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, raw, ',');
        while (it.next()) |slug| {
            if (n == state_mod.max_recent) break;
            if (slug.len == 0) continue;
            for (state_mod.sections, 0..) |s, i| {
                if (std.mem.eql(u8, s.slug, slug)) {
                    indices[n] = i;
                    n += 1;
                    break;
                }
            }
        }
        self.state = self.state.withRecent(indices[0..n]);
    }

    // The section the reader just opened goes to the front; the list keeps its bound and drops the duplicate.
    fn pushRecent(self: *CatalogViewModel, index: usize) void {
        if (index >= state_mod.sections.len) return;
        var indices: [state_mod.max_recent]usize = undefined;
        indices[0] = index;
        var n: usize = 1;
        for (self.state.recent[0..self.state.recent_len]) |old| {
            if (n == state_mod.max_recent) break;
            if (old == index) continue;
            indices[n] = old;
            n += 1;
        }
        self.state = self.state.withRecent(indices[0..n]);
    }

    // A snippet is worth reading and worth keeping: the system clipboard takes the text, the page says so.
    pub fn copyUsage(self: *CatalogViewModel, index: usize) void {
        if (index >= state_mod.sections.len) return;
        clipboard.write(state_mod.sections[index].snippet);
        self.state = self.state.withLast("usage copied");
    }

    // `val state by vm.state`: the value the view draws.
    pub fn uiState(self: *const CatalogViewModel) CatalogUiState {
        return self.state;
    }

    pub fn claimFocus(self: *CatalogViewModel) void {
        if (self.focus_claimed) return;
        self.focus_claimed = true;
        frame.setFocus(field_id);
    }

    // `onCleared()`: the store calls this when the screen goes away. This model holds no timers and no buffers.
    pub fn onCleared(self: *CatalogViewModel) void {
        _ = self;
    }

    // The field reports an edit as `(ctx, text)`, so the widget's shape and the intent's shape meet here.
    fn onDraft(raw: ?*anyopaque, text: []const u8) void {
        const self: *CatalogViewModel = @ptrCast(@alignCast(raw.?));
        self.setDraft(text);
    }

    fn onFilter(raw: ?*anyopaque, text: []const u8) void {
        const self: *CatalogViewModel = @ptrCast(@alignCast(raw.?));
        self.setFilter(text);
    }

    // `fun onInputChange(text: String)`: the draft is state, and it is also what the header reports.
    pub fn setDraft(self: *CatalogViewModel, text: []const u8) void {
        self.state = self.state.withDraft(text).withLast(text);
    }

    // `fun onFilterChange(text: String)`: only the filter moves — the filter is not the field the header reports.
    pub fn setFilter(self: *CatalogViewModel, text: []const u8) void {
        self.state = self.state.withFilter(text);
    }

    // `fun onCheck()` — a checkbox reports a click, so the intent flips what the state says.
    pub fn toggleChecked(self: *CatalogViewModel) void {
        const on = !self.state.checked;
        self.state = self.state.withChecked(on).withLast(if (on) "checked" else "unchecked");
        self.persist_dirty = true;
    }

    pub fn pickRadio(self: *CatalogViewModel, index: usize) void {
        self.state = self.state.withRadio(index).withLast("radio picked");
        self.persist_dirty = true;
    }

    pub fn toggleSwitch(self: *CatalogViewModel) void {
        const on = !self.state.toggled;
        self.state = self.state.withToggled(on).withLast(if (on) "toggle on" else "toggle off");
        self.persist_dirty = true;
    }

    // The slider reports a click, not a value: the intent reads the pointer against the track the view declared.
    pub fn slide(self: *CatalogViewModel) void {
        const track = frame.bounds(frame.clayId(slider_id)) orelse return;
        if (track.width <= 0) return;
        const frac = std.math.clamp((frame.ptr_x - track.x) / track.width, 0, 1);
        self.state = self.state.withSlider(frac * 100).withLast("slider moved");
        self.persist_dirty = true;
    }

    pub fn selectTab(self: *CatalogViewModel, index: usize) void {
        self.state = self.state.withTab(index).withLast("tab selected");
        self.persist_dirty = true;
    }

    pub fn selectListRow(self: *CatalogViewModel, index: usize) void {
        self.state = self.state.withRow(index).withLast("row selected");
        self.persist_dirty = true;
    }

    pub fn selectTreeRow(self: *CatalogViewModel, index: usize) void {
        self.state = self.state.withTreeRow(index).withLast("tree row selected");
        self.persist_dirty = true;
    }

    // The dropdown's rows are the filter's answer, so the pick itself changes nothing but the report.
    pub fn selectOption(self: *CatalogViewModel, index: usize) void {
        _ = index;
        self.state = self.state.withLast("option selected");
    }

    // The button demos differ only in what they say, and a demo that says nothing would be a demo of nothing.
    // The modal demo: a button raises the card, an action answers it, and the answer is what the header reports.
    pub fn openModal(self: *CatalogViewModel) void {
        self.state = self.state.withModal(true);
    }

    pub fn answerModal(self: *CatalogViewModel, index: usize) void {
        self.state = self.state.withModal(false).withLast(switch (index) {
            0 => "modal: cancel",
            1 => "modal: discard",
            else => "modal: saved",
        });
    }

    // What the view hands the split and the sidebar: the props carry the model's state, so the drag writes home.
    pub fn splitProps(self: *CatalogViewModel, t: Theme) split_mod.Props {
        return .{
            .id = .{ .text = "catalog.split" },
            .state = &self.split_state,
            .axis = .horizontal,
            .side = .after,
            .min = 60,
            .thickness = 6,
            // The line reads as a divider before the pointer touches it, like every other rule in the kit.
            .bg = t.colors.divider,
            .hover_bg = t.colors.hover,
            .active_bg = t.colors.primary,
        };
    }

    pub fn sidebarProps(self: *CatalogViewModel, t: Theme) sidebar_mod.Props {
        return .{
            .id = .{ .text = "catalog.sidebar" },
            .state = &self.sidebar_state,
            .h = .{ .fixed = 190 },
            .min_width = 120,
            .max_width = 320,
            .bg = t.colors.surface,
            .handle_bg = t.colors.surface_variant,
            .handle_hover_bg = t.colors.hover,
            .handle_active_bg = t.colors.primary,
        };
    }

    // The theme switch: one boolean, and every widget that left a spacing prop unset follows it.
    pub fn toggleDense(self: *CatalogViewModel) void {
        self.dense = !self.dense;
        self.state = self.state.withLast(if (self.dense) "compact theme" else "roomy theme");
        self.persist_dirty = true;
    }

    pub fn pressPrimary(self: *CatalogViewModel) void {
        self.state = self.state.withLast("primary button");
    }

    pub fn pressSecondary(self: *CatalogViewModel) void {
        self.state = self.state.withLast("secondary button");
    }

    pub fn pressQuiet(self: *CatalogViewModel) void {
        self.state = self.state.withLast("quiet button");
    }

    pub fn pressDanger(self: *CatalogViewModel) void {
        self.state = self.state.withLast("danger button");
    }

    pub fn pressSmall(self: *CatalogViewModel) void {
        self.state = self.state.withLast("small button");
    }

    pub fn pressMedium(self: *CatalogViewModel) void {
        self.state = self.state.withLast("medium button");
    }

    pub fn pressLarge(self: *CatalogViewModel) void {
        self.state = self.state.withLast("large button");
    }
};
