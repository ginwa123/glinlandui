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

    // The theme the screen is drawn with: the same palette and type, and the kit's denser metrics when the switch says so.
    pub fn currentTheme(self: *App) glinlandui.theme.Theme {
        if (!self.vm().dense) return self.theme;
        var dense = self.theme;
        dense.metrics = glinlandui.theme.compact.metrics;
        return dense;
    }

    // `setContent { MaterialTheme { CatalogScreen() } }`: a click dispatches before the repaint, so its intent is drawn.
    pub fn content(ctx: ?*anyopaque, w: u32, h: u32) void {
        _ = w;
        _ = h;
        const self: *App = @ptrCast(@alignCast(ctx.?));
        const model = self.vm();
        const theme_now = self.currentTheme();
        // One line, and every widget under it that left a spacing prop to the theme follows: the parent owns the theme.
        glinlandui.theme.setCurrent(theme_now);
        // The toolkit forgets focus when a host starts, so the screen claims the keyboard on the frame that draws it.
        model.claimFocus();
        var scope = view.Scope{
            .theme = theme_now,
            .vm = model,
            .state = model.uiState(),
        };
        // A screenshot helper: `CATALOG_SCROLLY=2400` opens the page at that offset, so a section can be looked at.
        if (std.c.getenv("CATALOG_SCROLLY")) |raw| {
            const y = std.fmt.parseFloat(f32, std.mem.span(raw)) catch 0;
            glinlandui.components.scroll.scrollBy("catalog.scroll", 0, y);
        }
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
        "catalog.buttons.section", "catalog.field.section",   "catalog.selection.section", "catalog.roles.section",
        "catalog.type.section",    "catalog.spacing.section", "catalog.badges.section",    "catalog.tabs.section",
        "catalog.list.section",    "catalog.tree.section",    "catalog.dropdown.section",  "catalog.scroll.section",
        "catalog.split.section",   "catalog.sidebar.section", "catalog.modal.section",     "catalog.images.section",
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

test "the theme switch retunes every widget from the parent, and nothing in the view changes" {
    var app = App{};
    var driver = try boot(&app);
    defer driver.deinit();

    // A button that left its padding to the theme: roomy metrics, then compact ones.
    const roomy = driver.box("catalog.btn.primary").?;
    try driver.click("catalog.dense");
    try testing.expect(app.vm().dense);
    try testing.expectEqualStrings("compact theme", app.vm().uiState().lastText());
    const dense = driver.box("catalog.btn.primary").?;
    // Same label, a narrower button: the padding came from the theme, not from the call site.
    try testing.expect(dense.width < roomy.width);
    // Exactly the two sides' difference: `control_pad` is 12 roomy and 8 compact, and the label did not change.
    try testing.expectApproxEqAbs(@as(f32, 2 * (12 - 8)), roomy.width - dense.width, 0.51);

    // Back to roomy, and the width is where it started.
    try driver.click("catalog.dense");
    try testing.expect(!app.vm().dense);
    const again = driver.box("catalog.btn.primary").?;
    try testing.expectEqual(roomy.width, again.width);
}

test "the page scrolls under the wheel, including over a cell that clips its own label" {
    var app = App{};
    var driver = try boot(&app);
    defer driver.deinit();

    const scroll = glinlandui.components.scroll;
    // Over the colour-role swatches: every one of them is a clipping cell, which must not swallow the wheel.
    const swatch = driver.box("catalog.roles.row").?;
    driver.move(swatch.x + swatch.width * 0.5, swatch.y + swatch.height * 0.5);
    try testing.expectEqual(@as(f32, 0), scroll.view("catalog.scroll").y);
    driver.scroll(0, 120);
    try testing.expect(scroll.view("catalog.scroll").y != 0);
}

test "a section's own scroll box fits inside the card that holds it" {
    var app = App{};
    var driver = try boot(&app);
    defer driver.deinit();

    // The page is scrolled until the Scroll section is mid-window, which is the state the window shows.
    glinlandui.components.scroll.scrollBy("catalog.scroll", 0, 560);
    driver.frame();
    const box = glinlandui.components.scroll.view("catalog.demo.scroll");
    const card = driver.box("catalog.scroll.section").?;
    try testing.expect(box.content_height > box.height);
    // The card is as tall as its contents: the box it holds may not reach past the card's own edge.
    try testing.expect(box.y + box.height <= card.y + card.height);
    try testing.expectApproxEqAbs(@as(f32, 130), box.height, 0.51);
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
