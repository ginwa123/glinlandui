// The ViewModel and the only writer: every public function here is an intent, and it knows nothing of a window.
const std = @import("std");
const glinlandui = @import("glinlandui");
const frame = glinlandui.frame;
const input_mod = glinlandui.components.input;
const state_mod = @import("state.zig");

const CatalogUiState = state_mod.CatalogUiState;
const Theme = glinlandui.theme.Theme;

// The ids the model itself needs: the field that takes the keyboard, and the slider track an intent measures.
pub const field_id = "catalog.field";
pub const dd_field_id = "catalog.dd.field";
pub const slider_id = "catalog.slider";

pub const CatalogViewModel = struct {
    // The state, as a plain value: an intent replaces it, and the next frame reads whatever it says.
    state: CatalogUiState = .{},

    // Compose keeps these in `remember`: a field owns a buffer, a caret and a draft, and every one of them outlives a frame.
    field: input_mod.Field = .{ .id = .{ .text = field_id } },
    dd_field: input_mod.Field = .{ .id = .{ .text = dd_field_id } },

    // A radio's click carries only a context, so each one gets a context the model owns.
    radio_ctxs: [state_mod.radio_count]RadioCtx = undefined,

    // The toolkit forgets focus when a host starts, so the screen claims the keyboard once, on its first frame.
    focus_claimed: bool = false,

    pub const RadioCtx = struct {
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
            .border = .{ .width = 1, .color = t.colors.divider },
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
    }

    pub fn pickRadio(self: *CatalogViewModel, index: usize) void {
        self.state = self.state.withRadio(index).withLast("radio picked");
    }

    pub fn toggleSwitch(self: *CatalogViewModel) void {
        const on = !self.state.toggled;
        self.state = self.state.withToggled(on).withLast(if (on) "toggle on" else "toggle off");
    }

    // The slider reports a click, not a value: the intent reads the pointer against the track the view declared.
    pub fn slide(self: *CatalogViewModel) void {
        const track = frame.bounds(frame.clayId(slider_id)) orelse return;
        if (track.width <= 0) return;
        const frac = std.math.clamp((frame.ptr_x - track.x) / track.width, 0, 1);
        self.state = self.state.withSlider(frac * 100).withLast("slider moved");
    }

    pub fn selectTab(self: *CatalogViewModel, index: usize) void {
        self.state = self.state.withTab(index).withLast("tab selected");
    }

    pub fn selectListRow(self: *CatalogViewModel, index: usize) void {
        self.state = self.state.withRow(index).withLast("row selected");
    }

    pub fn selectTreeRow(self: *CatalogViewModel, index: usize) void {
        self.state = self.state.withTreeRow(index).withLast("tree row selected");
    }

    // The dropdown's rows are the filter's answer, so the pick itself changes nothing but the report.
    pub fn selectOption(self: *CatalogViewModel, index: usize) void {
        _ = index;
        self.state = self.state.withLast("option selected");
    }

    // The button demos differ only in what they say, and a demo that says nothing would be a demo of nothing.
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
