// The entry point: `MainActivity`, the window, and the headless check mode CI runs — nothing else.
const std = @import("std");
const glinlandui = @import("glinlandui");
const file_dialog = @import("file_dialog");

const dialog = glinlandui.file_dialog;
const state_mod = file_dialog.state;

const WIN_W: u32 = 520;
const WIN_H: u32 = 300;

pub fn main(init: std.process.Init) !void {
    _ = init;

    // `--check` is an environment variable because `zig build run-file-dialog` forwards args to the binary, so a flag would have to survive that indirection too.
    if (std.c.getenv("GLIN_FILE_DIALOG_CHECK") != null) return check();

    const alloc = glinlandui.platform.allocator;

    var app = file_dialog.app.App{};
    app.start();

    var host = try glinlandui.host.Host.init(alloc, &app, file_dialog.app.App.content);
    defer host.deinit();

    var window = glinlandui.Window.init(alloc, .{
        .app_id = "glinlandui-file-dialog",
        .title = "glinlandui - file dialog",
        .width = WIN_W,
        .height = WIN_H,
        .min_width = WIN_W,
        .min_height = WIN_H,
    });
    window.delegate = host.delegate();

    window.run() catch |err| {
        std.debug.print("window unavailable ({s})\n", .{@errorName(err)});
    };
}

// What CI runs: this host's backend, and the requests the three buttons would build — with no window, no compositor and no user.
fn check() void {
    std.debug.print("backend:     {s}\n", .{backendName()});
    std.debug.print("available:   {}\n", .{dialog.available()});

    for (state_mod.ACTIONS) |a| {
        const options = state_mod.optionsFor(a.kind, null);
        std.debug.print(
            "{s: <12} {s} \"{s}\" filters={d} multiple={} timeout={s}\n",
            .{ a.id, portalMemberFor(a.kind), options.title, options.filters.len, options.multiple, timeoutNote() },
        );
    }

    if (canBoundADialog()) {
        std.debug.print("attempt:     {s}\n", .{probe()});
    } else {
        std.debug.print(
            "attempt:     not attempted — a dialog on this host cannot be bounded (timeout_ms is Linux-only)\n",
            .{},
        );
    }
}

// Whether a call to the backend is guaranteed to come back on its own: a portal answers over D-Bus, while AppKit and COM own a modal loop no host timer can end.
fn canBoundADialog() bool {
    return switch (@import("builtin").os.tag) {
        .linux => true,
        else => false,
    };
}

// The portal method a `Kind` maps to, spelled out here so the printout PROVES that three buttons ask three different questions.
fn portalMemberFor(kind: dialog.Kind) []const u8 {
    return switch (kind) {
        .open_file => "OpenFile",
        .open_folder => "OpenDirectory",
        .save_file => "SaveFile",
    };
}

// Whether this host honours `timeout_ms`, for the check's output.
fn timeoutNote() []const u8 {
    return if (canBoundADialog()) "honoured" else "ignored";
}

// Which backend this build resolved to, by name — the one OS branch an EXAMPLE may take, and a real app has no use for it.
fn backendName() []const u8 {
    return switch (@import("builtin").os.tag) {
        .linux => "xdg-desktop-portal (pure-Zig D-Bus)",
        .macos => "NSOpenPanel",
        .windows => "IFileDialog",
        else => "none (error.Unsupported)",
    };
}

// Call `openFile` and describe how it ended WITHOUT a dialog appearing — the bound is what makes this safe on a CI runner nobody can click.
fn probe() []const u8 {
    const selection = dialog.openFile(std.heap.page_allocator, .{
        .kind = .open_file,
        .title = "glinlandui check",
        .timeout_ms = 2_000,
    }) catch |err| {
        // Matched by NAME for the reason `Machine.fromError` gives: a desktop backend's error set is inferred, so naming a member this host lacks does not compile.
        return @errorName(err);
    };
    defer selection.deinit(std.heap.page_allocator);
    return switch (selection.status) {
        .selected => "selected (a real dialog opened — press Cancel next time)",
        .cancelled => "cancelled",
        .other => "other",
    };
}
