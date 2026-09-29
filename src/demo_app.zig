//! The demo application tree, shared by BOTH entry points.
//!
//! ## Why it is shared rather than duplicated
//!
//! `src/main.zig` is the native demo and `src/web_main.zig` is the browser one.
//! Both are meant to prove the same thing — that Clay layout, the widget set, the
//! rasterizer and the present path produce a real frame on their host — and the
//! only way that claim is worth anything is if they drive the *same* tree. Two
//! copies would drift, and the drift would be invisible until someone compared
//! screenshots.
//!
//! ## Why it lives in `src/`
//!
//! Zig rejects an `@import` that escapes the importing module's root DIRECTORY
//! (src/README.md, "Traps" §1). `src/main.zig` is the root of the native
//! executable's module, so its root directory is `src/` and it cannot reach
//! `examples/`. This file therefore sits beside both roots.
//!
//! ## Why it imports `glinlandui` BY MODULE NAME
//!
//! `@import("glinlandui")` — never `@import("root.zig")`. A relative import of the
//! library root would compile the whole library a second time *inside the
//! executable's module*, and then `glinlandui.zclay` would no longer be the same
//! module identity as the library's own `zclay` (invariant I5). The failure mode
//! is a baffling type mismatch rather than a missing import, so the name is used
//! deliberately.
//!
//! ## The counters are the point
//!
//! `clicks`, `toggled` and `slider_frac` are mutated by the widgets and rendered
//! back into the tree, so the pixels visibly reflect interaction. A demo whose
//! callbacks fired but whose state never reached the screen would look identical
//! to one whose callbacks never fired; these make the difference observable.
const std = @import("std");
const glinlandui = @import("glinlandui");

const components = glinlandui.components;
const Color = glinlandui.Color;

