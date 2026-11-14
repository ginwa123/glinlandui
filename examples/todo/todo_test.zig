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
    var driver = try Driver.initOwned(std.heap.page_allocator, app, App.content);
    errdefer driver.deinit();
    // No key or text handler is registered: the engine types into the focused field on its own.
    try driver.start(.{ .width = 720, .height = 640 });
    return driver;
}

test "the empty state is drawn, not just modelled" {
    var app = App{};
    var driver = try boot(&app);
    defer driver.deinit();

    // The field owns the keyboard from the first frame, which is what makes typing reach the model.
    try std.testing.expect(app.field.editor.focused);
    try std.testing.expectEqualStrings("", app.vm().uiState().draft());
    try std.testing.expect(driver.hasText("No todos yet — type one and press Enter."));
    try std.testing.expect(driver.hasText("0 of 0 done"));
}

test "typing and pressing Enter adds a row to the model and to the frame" {
    var app = App{};
    var driver = try boot(&app);
    defer driver.deinit();

    try driver.typeText("buy milk");
    // The value prop round-trips: the field reports the edit, the model holds it, the frame draws it back.
    try std.testing.expectEqualStrings("buy milk", app.field.text());
    try std.testing.expectEqualStrings("buy milk", app.vm().uiState().draft());

    _ = try driver.key(key_enter);

    const state = app.vm().uiState();
    try std.testing.expectEqual(@as(usize, 1), state.count);
    try std.testing.expectEqualStrings("buy milk", state.items()[0].text());
    // The intent took the draft, so the field and the model are both empty again.
    try std.testing.expectEqualStrings("", app.field.text());
    try std.testing.expectEqualStrings("", app.vm().uiState().draft());

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
    try std.testing.expectEqualStrings("   ", app.field.text());
    try std.testing.expectEqualStrings("   ", app.vm().uiState().draft());
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
