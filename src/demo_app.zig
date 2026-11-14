//! The demo application tree, shared by BOTH entry points.
const std = @import("std");
const glinlandui = @import("glinlandui");

const components = glinlandui.components;
const Color = glinlandui.Color;
const props = glinlandui.props;

pub const App = struct {
    clicks: u32 = 0,
    toggled: bool = false,
    slider_frac: f32 = 0.4,
    status_buf: [96]u8 = undefined,
    /// What the last file dialog returned, or why it did not.
    pick_buf: [192]u8 = [_]u8{0} ** 192,

    /// The webapp's embedded font, read by `web/exports.zig` from `glin_web_init`.
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
            .id = .{ .text = "root" },
            .direction = .column,
            .w = .grow,
            .h = .grow,
            .bg = Color.rgb(0x1e, 0x1e, 0x1e),
            .pad = props.Pad.all(16),
            .gap = 12,
        }, self, Self.children);
    }

    fn children(self: *App) void {
        components.text.label(.{
            .label = .{ .text = "glinlandui", .size = 24, .color = Color.rgb(0xf0, 0xf0, 0xf0) },
        });
        components.text.label(.{
            .label = .{ .text = "real pixels, identical tests on Linux, macOS and the web", .size = 14, .color = Color.rgb(0x9a, 0x9a, 0x9a) },
        });
        components.button.button(.{
            .id = .{ .text = "click-me" },
            .label = .{ .text = "Click me" },
            .w = .{ .fixed = 180 },
            .h = .{ .fixed = 40 },
            .on_click = onClick,
            .ctx = self,
        });
        components.toggle.toggle(.{
            .id = .{ .text = "toggle" },
            .on = self.toggled,
            .on_click = onToggle,
            .ctx = self,
        });
        components.slider.slider(.{
            .id = .{ .text = "slider" },
            .w = 220,
            .h = 24,
            .value = self.slider_frac,
            .on_change = onSlider,
            .ctx = self,
        });
        components.text.label(.{
            .label = .{ .text = self.statusText(), .size = 13, .color = Color.rgb(0x7a, 0xb8, 0xff) },
        });

        // The file dialog, on the platforms that have one.
        if (glinlandui.file_dialog.available()) {
            components.text.label(.{
                .label = .{ .text = "XDG portal file dialog", .size = 14, .color = Color.rgb(0xf0, 0xf0, 0xf0) },
            });
            components.button.button(.{
                .id = .{ .text = "open-file" },
                .label = .{ .text = "Open a file..." },
                .w = .{ .fixed = 220 },
                .h = .{ .fixed = 40 },
                .on_click = onOpenFile,
                .ctx = self,
            });
            components.button.button(.{
                .id = .{ .text = "open-folder" },
                .label = .{ .text = "Choose a folder..." },
                .w = .{ .fixed = 220 },
                .h = .{ .fixed = 40 },
                .on_click = onOpenFolder,
                .ctx = self,
            });
            components.text.label(.{
                .label = .{ .text = self.pickText(), .size = 13, .color = Color.rgb(0x9a, 0x9a, 0x9a) },
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

    /// Where the dialog opens.
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

    /// One buffer for the formatting above, because the text is copied into `pick_buf` immediately and two dialogs in a row would otherwise each need their.
    var pick_scratch: [192]u8 = undefined;

    fn onSlider(ctx: ?*anyopaque) void {
        // The slider stores its fraction; advance it so the fill visibly moves and the status line updates.
        const self: *App = @ptrCast(@alignCast(ctx.?));
        self.slider_frac = if (self.slider_frac >= 0.95) 0.05 else self.slider_frac + 0.1;
    }
};