pub const App = struct {
    clicks: u32 = 0,
    toggled: bool = false,
    slider_frac: f32 = 0.4,
    status_buf: [96]u8 = undefined,
    /// What the last file dialog returned, or why it did not. The file dialog
    /// is the one feature here whose result is not a number the user can see
    /// from the widgets, so it gets its own line rather than a corner of the
    /// shared status.
    ///
    /// ZEROED, not `undefined`, because it is read on the very first frame —
    /// before any dialog has run — and a label drawn from uninitialised memory
    /// is not an empty string, it is whatever was on the stack. Pango says so
    /// loudly ("Invalid UTF-8 string passed to pango_layout_set_text"), which
    /// is how this was found.
    pick_buf: [192]u8 = [_]u8{0} ** 192,

    /// The webapp's embedded font, read by `web/exports.zig` from `glin_web_init`.
    ///
    /// It lives on the APP TYPE rather than in the entry-point file because the
    /// export surface is generic over the app: `Exports(App, App.root)` can only
    /// see declarations that belong to `App`. A declaration in `main.zig` would
    /// be invisible to it, and the font would silently never install — which is
    /// exactly what happened, and why the browser showed bars.
    ///
    /// Empty on native, where the backends resolve a font from the filesystem.
    pub const embedded_font: []const u8 = if (@import("builtin").cpu.arch.isWasm())
        @import("font_data").bytes
    else
        &.{};

    /// The Clay declare callback: everything drawing happens here.
    pub fn root(ctx: ?*anyopaque, _: u32, _: u32) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        self.declare();
    }

    fn declare(self: *App) void {
        const Self = @This();
        components.box.box(.{
            .id = "root",
            .direction = .column,
            .w = .grow,
            .h = .grow,
            .bg = Color.rgb(0x1e, 0x1e, 0x1e),
            .pad = 16,
            .gap = 12,
        }, self, Self.children);
    }

    fn children(self: *App) void {
        components.text.label(.{
            .str = "glinlandui",
            .font_size = 24,
            .color = Color.rgb(0xf0, 0xf0, 0xf0),
        });
        components.text.label(.{
            .str = "real pixels, identical tests on Linux, macOS and the web",
            .font_size = 14,
            .color = Color.rgb(0x9a, 0x9a, 0x9a),
        });
        components.button.button(.{
            .id = "click-me",
            .label = "Click me",
            .w = 180,
            .h = 40,
            .on_click = onClick,
            .ctx = self,
        });
        components.toggle.toggle(.{
            .id = "toggle",
            .on = self.toggled,
            .on_click = onToggle,
            .ctx = self,
        });
        components.slider.slider(.{
            .id = "slider",
            .w = 220,
            .h = 24,
            .value = self.slider_frac,
            .on_change = onSlider,
            .ctx = self,
        });
        components.text.label(.{
            .str = self.statusText(),
            .font_size = 13,
            .color = Color.rgb(0x7a, 0xb8, 0xff),
        });

        // The file dialog, on the platforms that have one. Gated on
        // `available()` rather than drawn and disabled: a button that cannot
        // do anything is worse than no button, and `available()` is a
        // compile-time constant per platform, so the whole block disappears on
        // a host with no dialog backend instead of failing at runtime.
        if (glinlandui.file_dialog.available()) {
            components.text.label(.{
                .str = "XDG portal file dialog",
                .font_size = 14,
                .color = Color.rgb(0xf0, 0xf0, 0xf0),
            });
            components.button.button(.{
                .id = "open-file",
                .label = "Open a file...",
                .w = 220,
                .h = 40,
                .on_click = onOpenFile,
                .ctx = self,
            });
            components.button.button(.{
                .id = "open-folder",
                .label = "Choose a folder...",
                .w = 220,
                .h = 40,
                .on_click = onOpenFolder,
                .ctx = self,
            });
            components.text.label(.{
                .str = self.pickText(),
                .font_size = 13,
                .color = Color.rgb(0x9a, 0x9a, 0x9a),
            });
        }
    }

    pub fn statusText(self: *App) []const u8 {
        return std.fmt.bufPrint(&self.status_buf, "clicks={d} toggled={} slider={d}", .{
            self.clicks,
            self.toggled,
            @as(u32, @intFromFloat(self.slider_frac * 100)),
        }) catch "status";
    }

    fn onClick(ctx: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        self.clicks += 1;
    }

    fn onToggle(ctx: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        self.toggled = !self.toggled;
    }

    /// What the last dialog returned, for the line under the buttons.
    pub fn pickText(self: *App) []const u8 {
        const end = std.mem.indexOfScalar(u8, &self.pick_buf, 0) orelse self.pick_buf.len;
        return self.pick_buf[0..end];
    }

    /// Open a file, and report what came back.
    ///
    /// The three cases this separates are the whole point of the API: the
    /// user picked something, the user dismissed the window on purpose, and
    /// there is no portal here at all. An app that collapsed the last two into
    /// "it failed" would pop an error box every time somebody pressed Escape.
    fn onOpenFile(ctx: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        const alloc = glinlandui.platform.allocator;
        const selection = glinlandui.file_dialog.openFile(alloc, .{
            .title = "Open a file",
            .current_folder = self.homeDir(),
        }) catch |err| return self.reportPick(self.fmtPick("openFile failed: {s}", .{@errorName(err)}));

        defer selection.deinit(alloc);
        switch (selection.status) {
            .selected => self.reportPick(self.fmtPick("file: {s}", .{selection.first() orelse "?"})),
            .cancelled => self.reportPick("openFile: cancelled"),
            .other => self.reportPick("openFile: no selection"),
        }
    }

    fn onOpenFolder(ctx: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(ctx.?));
        const alloc = glinlandui.platform.allocator;
        const selection = glinlandui.file_dialog.openFolder(alloc, .{
            .title = "Choose a folder",
            .current_folder = self.homeDir(),
        }) catch |err| return self.reportPick(self.fmtPick("openFolder failed: {s}", .{@errorName(err)}));

        defer selection.deinit(alloc);
        switch (selection.status) {
            .selected => self.reportPick(self.fmtPick("folder: {s}", .{selection.first() orelse "?"})),
            .cancelled => self.reportPick("openFolder: cancelled"),
            .other => self.reportPick("openFolder: no selection"),
        }
    }

    /// Where the dialog opens. Null means "the portal's own idea of home",
    /// which is the right default: there is no portable way to ask for a home
    /// directory, and guessing one is how a file dialog opens in `/`.
    fn homeDir(self: *App) ?[]const u8 {
        _ = self;
        return null;
    }

    fn reportPick(self: *App, text: []const u8) void {
        const n = @min(text.len, self.pick_buf.len - 1);
        @memcpy(self.pick_buf[0..n], text[0..n]);
        self.pick_buf[n] = 0;
    }

    fn fmtPick(self: *App, comptime fmt: []const u8, args: anytype) []const u8 {
        _ = self;
        return std.fmt.bufPrint(&pick_scratch, fmt, args) catch "pick failed";
    }

    /// One buffer for the formatting above, because the text is copied into
    /// `pick_buf` immediately and two dialogs in a row would otherwise each
    /// need their own.
    var pick_scratch: [192]u8 = undefined;

    fn onSlider(ctx: ?*anyopaque) void {
        // The slider stores its fraction; advance it so the fill visibly moves
        // and the status line updates.
        const self: *App = @ptrCast(@alignCast(ctx.?));
        self.slider_frac = if (self.slider_frac >= 0.95) 0.05 else self.slider_frac + 0.1;
    }
};
