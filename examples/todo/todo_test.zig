// End-to-end: the REAL App, driven headlessly, asserted on the frame it produced.
// Asserting only on `vm.uiState()` would pass with a blank window, so every test also checks the frame.
const std = @import("std");
const glinlandui = @import("glinlandui");
const todo = @import("todo");

const App = todo.app.App;
const Driver = glinlandui.testing.Driver;

// evdev Enter, the code `text_editor.KEY_ENTER` names.
const key_enter: u32 = 28;

// Boot the app the way `main.zig` does, but with the frame driven by the test instead of a window.
// page_allocator, not testing.allocator: the Clay arena is intentionally leaked for the process's life.
fn boot(app: *App) !Driver {
    app.start();
    var driver = try Driver.initOwned(std.heap.page_allocator, app, glinlandui.composition.Composition.setContent(App.content));
    errdefer driver.deinit();
    // The driver owns a Host of its own, so the event routing `main.zig` installs has to be installed here too.
    driver.host.keys.register(App.onKey, app);
    driver.host.keys.registerText(App.onText, app);
    try driver.start(.{ .width = 720, .height = 640 });
    return driver;
}

test "the empty state is drawn, not just modelled" {
    var app = App{};
    var driver = try boot(&app);
    defer driver.deinit();

    // The field owns the keyboard from the first frame, which is what makes typing reach the model.
    try std.testing.expect(app.field.editor.focused);
    try std.testing.expect(driver.hasText("No todos yet — type one and press Enter."));
    try std.testing.expect(driver.hasText("0 of 0 done"));
}

test "typing and pressing Enter adds a row to the model and to the frame" {
    var app = App{};
    var driver = try boot(&app);
    defer driver.deinit();

    try driver.typeText("buy milk");
    try std.testing.expectEqualStrings("buy milk", app.field.editor.text());

    _ = try driver.key(key_enter);

    const state = app.vm().uiState();
    try std.testing.expectEqual(@as(usize, 1), state.count);
    try std.testing.expectEqualStrings("buy milk", state.items()[0].text());
    // The intent took the draft, so the field is empty again.
    try std.testing.expectEqualStrings("", app.field.editor.text());

    try std.testing.expect(driver.hasText("buy milk"));
    try std.testing.expect(driver.hasText("0 of 1 done"));
}

test "a blank Enter adds nothing, and leaves the draft alone" {
    var app = App{};
    var driver = try boot(&app);
    defer driver.deinit();

    try driver.typeText("   ");
    _ = try driver.key(key_enter);

    try std.testing.expectEqual(@as(usize, 0), app.vm().uiState().count);
    try std.testing.expectEqualStrings("   ", app.field.editor.text());
}

test "clicking the checkbox toggles the row, and the footer counts it" {
    var app = App{};
    var driver = try boot(&app);
    defer driver.deinit();

    try driver.typeText("one");
    _ = try driver.key(key_enter);

    try driver.click("todo.row.check.0");
    try std.testing.expect(app.vm().uiState().items()[0].done);
    try std.testing.expect(driver.hasText("1 of 1 done"));
}

test "Delete removes its own row and does not toggle it" {
    var app = App{};
    var driver = try boot(&app);
    defer driver.deinit();

    try driver.typeText("one");
    _ = try driver.key(key_enter);
    try driver.typeText("two");
    _ = try driver.key(key_enter);

    try driver.click("todo.row.delete.1");

    const state = app.vm().uiState();
    try std.testing.expectEqual(@as(usize, 1), state.count);
    try std.testing.expectEqualStrings("one", state.items()[0].text());
    // The button won the hit test, so the row underneath it never saw the click.
    try std.testing.expect(!state.items()[0].done);
    try std.testing.expect(!driver.hasText("two"));
}
