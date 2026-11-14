// The Activity: the store, the theme and the composition — it hands the window a screen and nothing else.
const std = @import("std");
const glinlandui = @import("glinlandui");

const view = @import("view.zig");
const view_model = @import("view_model.zig");

pub const App = struct {
    // `ViewModelStoreOwner`: one screen, one store, one ViewModel for the life of the window.
    store: glinlandui.view_model.Store(view_model.CatalogViewModel) = .{},
    // `MaterialTheme`: the catalog is the kit's own palette, so the Activity picks the kit's ink-on-paper theme.
    theme: glinlandui.theme.Theme = glinlandui.theme.dragon,

    // `onCreate`: the model takes its fields and its click contexts.
    pub fn start(self: *App) void {
        self.vm().start(self.theme);
    }

    // `viewModel()`: the store's instance, created on first use and kept for the life of the screen.
    pub fn vm(self: *App) *view_model.CatalogViewModel {
        return self.store.getOrCreate(view_model.CatalogViewModel.init);
    }

    // `setContent { MaterialTheme { CatalogScreen() } }`: a click dispatches before the repaint, so its intent is drawn.
    pub fn content(ctx: ?*anyopaque, w: u32, h: u32) void {
        _ = w;
        _ = h;
        const self: *App = @ptrCast(@alignCast(ctx.?));
        const model = self.vm();
        // The toolkit forgets focus when a host starts, so the screen claims the keyboard on the frame that draws it.
        model.claimFocus();
        var scope = view.Scope{
            .theme = self.theme,
            .vm = model,
            .state = model.uiState(),
        };
        view.CatalogScreen(&scope);
    }
};

// ---- tests ---------------------------------------------------------------------------------------------------

const testing = std.testing;
const Driver = glinlandui.testing.Driver;

fn boot(app: *App) !Driver {
    app.start();
    var driver = try Driver.initOwned(std.heap.page_allocator, app, App.content);
    errdefer driver.deinit();
    try driver.start(.{ .width = 960, .height = 760 });
    // The first frame has no layout yet, so a scroll container's clip is 0x0 until it has painted once.
    driver.frame();
    return driver;
}

test "every section is declared and drawn" {
    var app = App{};
    var driver = try boot(&app);
    defer driver.deinit();

    for ([_][]const u8{
        "catalog.buttons.section", "catalog.field.section",    "catalog.selection.section", "catalog.roles.section",
        "catalog.type.section",    "catalog.badges.section",   "catalog.tabs.section",      "catalog.list.section",
        "catalog.tree.section",    "catalog.dropdown.section",
    }) |id| {
        try testing.expect(driver.exists(id));
    }
    try testing.expect(driver.hasText("glinlandui · catalog"));
    try testing.expect(driver.hasText("Colour roles"));
    try testing.expect(driver.hasText("one primary per view, everything else quiet"));
}

test "a click reaches the widget and the frame shows the result" {
    var app = App{};
    var driver = try boot(&app);
    defer driver.deinit();

    try testing.expect(app.vm().uiState().checked);
    try driver.click("catalog.check");
    try testing.expect(!app.vm().uiState().checked);
    try testing.expect(driver.hasText("last intent: unchecked"));
}

test "typing reaches the field with no key handler registered" {
    var app = App{};
    var driver = try boot(&app);
    defer driver.deinit();

    try driver.typeText("abc");
    try testing.expectEqualStrings("abc", app.vm().field.text());
    try testing.expect(driver.hasText("last intent: abc"));
}

test "the palette is the kit's, role by role" {
    var app = App{};
    var driver = try boot(&app);
    defer driver.deinit();

    // The swatch row names every role, so a missing one is a missing component.
    inline for (std.meta.fields(glinlandui.theme.Colors)) |f| {
        try testing.expect(driver.exists(f.name));
    }
}
