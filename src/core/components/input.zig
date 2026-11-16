// Agnostic reusable Clay text field (toolkit-style, library only).
const std = @import("std");
const cl = @import("zclay");
const headless = @import("../testing/headless.zig");
const soft = @import("../render_software.zig");
const prop = @import("../props.zig");
const Color = @import("../color.zig").Color;
const registry = @import("click_registry.zig");
const caret_mod = @import("caret.zig");
const scroll_mod = @import("scroll.zig");
const context_menu = @import("context_menu.zig");
const frame_mod = @import("../frame.zig");
const text_editor = @import("../text_editor.zig");
const text_backend = @import("../text_backend.zig");
const semantics = @import("../semantics.zig");
const audit = @import("../audit.zig");

// Raw evdev keycode → printable ASCII under the US layout.
pub fn keyChar(evdev: u32, shift: bool) ?u8 {
    // Letters: Q..P, A..L, Z..M rows.
    const lower = "qwertyuiopasdfghjklzxcvbnm";
    const codes = [_]u32{ 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 30, 31, 32, 33, 34, 35, 36, 37, 38, 44, 45, 46, 47, 48, 49, 50 };
    for (codes, 0..) |code, i| {
        if (evdev == code) {
            const c = lower[i];
            return if (shift) std.ascii.toUpper(c) else c;
        }
    }
    // Digits row (shifted: symbols).
    const digits = "1234567890";
    const shifted = "!@#$%^&*()";
    const dcodes = [_]u32{ 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
    for (dcodes, 0..) |code, i| {
        if (evdev == code) return if (shift) shifted[i] else digits[i];
    }
    // Punctuation (unshifted, shifted).
    const punct = [_]struct { code: u32, plain: u8, shifted: u8 }{
        .{ .code = 12, .plain = '-', .shifted = '_' },
        .{ .code = 13, .plain = '=', .shifted = '+' },
        .{ .code = 26, .plain = '[', .shifted = '{' },
        .{ .code = 27, .plain = ']', .shifted = '}' },
        .{ .code = 39, .plain = ';', .shifted = ':' },
        .{ .code = 40, .plain = '\'', .shifted = '"' },
        .{ .code = 41, .plain = '`', .shifted = '~' },
        .{ .code = 43, .plain = '\\', .shifted = '|' },
        .{ .code = 51, .plain = ',', .shifted = '<' },
        .{ .code = 52, .plain = '.', .shifted = '>' },
        .{ .code = 53, .plain = '/', .shifted = '?' },
        .{ .code = 57, .plain = ' ', .shifted = ' ' },
    };
    for (punct) |p| {
        if (evdev == p.code) return if (shift) p.shifted else p.plain;
    }
    return null;
}

// Append a char to a caller-owned draft buffer.
pub fn insert(buf: []u8, len: *usize, c: u8) bool {
    if (len.* >= buf.len) return false;
    buf[len.*] = c;
    len.* += 1;
    return true;
}

// Drop the last byte (keymap is ASCII-only, so byte == char).
pub fn backspace(len: *usize) void {
    if (len.* > 0) len.* -= 1;
}

// ---- HTML-like caret + keyboard selection (single-line, ASCII) ---- The field used to be append-only (caret pinned at end).

// Raw evdev codes for navigation (observed live: no +8 offset).
pub const KEY_LEFT: u32 = 105;
pub const KEY_RIGHT: u32 = 106;
pub const KEY_UP: u32 = 103;
pub const KEY_DOWN: u32 = 108;
pub const KEY_HOME: u32 = 102;
pub const KEY_END: u32 = 107;
pub const KEY_DELETE: u32 = 111;
pub const KEY_BACKSPACE: u32 = 14;

// Caret + keyboard-selection state (owner-held, one per draft buffer).
pub const EditState = struct {
    caret: usize = 0,
    anchor: ?usize = null,
};

// Normalized selection span (start < end), or null when caret-only.
pub const Span = struct {
    start: usize,
    end: usize,
};

pub fn selection(st: EditState) ?Span {
    const a = st.anchor orelse return null;
    if (a == st.caret) return null;
    return .{ .start = @min(a, st.caret), .end = @max(a, st.caret) };
}

pub fn hasSelection(st: EditState) bool {
    return selection(st) != null;
}

// Clamp caret/anchor into 0..len (call after external len edits).
pub fn clampEdit(st: *EditState, len: usize) void {
    st.caret = @min(st.caret, len);
    if (st.anchor) |a| st.anchor = @min(a, len);
}

fn moveCaret(st: *EditState, len: usize, new_caret: usize, shift: bool) void {
    const c = @min(new_caret, len);
    if (shift) {
        if (st.anchor == null) st.anchor = st.caret;
        st.caret = c;
        // Shift+move back onto the anchor clears (HTML behavior).
        if (st.anchor == st.caret) st.anchor = null;
    } else {
        st.caret = c;
        st.anchor = null;
    }
}

// Arrow left: with an active selection and no Shift, collapses to the selection start (HTML); otherwise steps one byte left.
pub fn moveLeft(st: *EditState, len: usize, shift: bool) void {
    if (!shift) {
        if (selection(st.*)) |sp| {
            st.caret = sp.start;
            st.anchor = null;
            return;
        }
    }
    clampEdit(st, len);
    moveCaret(st, len, if (st.caret > 0) st.caret - 1 else 0, shift);
}

// Arrow right: mirror of moveLeft (collapses to selection end).
pub fn moveRight(st: *EditState, len: usize, shift: bool) void {
    if (!shift) {
        if (selection(st.*)) |sp| {
            st.caret = sp.end;
            st.anchor = null;
            return;
        }
    }
    clampEdit(st, len);
    moveCaret(st, len, st.caret + 1, shift);
}

pub fn moveHome(st: *EditState, shift: bool) void {
    moveCaret(st, st.caret, 0, shift);
}

pub fn moveEnd(st: *EditState, len: usize, shift: bool) void {
    moveCaret(st, len, len, shift);
}

// Ctrl+A: select the whole buffer (empty buffer selects nothing).
pub fn selectAll(st: *EditState, len: usize) void {
    clampEdit(st, len);
    st.caret = len;
    st.anchor = if (len > 0) 0 else null;
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

// Ctrl+Left target: skip non-word bytes leftward, then word bytes.
pub fn wordLeftEnd(buf: []const u8, len: usize, caret: usize) usize {
    var c = @min(caret, len);
    while (c > 0 and !isWordChar(buf[c - 1])) : (c -= 1) {}
    while (c > 0 and isWordChar(buf[c - 1])) : (c -= 1) {}
    return c;
}

// Ctrl+Right target: skip word bytes rightward, then non-word bytes (lands at the end of the current/next word, like browsers).
pub fn wordRightEnd(buf: []const u8, len: usize, caret: usize) usize {
    var c = @min(caret, len);
    while (c < len and isWordChar(buf[c])) : (c += 1) {}
    while (c < len and !isWordChar(buf[c])) : (c += 1) {}
    return c;
}

pub fn moveWordLeft(st: *EditState, buf: []const u8, len: usize, shift: bool) void {
    clampEdit(st, len);
    moveCaret(st, len, wordLeftEnd(buf, len, st.caret), shift);
}

pub fn moveWordRight(st: *EditState, buf: []const u8, len: usize, shift: bool) void {
    clampEdit(st, len);
    moveCaret(st, len, wordRightEnd(buf, len, st.caret), shift);
}

// Delete span [start,end), shifting the tail left. Returns the new len.
fn deleteSpan(buf: []u8, len: usize, start: usize, end: usize) usize {
    std.debug.assert(start <= end and end <= len);
    std.mem.copyForwards(u8, buf[start .. len - (end - start)], buf[end..len]);
    return len - (end - start);
}

// Type a char: replaces the selection when present, else inserts at the caret.
pub fn insertAt(buf: []u8, len: *usize, st: *EditState, c: u8) bool {
    if (selection(st.*)) |sp| {
        len.* = deleteSpan(buf, len.*, sp.start, sp.end);
        st.caret = sp.start;
        st.anchor = null;
    }
    clampEdit(st, len.*);
    if (len.* >= buf.len) return false;
    std.mem.copyBackwards(u8, buf[st.caret + 1 .. len.* + 1], buf[st.caret..len.*]);
    buf[st.caret] = c;
    len.* += 1;
    st.caret += 1;
    return true;
}

// Backspace: deletes the selection when present, else the byte before the caret (no-op at 0).
pub fn backspaceAt(buf: []u8, len: *usize, st: *EditState) void {
    if (selection(st.*)) |sp| {
        len.* = deleteSpan(buf, len.*, sp.start, sp.end);
        st.caret = sp.start;
        st.anchor = null;
        return;
    }
    clampEdit(st, len.*);
    if (st.caret == 0) return;
    // A whole codepoint, so Backspace over `\xc3\xa9` cannot leave half a character behind.
    const start = text_editor.prevCodepoint(buf[0..len.*], st.caret);
    len.* = deleteSpan(buf, len.*, start, st.caret);
    st.caret = start;
}

// Forward Delete: deletes the selection when present, else the byte at the caret (no-op at end).
pub fn deleteAt(buf: []u8, len: *usize, st: *EditState) void {
    if (selection(st.*)) |sp| {
        len.* = deleteSpan(buf, len.*, sp.start, sp.end);
        st.caret = sp.start;
        st.anchor = null;
        return;
    }
    clampEdit(st, len.*);
    if (st.caret >= len.*) return;
    const n = text_editor.codepointLen(buf[0..len.*], st.caret);
    len.* = deleteSpan(buf, len.*, st.caret, st.caret + n);
}

// Arrow/Home/End dispatch for a single-line field (Up/Down ignored).
pub fn handleNavKey(st: *EditState, buf: []const u8, len: usize, evdev: u32, shift: bool, ctrl: bool) bool {
    switch (evdev) {
        KEY_LEFT => {
            if (ctrl) moveWordLeft(st, buf, len, shift) else moveLeft(st, len, shift);
            return true;
        },
        KEY_RIGHT => {
            if (ctrl) moveWordRight(st, buf, len, shift) else moveRight(st, len, shift);
            return true;
        },
        KEY_HOME => {
            moveHome(st, shift);
            return true;
        },
        KEY_END => {
            moveEnd(st, len, shift);
            return true;
        },
        else => return false,
    }
}

// ---- Key-event state machine (component owns interpretation) ---- Why this lives here instead of views.zig: the Wayland loop delivers raw evdev to.

// Modifier latch: one per window (a single keyboard).
pub const Mods = struct {
    shift: bool = false,
    ctrl: bool = false,
    // Cmd on macOS, the Super/Windows key elsewhere. Its own flag, so an app can tell Cmd from Ctrl.
    super: bool = false,

    pub fn track(m: *Mods, evdev: u32, pressed: bool) bool {
        switch (evdev) {
            42, 54 => {
                m.shift = pressed;
                return true;
            },
            29, 97 => {
                m.ctrl = pressed;
                return true;
            },
            // KEY_LEFTMETA / KEY_RIGHTMETA: macOS maps Cmd here, so Cmd+C is no longer a plain `c`.
            125, 126 => {
                m.super = pressed;
                return true;
            },
            else => return false,
        }
    }

    // True while either shortcut modifier is held: Cmd on macOS, Ctrl everywhere else.
    pub fn shortcut(m: Mods) bool {
        return m.ctrl or m.super;
    }
};

// What a key event means for the draft.
pub const Action = enum { ignored, edited, confirm };

pub const KEY_ENTER: u32 = 28;
pub const KEY_A: u32 = 30;

// Full key handling for one draft buffer: arrows/Home/End (via handleNavKey), Backspace/Delete-at-caret, Ctrl+A select-all, Enter, printables.
pub fn handleKey(buf: []u8, len: *usize, st: *EditState, mods: Mods, evdev: u32, pressed: bool) Action {
    if (!pressed) return .ignored;
    if (handleNavKey(st, buf, len.*, evdev, mods.shift, mods.ctrl)) return .edited;
    switch (evdev) {
        KEY_BACKSPACE => {
            backspaceAt(buf, len, st);
            return .edited;
        },
        KEY_DELETE => {
            deleteAt(buf, len, st);
            return .edited;
        },
        KEY_ENTER => return .confirm,
        else => {},
    }
    // Ctrl held: only Ctrl+A selects here, and every other combo inserts nothing. Copy/cut/paste live in `dispatchKey`, which owns the field's clipboard.
    if (mods.ctrl) {
        if (keyChar(evdev, false)) |c| {
            if (c == 'a') {
                selectAll(st, len.*);
                return .edited;
            }
        }
        return .ignored;
    }
    if (keyChar(evdev, mods.shift)) |c| {
        return if (insertAt(buf, len, st, c)) .edited else .ignored;
    }
    return .ignored;
}

// Insert a run the platform already composed -- Caps Lock `A`, `*`, `(`, `\xc3\xa9` -- at the caret, replacing any selection.
pub fn handleText(buf: []u8, len: *usize, st: *EditState, text: []const u8) Action {
    if (text.len == 0) return .ignored;
    var inserted = false;
    for (text) |c| {
        if (insertAt(buf, len, st, c)) inserted = true;
    }
    return if (inserted) .edited else .ignored;
}

// One text field: what it looks like, the intents it raises, and the state it owns.
pub const Field = struct {
    // ---- what it looks like ----

    // Where the app declared this widget: `@src()` at the call site, which the devtool then shows as the declaration.
    src: ?std.builtin.SourceLocation = null,
    id: prop.Id = .{ .text = "" },
    // The text the field shows. It wins whenever it CHANGES, so an app can drive the field from its state.
    value: []const u8 = "",
    font_size: prop.Len = .{ .px = 14 },
    fg: Color = Color.rgb(0xe8, 0xe8, 0xe8),
    bg: Color = Color.rgb(0x26, 0x26, 0x26),
    // A selected run carries a colour only: this renderer has no per-run background at glyph fidelity.
    sel_fg: Color = Color.rgb(0x7a, 0xb8, 0xff),
    // The selection's background, drawn behind the selected run.
    sel_bg: Color = Color.rgb(0x2d, 0x3a, 0x52),
    // The caret's colour, or a neutral one when null: a caret that matches the text merges with the glyph it touches.
    caret_fg: ?Color = null,
    // Multiline: Enter types a new line and the caret moves onto it; Ctrl/Cmd+Enter is the submit gesture instead.
    multiline: bool = false,
    // Read only: the field still takes the caret, a selection and copy, but no key ever edits the text.
    readonly: bool = false,
    // The line starts the app already computed, plus the end offset, so a megabyte body never scans for a line.
    lines: ?[]const usize = null,
    // The scroll container this field lives in: set it and a multiline field keeps the caret's line inside it.
    scroll_id: ?[]const u8 = null,
    // A field grows to the width it is given and fits its text vertically, unless the caller says otherwise.
    w: prop.Size = .grow,
    h: prop.Size = .{ .fixed = 32 },
    pad: prop.Pad = prop.Pad.axes(0, 10),
    radius: prop.Radius = prop.Radius.all(6),
    border: prop.Border = .{},
    disabled: bool = false,
    disabled_bg: Color = Color.rgb(0x1a, 0x1a, 0x1a),
    disabled_fg: Color = Color.rgb(0x77, 0x77, 0x77),
    // A hint drawn in the empty field while it does not own the keyboard, e.g. "Filter requests".
    placeholder: []const u8 = "",
    placeholder_fg: Color = Color.rgb(0x77, 0x77, 0x77),
    // ---- the intents it raises, each with the model it belongs to.
    on_change: prop.Change = .{},
    // Called on Enter with the draft. True means the intent took it, and then the field clears itself.
    on_submit: prop.Submit = .{},
    // Called after a click places the caret, so the app can take focus.
    on_focus: prop.Click = .{},
    // Dispatch priority for the field's own hit target: an overlay that swallows clicks passes a z above its own, so the field still answers.
    click_z: i16 = 0,
    // Measures a run with the font that draws the field. The engine's text backend is that font.
    measure: *const fn ([]const u8, u16) f32 = text_backend.runWidth,
    // Copy, cut and paste: the system clipboard unless a caller (or a test) hands in its own.
    clipboard: Clipboard = .{},
    // The rows this field ADDS after its own four, and the card's look; `on_select` is called with the app's own index.
    menu: prop.ContextMenu = .{},
    // The field's two mandatory rows followed by the app's, merged per frame: one list, so a row index is unambiguous.
    menu_items: [menu_cap][]const u8 = undefined,
    menu_disabled: [menu_cap]bool = undefined,

    // ---- the state it owns ----
    buf: [max_field_len]u8 = undefined,
    editor: text_editor.Editor = .{ .buf = &.{} },
    // The id as text, copied because a click uses it after the frame.
    name_buf: [96]u8 = undefined,
    name_len: usize = 0,
    // Left padding, written by `textField` each frame so a click and the caret share one origin.
    pad_lr: prop.Len = .{ .px = 8 },
    // True while this field owns a drag in flight; the field ticks it, so the app never has to.
    dragging: bool = false,
    // How far the text has slid left inside the field, so the caret stays in view: the clip applies it.
    h_scroll: f32 = 0,
    // The caret the scroll reveal last ran for: a caret that has NOT moved must not undo a wheel scroll every frame.
    revealed_caret: ?usize = null,
    // The clip's width in the previous frame: the room the caret has before the text has to slide.
    inner_w: f32 = 0,
    bound: bool = false,
    // The value the caller declared last frame: a change there is the model editing, and it wins over the draft.
    declared: [max_field_len]u8 = undefined,
    declared_len: usize = 0,
    declared_known: bool = false,

    // Point the editor at this field's own buffer, once, after the Field is where it will stay.
    pub fn bind(self: *Field) void {
        self.bindTo(&self.buf);
    }

    // Same, for an app that owns a bigger buffer than a single-line field needs.
    pub fn bindTo(self: *Field, buf: []u8) void {
        if (self.bound) return;
        self.editor = text_editor.Editor.init(buf);
        self.revealed_caret = null;
        self.bound = true;
    }

    // Point a READ-ONLY field at text the app owns: the same bytes, no copy, and no `bindTo` length limit.
    pub fn show(self: *Field, shown: []const u8) void {
        const bytes = @constCast(shown);
        // The same run at another address (a copy, an arena that moved) is the same document: repoint instead of resetting the caret.
        if (self.bound and self.editor.buf.len == bytes.len and self.editor.buf.ptr != bytes.ptr) {
            self.editor.buf = bytes;
            return;
        }
        // Re-init only when the model handed over a different run, so the caret and the selection survive a redraw.
        if (!self.bound or self.editor.buf.ptr != bytes.ptr or self.editor.buf.len != bytes.len) {
            self.editor = text_editor.Editor.init(bytes);
            self.revealed_caret = null;
            self.bound = true;
            // A different run starts at its own beginning, so the reason to be scrolled left is gone.
            self.h_scroll = 0;
        }
        self.editor.len = bytes.len;
        self.editor.caret.clamp(bytes.len);
    }

    // The draft, for an app that wants to read it.
    pub fn text(self: *const Field) []const u8 {
        return self.editor.text();
    }

    // The line the caret is on, which is what an enclosing scroll has to keep in view.
    pub fn caretLine(self: *const Field) usize {
        return lineIndexAt(self, @min(self.editor.caret.offset, self.editor.len));
    }

    // How tall one line of a multiline field is: the glyphs, plus the room the caret bar needs.
    pub fn lineHeight(self: *const Field) f32 {
        return self.font_size.pts() + 6;
    }

    // The byte offset a point lands on, with `x`/`y` already relative to the field's text origin: a click in a multiline field picks the line first.
    pub fn caretOffsetAtPoint(self: *const Field, x: f32, y: f32) usize {
        const ed = &self.editor;
        if (!self.multiline) return text_editor.offsetAtX(ed.text(), x, self.font_size.whole(), self.measure);
        const raw = @floor(@max(y, 0) / self.lineHeight());
        const total = lineTotal(self);
        const last = if (total > 0) total - 1 else 0;
        const line = @min(@as(usize, @intFromFloat(raw)), last);
        const start = @min(lineStartOf(self, line), ed.len);
        // An app's line index can be a frame behind its text, so a line never ends before it starts.
        const end = @min(@max(lineEndOf(self, line), start), ed.len);
        return start + text_editor.offsetAtX(ed.buf[start..end], x, self.font_size.whole(), self.measure);
    }

    // Adopt a value from the model: it does NOT report, because the model is where it came from.
    pub fn setText(self: *Field, value: []const u8) void {
        self.editor.setText(value);
        // The caret is back at the front of a new value, so the text has no reason to be slid left.
        self.h_scroll = 0;
        self.revealed_caret = null;
    }

    // Empty the draft without reporting it.
    pub fn clear(self: *Field) void {
        self.setText("");
    }

    // Raise the submit intent: Enter, or a button that does the same thing. True when the app took the draft.
    pub fn submit(self: *Field) bool {
        const f = self.on_submit.f orelse return false;
        if (!f(self.on_submit.ctx, self.editor.text())) return false;
        self.editor.setText("");
        self.report();
        return true;
    }

    // The focus and semantics name: the id as text, which is what a click and the keyboard use.
    pub fn name(self: *const Field) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    // Tell the caller the text changed.
    fn report(self: *Field) void {
        if (self.on_change.f) |f| f(self.on_change.ctx, self.editor.text());
    }

    // Copy the declared value, so a change next frame is detectable and a truncation is not a change every frame.
    fn rememberDeclared(self: *Field, value: []const u8) void {
        self.declared_len = @min(value.len, self.declared.len);
        @memcpy(self.declared[0..self.declared_len], value[0..self.declared_len]);
    }

    // True when `value` is the value this field already declared.
    fn declaredIs(self: *const Field, value: []const u8) bool {
        const n = @min(value.len, self.declared.len);
        if (n != self.declared_len) return false;
        return std.mem.eql(u8, value[0..n], self.declared[0..n]);
    }

    // Remember the id as text, so a click that runs after the frame still knows the field's name.
    fn rememberName(self: *Field) []const u8 {
        const declared = self.id.str();
        self.name_len = @min(declared.len, self.name_buf.len);
        @memcpy(self.name_buf[0..self.name_len], declared[0..self.name_len]);
        return self.name();
    }
};

// A field reports an edit: `(ctx, new_text)`.
pub const ChangeFn = ?*const fn (?*anyopaque, []const u8) void;

// A field asks whether Enter was taken: `(ctx, draft)`, true = taken, and then the field clears.
pub const SubmitFn = ?*const fn (?*anyopaque, []const u8) bool;

// How much draft a field owns. An app that needs more binds a bigger buffer with `bindTo`.
pub const max_field_len: usize = 256;

// The most a single paste can carry: the clipboard is read into one stack buffer, and a longer run is truncated.
pub const paste_max: usize = 64 * 1024;

// Where a field's copy, cut and paste go: the system clipboard by default, a scripted one in a test.
pub const Clipboard = struct {
    ctx: ?*anyopaque = null,
    read_fn: *const fn (?*anyopaque, []u8) []const u8 = platformRead,
    write_fn: *const fn (?*anyopaque, []const u8) void = platformWrite,

    // The pasteboard's text, copied into `buf`; empty when it holds no text.
    pub fn read(self: Clipboard, buf: []u8) []const u8 {
        return self.read_fn(self.ctx, buf);
    }

    // Replace the pasteboard's text.
    pub fn write(self: Clipboard, text: []const u8) void {
        self.write_fn(self.ctx, text);
    }
};

fn platformRead(_: ?*anyopaque, buf: []u8) []const u8 {
    return @import("../select.zig").Clipboard.read(buf);
}

fn platformWrite(_: ?*anyopaque, text: []const u8) void {
    @import("../select.zig").Clipboard.write(text);
}

// The rows EVERY text field offers, in this order: they are the field's own, and an app's `menu.items` follow them.
pub const menu_prefix = [_][]const u8{ "Cut", "Copy", "Paste", "Select All" };

// How many rows a field's card can hold: its own four, then the app's.
pub const menu_cap: usize = 12;

// Which of the four CANNOT act, index-aligned with `menu_prefix`. A read-only field still shows all four (mandatory) and dims Cut and Paste.
const menu_editable_disabled = [_]bool{ false, false, false, false };
const menu_readonly_disabled = [_]bool{ true, false, true, false };

// The field that owns the keyboard this frame: the engine types into it, so the app never routes a key.
var active: ?*Field = null;

// Forget last frame's field: a field that stops being declared must not keep the keyboard.
pub fn beginFrame() void {
    active = null;
}

// Type a composed run into the focused field; false when no field owns the keyboard.
pub fn dispatchText(text: []const u8) bool {
    const field = active orelse return false;
    // A read-only field never takes a composed run: the pasteboard cannot type into a response body.
    if (field.readonly) return false;
    if (text.len == 0) return false;
    var before: [max_field_len]u8 = undefined;
    const before_len = field.editor.len;
    const n = @min(before_len, before.len);
    @memcpy(before[0..n], field.editor.text()[0..n]);
    if (text_editor.handleText(&field.editor, text) == .ignored) return false;
    if (changed(before[0..n], before_len, field.editor.text())) field.report();
    return true;
}

// A key for the focused field: Enter submits, everything else edits. False when no field owns the keyboard.
pub fn dispatchKey(mods: Mods, keycode: u32) bool {
    const field = active orelse return false;
    // A single-line field has no newline: Enter is the submit gesture, and with no handler it is absorbed.
    if (keycode == text_editor.KEY_ENTER) {
        // A read-only field types nothing; the submit shortcut still runs, so a response pane can re-send.
        if (field.readonly) {
            if (mods.shortcut()) _ = field.submit();
            return true;
        }
        // A multiline field types the newline instead, and only the shortcut submits; that is what puts the caret on a new line.
        if (field.multiline and !mods.shortcut()) {
            if (!field.editor.insertByte('\n')) return false;
            field.report();
            return true;
        }
        _ = field.submit();
        return true;
    }
    // Copy, cut and paste are the field's: a person presses them, so an app should not have to wire them.
    if (mods.shortcut()) {
        switch (keycode) {
            // Copy is the whole point of a read-only pane, so it stays; cut and paste would edit it, so they are absorbed.
            text_editor.KEY_C => return copySelection(field),
            text_editor.KEY_X => if (field.readonly) return true else return cutSelection(field),
            text_editor.KEY_V => if (field.readonly) return true else return pasteClipboard(field),
            else => {},
        }
    }
    var before: [max_field_len]u8 = undefined;
    const before_len = field.editor.len;
    const n = @min(before_len, before.len);
    @memcpy(before[0..n], field.editor.text()[0..n]);
    // A read-only field follows the caret and the selection; anything else would be an edit, so it is absorbed.
    if (field.readonly and !isNavigation(keycode, mods.shortcut())) return true;
    if (text_editor.handleKey(&field.editor, keycode, mods.shift, mods.shortcut()) == .ignored) return false;
    if (changed(before[0..n], before_len, field.editor.text())) field.report();
    return true;
}

// True when the text differs from the snapshot taken before the key: an arrow moves the caret, not the text.
fn changed(before: []const u8, before_len: usize, after: []const u8) bool {
    if (after.len != before_len) return true;
    return !std.mem.eql(u8, before, after[0..before.len]);
}

// The only keys a read-only field acts on: they move the caret and grow the selection, and change no byte.
fn isNavigation(keycode: u32, shortcut: bool) bool {
    return switch (keycode) {
        text_editor.KEY_LEFT, text_editor.KEY_RIGHT, text_editor.KEY_UP, text_editor.KEY_DOWN, text_editor.KEY_HOME, text_editor.KEY_END => true,
        text_editor.KEY_A => shortcut,
        else => false,
    };
}

// Copy the selection: the pasteboard copies at once, so it is handed the draft's own bytes and nothing is allocated.
pub fn copySelection(field: *Field) bool {
    const span = field.editor.caret.selection() orelse return false;
    if (span.end <= span.start) return false;
    field.clipboard.write(field.editor.buf[span.start..span.end]);
    return true;
}

// Cut: copy, then delete, which the field reports like any other edit.
pub fn cutSelection(field: *Field) bool {
    if (!copySelection(field)) return false;
    if (!field.editor.deleteSelection()) return false;
    field.report();
    return true;
}

// Paste: one run from the clipboard, replacing a selection, reported as one edit.
pub fn pasteClipboard(field: *Field) bool {
    var buf: [paste_max]u8 = undefined;
    const text = field.clipboard.read(&buf);
    if (text.len == 0) return false;
    if (text_editor.handleText(&field.editor, text) == .ignored) return false;
    field.report();
    return true;
}

// The card a field raises: its own four rows first, then whatever the app asked for, in ONE list so an index is unambiguous.
fn fieldMenu(field: *Field) prop.ContextMenu {
    for (menu_prefix, 0..) |label, i| {
        field.menu_items[i] = label;
        field.menu_disabled[i] = if (field.readonly) menu_readonly_disabled[i] else menu_editable_disabled[i];
    }
    var n: usize = menu_prefix.len;
    for (field.menu.items, 0..) |label, i| {
        if (n == menu_cap) break;
        field.menu_items[n] = label;
        field.menu_disabled[n] = field.menu.isDisabled(i);
        n += 1;
    }
    var menu = field.menu;
    menu.items = field.menu_items[0..n];
    menu.disabled = field.menu_disabled[0..n];
    menu.on_select = .{ .f = onMenuPick, .ctx = field };
    menu.on_open = .{ .f = onMenuOpen, .ctx = field };
    return menu;
}

// A row was picked: the field's four are its own, and anything after them is the app's, with the app's own index.
fn onMenuPick(ctx: ?*anyopaque, index: usize) void {
    const field: *Field = @ptrCast(@alignCast(ctx.?));
    switch (index) {
        0 => {
            if (!field.readonly) _ = cutSelection(field);
        },
        1 => _ = copySelection(field),
        2 => {
            if (!field.readonly) _ = pasteClipboard(field);
        },
        3 => field.editor.selectAll(),
        else => {
            const app = field.menu.on_select;
            if (app.f) |f| f(app.ctx, index - menu_prefix.len);
        },
    }
}

// A right click takes the caret where it landed, and keeps a selection it landed INSIDE, so Copy has something to copy.
fn onMenuOpen(ctx: ?*anyopaque) void {
    const field: *Field = @ptrCast(@alignCast(ctx.?));
    if (field.menu.on_open.f) |f| f(field.menu.on_open.ctx);
    if (!pointInField(field, frame_mod.ptr_x, frame_mod.ptr_y)) return;
    const data = cl.getElementData(cl.getElementId(field.name()));
    if (!data.found) return;
    const bb = data.bounding_box;
    const x = frame_mod.ptr_x - bb.x - field.pad_lr.pts() + field.h_scroll;
    const y = frame_mod.ptr_y - bb.y - field.pad.top.pts();
    const at = field.caretOffsetAtPoint(x, y);
    if (field.editor.caret.selection()) |span| {
        if (at >= @min(span.start, span.end) and at <= @max(span.start, span.end)) {
            field.editor.idle = 0;
            frame_mod.setFocus(field.name());
            if (field.on_focus.f) |f| f(field.on_focus.ctx);
            return;
        }
    }
    field.editor.setCaret(at, false);
    frame_mod.setFocus(field.name());
    if (field.on_focus.f) |f| f(field.on_focus.ctx);
}

// The field's box cut down to the viewport of the scroll it lives in: a field taller than its box is only clickable where it SHOWS.
fn visibleBox(field: *const Field) ?cl.BoundingBox {
    const data = cl.getElementData(cl.getElementId(field.name()));
    if (!data.found) return null;
    const bb = data.bounding_box;
    const scroll_id = field.scroll_id orelse return bb;
    const view = cl.getElementData(cl.getElementId(scroll_id));
    if (!view.found) return bb;
    const v = view.bounding_box;
    const x0 = @max(bb.x, v.x);
    const y0 = @max(bb.y, v.y);
    const x1 = @min(bb.x + bb.width, v.x + v.width);
    const y1 = @min(bb.y + bb.height, v.y + v.height);
    return .{ .x = x0, .y = y0, .width = @max(x1 - x0, 0), .height = @max(y1 - y0, 0) };
}

// True when (x, y) is on the part of the field the user can actually see.
fn pointInField(field: *const Field, x: f32, y: f32) bool {
    const bb = visibleBox(field) orelse return false;
    return x >= bb.x and x < bb.x + bb.width and y >= bb.y and y < bb.y + bb.height;
}

// Anchor the caret on the press, extend it while the button stays down, and release the drag when it comes up.
fn dragSelect(field: *Field) void {
    if (!frame_mod.ptr_down) {
        field.dragging = false;
        return;
    }
    // Only a press on the VISIBLE field may take the caret: a field taller than its scroll box reaches past the viewport.
    const began_here = pointInField(field, frame_mod.ptr_press_x, frame_mod.ptr_press_y);
    if (!field.dragging and !began_here) return;
    const data = cl.getElementData(cl.getElementId(field.name()));
    if (!data.found) return;
    const bb = data.bounding_box;
    // `extend` is false on the anchoring frame (place the caret) and true after it (grow the selection from that anchor).
    const x = frame_mod.ptr_x - bb.x - field.pad_lr.pts() + field.h_scroll;
    const y = frame_mod.ptr_y - bb.y - field.pad.top.pts();
    field.editor.setCaret(field.caretOffsetAtPoint(x, y), field.dragging);
    if (!field.dragging) {
        field.dragging = true;
        frame_mod.setFocus(field.name());
        if (field.on_focus.f) |f| f(field.on_focus.ctx);
    }
}

// Declare a text field: the draft, its caret and selection, the blink, the click that places the caret, and the keyboard.
pub fn textField(field: *Field) void {
    field.bind();
    const input = &field.editor;
    const name = field.rememberName();
    // The click and drag handlers need the same origin and metrics the text is drawn with.
    field.pad_lr = field.pad.left;
    // The model's value wins when it CHANGED; an unchanged value leaves the draft and the caret alone.
    const adopt = if (field.declared_known) !field.declaredIs(field.value) else input.len == 0;
    if (!field.declared_known or adopt) {
        field.declared_known = true;
        field.rememberDeclared(field.value);
        if (adopt and !std.mem.eql(u8, field.value, input.text())) input.setText(field.value);
    }
    // Drag-select first, so the caret and the selection this frame draws are the ones the pointer just asked for.
    dragSelect(field);
    const draft = input.text();
    // A model edit can write a shorter run in place, and the caret it left behind must not slice past the new end.
    input.caret.clamp(draft.len);
    // The clip's own width is last frame's, because a box read mid-declare has not been laid out yet.
    if (frame_mod.bounds(textClipId(name))) |b| field.inner_w = b.width;
    // A caret that would land outside the field slides the text left instead: that IS the horizontal scroll.
    syncScroll(field, draft);
    // Once a click has claimed the keyboard, the toolkit decides who owns it: clicking another component blurs this field.
    if (frame_mod.focusKnown()) input.focused = frame_mod.isFocused(name);
    // The engine types into the focused field, so an app declares a field and never routes a key.
    if (input.focused and !field.disabled) active = field;
    // The field owns its own animation, and only while it is focused: an unfocused field holds its clock at zero and draws no caret.
    input.tickBlink(frame_mod.delta_s);
    const fg: Color = if (field.disabled) field.disabled_fg else field.fg;
    // Solid for half a second after the caret moves, then blinking: a caret that blinks while you type is a caret you cannot find.
    const blink_on = text_editor.caretVisible(input) and caretLineOnScreen(field);
    // A hint belongs to an empty single-line field nobody is typing in, so it never competes with a draft or a caret.
    const hint = field.placeholder.len > 0 and draft.len == 0 and !input.focused and !field.disabled;
    // The caret's row is revealed after the layout, mid-declare its box does not exist yet, and only when it MOVED: a reveal every frame pulled the box back to the caret, so a wheel scroll could not stay down.
    var reveal_pending = false;
    if (field.multiline and input.focused and field.scroll_id != null) {
        const caret_now = @min(input.caret.offset, input.len);
        // A reveal follows a caret that MOVED while no button was held: a drag belongs to whatever the press grabbed.
        if (field.revealed_caret != caret_now) {
            if (!frame_mod.ptr_down) {
                scroll_mod.revealAfterLayout(field.scroll_id.?, lineBoxId(name, field.caretLine()));
                reveal_pending = true;
            }
            field.revealed_caret = caret_now;
        }
    } else {
        field.revealed_caret = null;
    }

    cl.UI()(.{
        .id = field.id.clay(),
        .layout = .{
            .direction = if (field.multiline) .top_to_bottom else .left_to_right,
            .sizing = .{ .w = field.w.clay(), .h = field.h.clay() },
            .padding = field.pad.clay(),
            .child_alignment = .{ .x = .left, .y = if (field.multiline) .top else .center },
            .child_gap = 0,
        },
        .background_color = (if (field.disabled) field.disabled_bg else field.bg).toClay(),
        .corner_radius = field.radius.clay(),
        .border = field.border.clay(),
    })({
        // The value rides inside ONE horizontal clip, so it slides under the field's right edge instead of over a neighbour.
        cl.UI()(.{
            .id = textClipId(name),
            .layout = .{
                .direction = if (field.multiline) .top_to_bottom else .left_to_right,
                .sizing = .{ .w = .grow, .h = .grow },
                .child_alignment = .{ .x = .left, .y = if (field.multiline) .top else .center },
                .child_gap = 0,
            },
            .clip = .{ .horizontal = true, .child_offset = .{ .x = -field.h_scroll, .y = 0 } },
        })({
            if (field.multiline) {
                drawLines(field, draft, blink_on, fg, name, reveal_pending);
            } else {
                drawSingleLine(field, draft, blink_on, fg, name, hint);
            }
        });
    });

    // Semantics: an editable field declares `set_text`, so a test can type into it by name and a reader can find it.
    if (!field.disabled and name.len > 0) {
        semantics.registerAt(@src(), .{
            .declared = semantics.declaredAt(field.src),
            .id = field.id.clay(),
            .tag = name,
            .role = .text_field,
            .value = draft,
            .flags = .{ .enabled = true },
            .actions = .{ .set_text = true },
        });
    }
    registry.registerClickDoubleCursorZ(field.id.clay(), onFieldClick, onFieldDoubleClick, field, .text, field.click_z);
    // Every field offers its own card, so an input is never a place where a right click does nothing.
    if (!field.disabled and name.len > 0) context_menu.register(field.id.clay(), fieldMenu(field), field.click_z);
}

// How many lines of a multiline field are drawn: a buffer is bounded by its own length, but a frame's command stream is not free.
pub const max_lines: usize = 512;

// A caret is a floating bar, so an enclosing scroll's clip does not cut it: draw it only while its own line is visible.
pub fn caretLineOnScreen(field: *const Field) bool {
    const scroll_id = field.scroll_id orelse return true;
    const v = scroll_mod.view(scroll_id);
    if (!v.found or v.content_height <= v.height) return true;
    const top = @as(f32, @floatFromInt(field.caretLine())) * field.lineHeight();
    return top + field.lineHeight() > v.y and top < v.y + v.height;
}

// How far into its own line the caret sits, in the field's own font: the x that has to stay on screen.
fn caretX(field: *const Field, draft: []const u8) f32 {
    const at = @min(field.editor.caret.offset, draft.len);
    if (!field.multiline) return field.measure(draft[0..at], field.font_size.whole());
    const line = lineIndexAt(field, at);
    const start = @min(lineStartOf(field, line), at);
    return field.measure(draft[start..at], field.font_size.whole());
}

// Slide the text left until the caret is back inside the clip, and no further: this is the whole of the horizontal scroll.
fn syncScroll(field: *Field, draft: []const u8) void {
    const width = field.inner_w;
    // A field that has not been laid out yet has no room to keep a caret in, so the text stays where it is.
    if (width <= 0) return;
    // Two points of air past the caret, so a glyph typed at the edge is not painted half outside the field.
    const room = width - 2;
    const x = caretX(field, draft);
    if (x - field.h_scroll > room) field.h_scroll = x - room;
    if (x - field.h_scroll < 0) field.h_scroll = x;
    field.h_scroll = @max(field.h_scroll, 0);
}

// The Clay id of a line's row: what an enclosing scroll looks up to keep the caret's line in view.
pub fn lineBoxId(name: []const u8, line: usize) cl.ElementId {
    return .IDI(name, lineBoxIndex(line));
}

// The Clay ids a multiline field's per-line boxes live under: three consecutive ids per line.
fn lineBoxIndex(line: usize) u32 {
    return @intCast(4096 + line * 3);
}

fn lineSelIndex(line: usize) u32 {
    return lineBoxIndex(line) + 1;
}

fn lineCaretIndex(line: usize) u32 {
    return lineBoxIndex(line) + 2;
}

// The two gaps a virtualised field draws instead of the lines above and below the viewport, so the scrollbar stays honest.
const gap_above_id: u32 = 4093;
const gap_below_id: u32 = 4094;

// How many lines a viewport of `height` at `y` covers, with an overscan so a flick of the wheel does not show a blank row.
pub const LineWindow = struct { first: usize, count: usize };

pub fn windowFor(total: usize, y: f32, height: f32, line_h: f32) LineWindow {
    return lineWindow(total, y, height, line_h);
}

fn lineWindow(total: usize, y: f32, height: f32, line_h: f32) LineWindow {
    if (line_h <= 0 or total == 0) return .{ .first = 0, .count = 0 };
    const overscan: usize = 3;
    const at: usize = if (y > 0) @intFromFloat(@max(y, 0) / line_h) else 0;
    const first = if (at > overscan) at - overscan else 0;
    const per_page: usize = @as(usize, @intFromFloat(@ceil(@max(height, 0) / line_h))) + 1 + 2 * overscan;
    const remaining = if (total > first) total - first else 0;
    return .{ .first = first, .count = @min(@min(per_page, remaining), max_lines) };
}

// How many lines the text has: the app's index when it handed one over, the editor's own count otherwise.
fn lineTotal(field: *const Field) usize {
    if (field.lines) |index| return if (index.len > 1) index.len - 1 else 0;
    return field.editor.lineCount();
}

// Where line `line` starts.
fn lineStartOf(field: *const Field, line: usize) usize {
    if (field.lines) |index| {
        if (index.len == 0) return 0;
        return index[@min(line, index.len - 1)];
    }
    return field.editor.lineStartAt(line);
}

// Where line `line` ends, without the newline that closes it.
fn lineEndOf(field: *const Field, line: usize) usize {
    const ed = &field.editor;
    if (field.lines) |index| {
        if (index.len == 0) return 0;
        var end = index[@min(line + 1, index.len - 1)];
        if (end > 0 and end <= ed.len and ed.buf[end - 1] == '\n') end -= 1;
        return @min(end, ed.len);
    }
    const start = lineStartOf(field, line);
    var end = start;
    while (end < ed.len and ed.buf[end] != '\n') end += 1;
    return end;
}

// The line a byte offset falls on: a binary search over the app's index, a scan over the editor's own text.
fn lineIndexAt(field: *const Field, offset: usize) usize {
    const index = field.lines orelse return field.editor.lineNumber(offset);
    if (index.len < 2) return 0;
    var lo: usize = 0;
    var hi: usize = index.len - 2;
    while (lo < hi) {
        const mid = lo + (hi - lo + 1) / 2;
        if (index[mid] <= offset) lo = mid else hi = mid - 1;
    }
    return lo;
}

// The caret's Clay id inside a multiline field on `line`: what a test, or the devtool, looks for.
pub fn lineCaretId(name: []const u8, line: usize) cl.ElementId {
    return .IDI(name, lineCaretIndex(line));
}

// The single-line caret's Clay id: a focused field draws exactly one bar, under this id.
pub fn caretId(name: []const u8) cl.ElementId {
    return .IDI(name, 2);
}

// The clip's index under the field: 1 is the selection run, 2 the caret, so the clip takes 3.
const text_clip_index: u32 = 3;

// The clip's Clay id, which is also the box whose width is the room the text has before it has to slide.
pub fn textClipId(name: []const u8) cl.ElementId {
    return .IDI(name, text_clip_index);
}

// The single-line body of a field: the selection as three runs, or the draft as one with the caret floated after it.
fn drawSingleLine(field: *Field, draft: []const u8, blink_on: bool, fg: Color, name: []const u8, hint: bool) void {
    const input = &field.editor;
    if (input.caret.hasSelection()) {
        const span = input.caret.selection().?;
        const s = span.start;
        const e = span.end;
        if (s > 0) cl.text(draft[0..s], .{ .font_size = field.font_size.whole(), .color = fg.toClay() });
        cl.UI()(.{
            .id = .IDI(name, 1),
            // Fit and unpadded: a taller highlight lifts every glyph on the line the moment a selection appears.
            .layout = .{ .sizing = .{ .w = .fit, .h = .fit } },
            .background_color = field.sel_bg.toClay(),
        })({
            cl.text(draft[s..e], .{ .font_size = field.font_size.whole(), .color = field.sel_fg.toClay() });
        });
        if (e < draft.len) cl.text(draft[e..], .{ .font_size = field.font_size.whole(), .color = fg.toClay() });
        return;
    }
    // One run for the value, caret floated over it; an empty one draws a space so `.fit` keeps a line.
    if (hint) {
        cl.text(field.placeholder, .{ .font_size = field.font_size.whole(), .color = field.placeholder_fg.toClay() });
        return;
    }
    cl.text(if (draft.len == 0) " " else draft, .{ .font_size = field.font_size.whole(), .color = fg.toClay() });
    if (blink_on) caretBar(field, draft);
}

// A multiline field: one row per line, and the caret floated on the line the caret is actually on.
fn drawLines(field: *Field, draft: []const u8, blink_on: bool, fg: Color, name: []const u8, keep_caret: bool) void {
    const ed = &field.editor;
    const sel = ed.caret.selection();
    const line_h = field.lineHeight();
    const caret_offset = @min(ed.caret.offset, ed.len);
    const caret_line = lineIndexAt(field, caret_offset);
    const total = lineTotal(field);
    var window = windowForField(field, total);
    // The caret's line joins the window ONLY when a reveal is pending: applyReveals needs its box, and the next frame draws the real window.
    if (keep_caret and total > window.count) {
        if (caret_line < window.first) {
            window.first = caret_line;
        } else if (caret_line >= window.first + window.count) {
            window.first = caret_line + 1 - window.count;
        }
    }
    // Everything above the window is ONE box of its exact height, which is what keeps a megabyte body's scrollbar honest.
    if (window.first > 0) lineGap(name, gap_above_id, @as(f32, @floatFromInt(window.first)) * line_h);
    var i: usize = window.first;
    const last = window.first + window.count;
    while (i < last) : (i += 1) {
        const start = @min(lineStartOf(field, i), draft.len);
        // An app's line index can be a frame behind its text, so a line never ends before it starts.
        const end = @min(@max(lineEndOf(field, i), start), draft.len);
        const line = draft[start..end];
        cl.UI()(.{
            .id = .IDI(name, lineBoxIndex(i)),
            .layout = .{
                .direction = .left_to_right,
                .sizing = .{ .w = .grow, .h = .fixed(line_h) },
                .child_alignment = .{ .x = .left, .y = .center },
                .child_gap = 0,
            },
        })({
            drawLine(field, line, start, sel, fg, name, i);
            // The caret is the line's own child, so it sits at that line's start even when the line is empty.
            if (blink_on and i == caret_line) caretBarInLine(field, name, i, line, caret_offset - start);
        });
    }
    if (last < total) lineGap(name, gap_below_id, @as(f32, @floatFromInt(total - last)) * line_h);
}

// The window a field draws: everything it has, unless an enclosing scroll shows that it does not all fit.
fn windowForField(field: *const Field, total: usize) LineWindow {
    const all = LineWindow{ .first = 0, .count = @min(total, max_lines) };
    const scroll_id = field.scroll_id orelse return all;
    const v = scroll_mod.view(scroll_id);
    // Only virtualise when the content really overflows: a field that fits keeps every line declared, ids and all.
    if (!v.found or v.height <= 0 or v.content_height <= v.height) return all;
    return lineWindow(total, v.y, v.height, field.lineHeight());
}

// One box standing in for the lines outside the viewport: no text, just the height they would have taken.
fn lineGap(name: []const u8, id: u32, height: f32) void {
    cl.UI()(.{
        .id = .IDI(name, id),
        .layout = .{
            .sizing = .{ .w = .grow, .h = .fixed(height) },
        },
    })({});
}

// One line of a multiline field, split around the selection when the selection overlaps it.
fn drawLine(field: *Field, line: []const u8, line_start: usize, sel: ?text_editor.Span, fg: Color, name: []const u8, index: usize) void {
    // An empty line still draws a cell, so its box has a height for the caret to float in.
    if (line.len == 0) {
        cl.text(" ", .{ .font_size = field.font_size.whole(), .color = fg.toClay() });
        return;
    }
    const span = sel orelse {
        cl.text(line, .{ .font_size = field.font_size.whole(), .color = fg.toClay() });
        return;
    };
    const line_end = line_start + line.len;
    if (span.end <= line_start or span.start >= line_end) {
        cl.text(line, .{ .font_size = field.font_size.whole(), .color = fg.toClay() });
        return;
    }
    const a = @min(@max(span.start, line_start) - line_start, line.len);
    const b = @min(@max(span.end, line_start) - line_start, line.len);
    if (a > 0) cl.text(line[0..a], .{ .font_size = field.font_size.whole(), .color = fg.toClay() });
    cl.UI()(.{
        .id = .IDI(name, lineSelIndex(index)),
        // Fit and unpadded, like the single-line highlight: a taller box would resize the line it sits on.
        .layout = .{ .sizing = .{ .w = .fit, .h = .fit } },
        .background_color = field.sel_bg.toClay(),
    })({
        cl.text(line[a..b], .{ .font_size = field.font_size.whole(), .color = field.sel_fg.toClay() });
    });
    if (b < line.len) cl.text(line[b..], .{ .font_size = field.font_size.whole(), .color = fg.toClay() });
}

// The caret inside a line row: the row already sits past the field's padding, so no extra offset is added.
fn caretBarInLine(field: *Field, name: []const u8, index: usize, line: []const u8, at: usize) void {
    const clamped = @min(at, line.len);
    caret_mod.declare(.{
        .id = .IDI(name, lineCaretIndex(index)),
        .x = .{ .px = field.measure(line[0..clamped], field.font_size.whole()) },
        // The row's own x is what the bar lands on, and a row between two pixels is what makes a caret look smeared.
        .parent_x = if (frame_mod.bounds(lineBoxId(name, index))) |b| b.x else null,
        .height = .{ .px = field.font_size.pts() + 4 },
        .color = field.caret_fg orelse Color.rgb(0xd8, 0xd8, 0xd8),
        .anchor = .center,
    });
}

// Select the word under a double click, which is what every text field does.
fn onFieldDoubleClick(ctx: ?*anyopaque) void {
    const field: *Field = @ptrCast(@alignCast(ctx.?));
    const data = cl.getElementData(cl.getElementId(field.name()));
    if (!data.found) return;
    // The clip slid the text left by `h_scroll`, so the point is measured from where the text now starts.
    const x = frame_mod.ptr_x - data.bounding_box.x - field.pad_lr.pts() + field.h_scroll;
    const y = frame_mod.ptr_y - data.bounding_box.y - field.pad.top.pts();
    text_editor.selectWordAt(&field.editor, field.caretOffsetAtPoint(x, y));
    field.editor.idle = 0;
    frame_mod.setFocus(field.name());
    if (field.on_focus.f) |f| f(field.on_focus.ctx);
}

// The caret, floated at the measured end of the run before it. The primitive snaps it and makes it one device pixel.
fn caretBar(field: *Field, text: []const u8) void {
    const at = @min(field.editor.caret.offset, text.len);
    caret_mod.declare(.{
        .id = .IDI(field.name(), 2),
        // The parent is the text's own clip, which already sits past the field's padding and border: adding the pad again leaves a gap after the last glyph.
        .x = .{ .px = @max(field.measure(text[0..at], field.font_size.whole()) - field.h_scroll, 0) },
        // The field's own x is what the bar lands on, and a field between two pixels is what makes a caret look smeared.
        .parent_x = if (frame_mod.bounds(field.id.clay())) |b| b.x else null,
        .height = .{ .px = field.font_size.pts() + 4 },
        .color = field.caret_fg orelse Color.rgb(0xd8, 0xd8, 0xdc),
        .anchor = .center,
    });
}

// Place the caret from a click, using the field's own box and the frame's pointer.
fn onFieldClick(ctx: ?*anyopaque) void {
    const field: *Field = @ptrCast(@alignCast(ctx.?));
    if (!pointInField(field, frame_mod.ptr_x, frame_mod.ptr_y)) return;
    const data = cl.getElementData(cl.getElementId(field.name()));
    if (!data.found) return;
    // The clip slid the text left by `h_scroll`, so the point is measured from where the text now starts.
    const x = frame_mod.ptr_x - data.bounding_box.x - field.pad_lr.pts() + field.h_scroll;
    const y = frame_mod.ptr_y - data.bounding_box.y - field.pad.top.pts();
    field.editor.setCaret(field.caretOffsetAtPoint(x, y), false);
    field.editor.idle = 0;
    frame_mod.setFocus(field.name());
    if (field.on_focus.f) |f| f(field.on_focus.ctx);
}

// ---- Double click: the word under the pointer is selected, and the next frame keeps the highlight ----

var dbl_field: Field = .{ .id = .{ .text = "test-double-field" } };

fn declareDblField() void {
    textField(&dbl_field);
}

test "a double click selects the word under the pointer, and the next frame still draws it" {
    frame_mod.setTime(0, 0);
    frame_mod.resetFocus();
    frame_mod.ptr_down = false;
    beginFrame();
    dbl_field = .{ .id = .{ .text = "test-double-field" }, .value = "hello world" };
    dbl_field.bind();
    _ = try layoutCommands(declareDblField);
    const bb = cl.getElementData(cl.getElementId("test-double-field")).bounding_box;
    // Two points into the run: past the field's own left padding, so the pointer lands inside "hello".
    const x = bb.x + dbl_field.pad_lr.pts() + 2;
    const y = bb.y + bb.height * 0.5;
    frame_mod.setPointer(x, y);
    try std.testing.expect(registry.dispatchDoubleClick(x, y));
    const span = dbl_field.editor.caret.selection() orelse return error.NoSelection;
    try std.testing.expectEqual(@as(usize, 0), span.start);
    try std.testing.expectEqual(@as(usize, 5), span.end);

    // The frame after the click, with the button already released: the selection survives and is drawn as its own run.
    const cmds = try layoutCommands(declareDblField);
    const kept = dbl_field.editor.caret.selection() orelse return error.SelectionCleared;
    try std.testing.expectEqual(@as(usize, 5), kept.end);
    var highlighted = false;
    for (cmds) |c| {
        if (c.command_type == .rectangle and c.id == cl.ElementId.IDI("test-double-field", 1).id) highlighted = true;
    }
    try std.testing.expect(highlighted);
}

fn layoutCommands(declare_fn: *const fn () void) ![]cl.RenderCommand {
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declare_fn();
    return cl.endLayout();
}

// A value far wider than any field a test declares, so the clip and the scroll both have something to do.
const long_value = "{\"sub\":\"7748bcb7-ea24-46e6-acd2-965e1f67910f\",\"access_satellite\":true,\"pool_id\":\"CK\"}";

var clip_field: Field = .{ .id = .{ .text = "test-clip-field" } };

fn declareClipField() void {
    textField(&clip_field);
}

test "a long value is clipped to its own field, and never widens it" {
    frame_mod.setTime(0, 0);
    frame_mod.resetFocus();
    frame_mod.ptr_down = false;
    beginFrame();
    clip_field = .{
        .id = .{ .text = "test-clip-field" },
        .value = long_value,
        .w = .{ .fixed = 120 },
        .h = .{ .fixed = 30 },
    };
    clip_field.bind();
    const cmds = try layoutCommands(declareClipField);
    // A clip element hands its parent no minimum width, so the field keeps the width it was declared with.
    const bb = cl.getElementData(cl.getElementId("test-clip-field")).bounding_box;
    try std.testing.expectApproxEqAbs(@as(f32, 120), bb.width, 0.5);
    // The value is still drawn in full -- it is clipped, not shortened -- and the run is wider than the field.
    var widest: f32 = 0;
    var clip_box: ?cl.BoundingBox = null;
    for (cmds) |c| {
        if (c.command_type == .text) widest = @max(widest, c.bounding_box.width);
        if (c.command_type == .scissor_start and c.id == textClipId("test-clip-field").id) clip_box = c.bounding_box;
    }
    try std.testing.expect(widest > bb.width);
    const clip = clip_box orelse return error.NoClip;
    try std.testing.expect(clip.width <= bb.width);
    // And the clip is a balanced pair, which is what the frame audit demands of every scissor.
    try std.testing.expectEqual(@as(usize, 0), audit.checkCommands(cmds, 1));
}

test "the caret scrolls the text right, and back to the left when it returns" {
    frame_mod.setTime(0, 0);
    frame_mod.resetFocus();
    frame_mod.ptr_down = false;
    beginFrame();
    clip_field = .{
        .id = .{ .text = "test-scroll-field" },
        .value = long_value,
        .w = .{ .fixed = 120 },
        .h = .{ .fixed = 30 },
    };
    clip_field.bind();
    // Clay keeps every element's box between frames, so this test initialises ONCE and lays out three times.
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
    // First frame: nothing measured yet, so there is no room to scroll against.
    _ = try layoutFrame(declareClipField);
    try std.testing.expectEqual(@as(f32, 0), clip_field.h_scroll);
    // The caret at the end of a value wider than the field slides the text left, so the caret stays in view.
    clip_field.editor.setCaret(clip_field.editor.len, false);
    _ = try layoutFrame(declareClipField);
    try std.testing.expect(clip_field.h_scroll > 0);
    // Back at the front (Home, or an arrow left the whole way), the text returns to its own start.
    clip_field.editor.setCaret(0, false);
    _ = try layoutFrame(declareClipField);
    try std.testing.expectEqual(@as(f32, 0), clip_field.h_scroll);
}

// One more frame on the same Clay context, so a box measured by the frame before it can be read.
fn layoutFrame(declare_fn: *const fn () void) ![]cl.RenderCommand {
    cl.beginLayout();
    declare_fn();
    return cl.endLayout();
}

// Clay registers EVERY clip element as a scroll container, so a wheel over a field's own horizontal clip must still reach the box around it.
var wheel_field: Field = .{ .id = .{ .text = "test-wheel-field" } };

fn declareWheelFieldScroll() void {
    scroll_mod.scroll(.{
        .id = .{ .text = "test-wheel-scroll" },
        .w = .{ .fixed = 200 },
        .h = .{ .fixed = 100 },
    }, {}, wheelScrollChildren);
}

fn wheelScrollChildren(_: void) void {
    textField(&wheel_field);
    var i: usize = 0;
    while (i < 9) : (i += 1) {
        cl.UI()(.{
            .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(40) } },
            .background_color = .{ 80, 80, 80, 255 },
        })({});
    }
}

// A multiline field taller than the box it lives in: the field is 300 pt of lines inside a 100 pt scroll box.
var bleed_field: Field = .{ .id = .{ .text = "test-bleed-field" } };

fn declareBleedScroll() void {
    scroll_mod.scroll(.{
        .id = .{ .text = "test-bleed-scroll" },
        .w = .{ .fixed = 200 },
        .h = .{ .fixed = 100 },
    }, {}, bleedScrollChildren);
}

fn bleedScrollChildren(_: void) void {
    textField(&bleed_field);
}

test "a multiline field taller than its scroll box paints nothing outside the box" {
    frame_mod.setTime(0, 0);
    frame_mod.resetFocus();
    frame_mod.ptr_down = false;
    beginFrame();
    bleed_field = .{
        .id = .{ .text = "test-bleed-field" },
        .multiline = true,
        .value = "line\nline\nline\nline\nline\nline\nline\nline\nline\nline\nline\nline\n",
        .w = .{ .fixed = 160 },
        .h = .{ .fixed = 300 },
    };
    bleed_field.bind();
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
    _ = try layoutFrame(declareBleedScroll);
    const cmds = try layoutFrame(declareBleedScroll);
    const box = cl.getElementData(cl.getElementId("test-bleed-scroll")).bounding_box;
    try std.testing.expectApproxEqAbs(@as(f32, 200), box.width, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 100), box.height, 0.5);

    var surface = try soft.Surface.init(std.testing.allocator, 260, 200);
    defer surface.deinit();
    surface.setClearColor(.{ 0, 0, 0, 255 });
    surface.clear();
    surface.renderCommands(cmds);

    // Something was painted inside the box, so the sweep below is not vacuous.
    var inked: usize = 0;
    var y: i64 = 0;
    while (y < 100) : (y += 1) {
        var x: i64 = 0;
        while (x < 200) : (x += 1) {
            if (surface.px(x, y)[0] != 0 or surface.px(x, y)[1] != 0 or surface.px(x, y)[2] != 0) inked += 1;
        }
    }
    try std.testing.expect(inked > 0);

    // And NOTHING outside it: the field is three times the box's height, so its own clip alone would leak.
    y = 0;
    while (y < 200) : (y += 1) {
        var x: i64 = 0;
        while (x < 260) : (x += 1) {
            if (x < 200 and y < 100) continue;
            const px = surface.px(x, y);
            try std.testing.expectEqualDeep([4]u8{ 0, 0, 0, 255 }, px);
        }
    }
}

test "a wheel over a text field scrolls the box around it, not the field's own clip" {
    frame_mod.setTime(0, 0);
    frame_mod.resetFocus();
    frame_mod.ptr_down = false;
    beginFrame();
    wheel_field = .{
        .id = .{ .text = "test-wheel-field" },
        .value = long_value,
        .w = .{ .fixed = 160 },
        .h = .{ .fixed = 30 },
    };
    wheel_field.bind();
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
    _ = try layoutFrame(declareWheelFieldScroll);
    const field_box = cl.getElementData(cl.getElementId("test-wheel-field")).bounding_box;
    const scroll_box = cl.getElementData(cl.getElementId("test-wheel-scroll")).bounding_box;
    try std.testing.expect(scroll_box.height <= 100.5);
    // Hover the TEXT itself: that point is under the field's own horizontal clip as well as the box around it.
    cl.setPointerState(.{ .x = field_box.x + 10, .y = field_box.y + 10 }, false);
    scroll_mod.updateScroll(0, -5, 1.0 / 60.0);
    _ = try layoutFrame(declareWheelFieldScroll);
    const data = cl.getScrollContainerData(cl.getElementId("test-wheel-scroll"));
    try std.testing.expect(data.found);
    try std.testing.expectApproxEqAbs(@as(f32, -5), data.scroll_position.y, 0.5);
    // The field's own clip did not move: it only ever scrolls sideways.
    const own = cl.getScrollContainerData(cl.getElementId("test-wheel-field"));
    try std.testing.expect(own.found == false or own.scroll_position.x == 0);
}

test "a clip element dragged off the screen still emits a balanced scissor pair" {
    headless.begin(.{ .x = 120, .y = 80 }, false);
    cl.beginLayout();
    cl.UI()(.{
        .layout = .{ .direction = .left_to_right, .sizing = .{ .w = .fixed(120), .h = .fixed(80) } },
    })({
        // 200 pt of empty space pushes the clip past the right edge of the layout, so Clay culls its commands.
        cl.UI()(.{ .layout = .{ .sizing = .{ .w = .fixed(200), .h = .fixed(20) } } })({});
        cl.UI()(.{
            .id = .ID("test-offscreen-clip"),
            .layout = .{ .sizing = .{ .w = .fixed(40), .h = .fixed(20) } },
            .clip = .{ .horizontal = true },
        })({});
    });
    const cmds = cl.endLayout();
    // A culled clip must drop both of its commands: a lone SCISSOR_END closes the enclosing clip early.
    try std.testing.expectEqual(@as(usize, 0), audit.checkCommands(cmds, 1));
}

test "handleText inserts a composed run and Backspace removes a whole codepoint" {
    var buf: [16]u8 = undefined;
    var len: usize = 0;
    var st = EditState{};
    try std.testing.expectEqual(Action.edited, handleText(&buf, &len, &st, "A*("));
    try std.testing.expectEqualStrings("A*(", buf[0..len]);
    try std.testing.expectEqual(Action.edited, handleText(&buf, &len, &st, "\xc3\xa9"));
    try std.testing.expectEqual(@as(usize, 5), len);
    backspaceAt(&buf, &len, &st);
    try std.testing.expectEqualStrings("A*(", buf[0..len]);
    try std.testing.expectEqual(Action.ignored, handleText(&buf, &len, &st, ""));
}

test "keyChar maps evdev codes with and without shift" {
    // Letters.
    try std.testing.expectEqual(@as(?u8, 'a'), keyChar(30, false));
    try std.testing.expectEqual(@as(?u8, 'A'), keyChar(30, true));
    try std.testing.expectEqual(@as(?u8, 'z'), keyChar(44, false));
    try std.testing.expectEqual(@as(?u8, 'Z'), keyChar(44, true));
    try std.testing.expectEqual(@as(?u8, 'm'), keyChar(50, false));
    // Digits + shifted symbols.
    try std.testing.expectEqual(@as(?u8, '1'), keyChar(2, false));
    try std.testing.expectEqual(@as(?u8, '!'), keyChar(2, true));
    try std.testing.expectEqual(@as(?u8, '0'), keyChar(11, false));
    try std.testing.expectEqual(@as(?u8, ')'), keyChar(11, true));
    // Timezone/format punctuation.
    try std.testing.expectEqual(@as(?u8, '/'), keyChar(53, false));
    try std.testing.expectEqual(@as(?u8, '-'), keyChar(12, false));
    try std.testing.expectEqual(@as(?u8, '_'), keyChar(12, true));
    try std.testing.expectEqual(@as(?u8, ':'), keyChar(39, true));
    try std.testing.expectEqual(@as(?u8, '.'), keyChar(52, false));
    try std.testing.expectEqual(@as(?u8, ' '), keyChar(57, false));
    try std.testing.expectEqual(@as(?u8, ' '), keyChar(57, true));
    // Non-printables.
    try std.testing.expect(keyChar(1, false) == null); // Escape
    try std.testing.expect(keyChar(14, false) == null); // Backspace
    try std.testing.expect(keyChar(28, false) == null); // Enter
    try std.testing.expect(keyChar(42, false) == null); // Shift
    try std.testing.expect(keyChar(59, false) == null); // F1
}

test "insert appends until full, backspace drops bytes" {
    var buf: [4]u8 = undefined;
    var len: usize = 0;
    try std.testing.expect(insert(&buf, &len, 'a'));
    try std.testing.expect(insert(&buf, &len, 'b'));
    try std.testing.expectEqual(@as(usize, 2), len);
    try std.testing.expectEqualStrings("ab", buf[0..len]);
    try std.testing.expect(insert(&buf, &len, 'c'));
    try std.testing.expect(insert(&buf, &len, 'd'));
    try std.testing.expect(!insert(&buf, &len, 'e'));
    try std.testing.expectEqual(@as(usize, 4), len);
    backspace(&len);
    try std.testing.expectEqual(@as(usize, 3), len);
    backspace(&len);
    backspace(&len);
    backspace(&len);
    backspace(&len); // clamps at zero
    try std.testing.expectEqual(@as(usize, 0), len);
}

test "Field carries neutral dark defaults" {
    const p = Field{ .id = .{ .text = "x" } };
    try std.testing.expectEqual(@as(f32, 14), p.font_size.pts());
    try std.testing.expectEqual(Color.rgb(0xe8, 0xe8, 0xe8), p.fg);
    try std.testing.expectEqual(Color.rgb(0x26, 0x26, 0x26), p.bg);
    try std.testing.expectEqual(@as(f32, 6), p.radius.top_left.pts());
    try std.testing.expect(std.meta.activeTag(p.w) == .grow);
    try std.testing.expectEqual(@as(f32, 0), p.pad.top.pts());
}

// ---- Field: the draft, the value prop, and the intents ----

var test_field: Field = .{};
var test_value: []const u8 = "";
var report_count: usize = 0;
var report_buf: [max_field_len]u8 = undefined;
var report_len: usize = 0;
var submit_taken: bool = true;
var submit_buf: [max_field_len]u8 = undefined;
var submit_len: usize = 0;

fn onTestChange(_: ?*anyopaque, text: []const u8) void {
    report_count += 1;
    report_len = @min(text.len, report_buf.len);
    @memcpy(report_buf[0..report_len], text[0..report_len]);
}

fn onTestSubmit(_: ?*anyopaque, text: []const u8) bool {
    submit_len = @min(text.len, submit_buf.len);
    @memcpy(submit_buf[0..submit_len], text[0..submit_len]);
    return submit_taken;
}

fn reported() []const u8 {
    return report_buf[0..report_len];
}

fn submitted() []const u8 {
    return submit_buf[0..submit_len];
}

fn declareTestField() void {
    textField(&test_field);
}

// A fresh field, one declared frame, and the keyboard on it.
fn startField(value: []const u8) !void {
    test_field = .{
        .id = .{ .text = "test-field" },
        .value = value,
        .on_change = .{ .f = onTestChange },
        .on_submit = .{ .f = onTestSubmit },
    };
    test_value = value;
    report_count = 0;
    report_len = 0;
    submit_len = 0;
    submit_taken = true;
    beginFrame();
    frame_mod.resetFocus();
    _ = try layoutCommands(declareTestField);
}

test "textField draws the value, declares its id and takes the keyboard" {
    try startField("jak");
    try std.testing.expectEqualStrings("jak", test_field.text());
    try std.testing.expect(cl.getElementData(cl.getElementId("test-field")).found);
    test_field.editor.setCaret(test_field.editor.len, false);
    // The engine types into it with no app handler at all.
    try std.testing.expect(dispatchText("!"));
    try std.testing.expectEqualStrings("jak!", test_field.text());
}

// How many rectangles a declared frame emits under one Clay id.
fn rectsWithId(id: u32) usize {
    const cmds = layoutCommands(declareTestField) catch return 0;
    var n: usize = 0;
    for (cmds) |c| {
        if (c.command_type == .rectangle and c.id == id) n += 1;
    }
    return n;
}

// How many caret bars the field's frame emits: the caret is a floating rectangle under `IDI(field, 2)`.
fn caretBars() usize {
    return rectsWithId(cl.ElementId.IDI("test-field", 2).id);
}

test "the caret bar is drawn while typing, after a submit, and after a refused submit" {
    frame_mod.setTime(0, 0);
    try startField("");
    try std.testing.expectEqual(@as(usize, 1), caretBars());
    try std.testing.expect(dispatchText("ab"));
    try std.testing.expectEqual(@as(usize, 1), caretBars());
    // A refused submit: the draft stays, so the caret must stay with it.
    submit_taken = false;
    try std.testing.expect(dispatchKey(.{}, text_editor.KEY_ENTER));
    try std.testing.expectEqualStrings("ab", test_field.text());
    try std.testing.expectEqual(@as(usize, 1), caretBars());
    // A taken submit clears the field, and the caret stays at the empty draft rather than vanishing.
    submit_taken = true;
    try std.testing.expect(dispatchKey(.{}, text_editor.KEY_ENTER));
    try std.testing.expectEqualStrings("", test_field.text());
    try std.testing.expectEqual(@as(usize, 1), caretBars());
}

test "Enter in a multiline field starts a new line, and the caret goes onto it" {
    frame_mod.setTime(0, 0);
    try startField("");
    test_field.multiline = true;
    try std.testing.expect(dispatchText("ab"));
    try std.testing.expect(dispatchKey(.{}, text_editor.KEY_ENTER));
    try std.testing.expectEqualStrings("ab\n", test_field.text());
    try std.testing.expectEqual(@as(usize, 3), test_field.editor.caret.offset);
    // Bare Enter raised no submit: it typed the line.
    try std.testing.expectEqualStrings("", submitted());
    // The caret bar is on the line Enter created, and not on the one before it.
    try std.testing.expectEqual(@as(usize, 1), rectsWithId(cl.ElementId.IDI("test-field", lineCaretIndex(1)).id));
    try std.testing.expectEqual(@as(usize, 0), rectsWithId(cl.ElementId.IDI("test-field", lineCaretIndex(0)).id));
    // Every line gets its own row, so the new line has a box to put the caret in.
    try std.testing.expect(cl.getElementData(cl.ElementId.IDI("test-field", lineBoxIndex(1))).found);
}

var clip_out: [256]u8 = undefined;
var clip_out_len: usize = 0;

fn clipCapture(_: ?*anyopaque, text: []const u8) void {
    clip_out_len = @min(text.len, clip_out.len);
    @memcpy(clip_out[0..clip_out_len], text[0..clip_out_len]);
}

test "a read-only field keeps the caret and the selection, and no key edits its text" {
    frame_mod.setTime(0, 0);
    try startField("");
    test_field.multiline = true;
    test_field.readonly = true;
    var bytes = [_]u8{ 'a', 'b', '\n', 'c', 'd' };
    test_field.show(&bytes);
    _ = try layoutCommands(declareTestField);
    try std.testing.expectEqualStrings("ab\ncd", test_field.text());

    // Every way of typing is absorbed: a composed run, Backspace, Delete, Enter, and a paste.
    try std.testing.expect(!dispatchText("x"));
    _ = dispatchKey(.{}, text_editor.KEY_BACKSPACE);
    _ = dispatchKey(.{}, text_editor.KEY_DELETE);
    _ = dispatchKey(.{}, text_editor.KEY_ENTER);
    _ = dispatchKey(.{ .ctrl = true }, text_editor.KEY_V);
    _ = dispatchKey(.{ .ctrl = true }, text_editor.KEY_X);
    try std.testing.expectEqualStrings("ab\ncd", test_field.text());
    try std.testing.expectEqual(@as(usize, 0), report_count);

    // Select all and copy: the one thing a read-only pane is for.
    clip_out_len = 0;
    test_field.clipboard = .{ .write_fn = clipCapture };
    _ = dispatchKey(.{ .ctrl = true }, text_editor.KEY_A);
    try std.testing.expect(dispatchKey(.{ .ctrl = true }, text_editor.KEY_C));
    try std.testing.expectEqualStrings("ab\ncd", clip_out[0..clip_out_len]);

    // The caret still moves, so a person can put it where a selection should start.
    test_field.editor.setCaret(2, false);
    _ = dispatchKey(.{}, text_editor.KEY_LEFT);
    try std.testing.expectEqual(@as(usize, 1), test_field.editor.caret.offset);
    try std.testing.expectEqualStrings("ab\ncd", test_field.text());
}

test "a read-only field shows the app's bytes without copying them" {
    frame_mod.setTime(0, 0);
    try startField("");
    test_field.multiline = true;
    test_field.readonly = true;
    var body = [_]u8{ 'x', '\n', 'y' };
    test_field.show(&body);
    try std.testing.expectEqualStrings("x\ny", test_field.text());
    try std.testing.expectEqual(@as([*]u8, &body), test_field.editor.buf.ptr);

    // A second body of a different length re-points the field, and the caret is clamped into it.
    test_field.editor.setCaret(3, false);
    var shorter = [_]u8{'z'};
    test_field.show(&shorter);
    try std.testing.expectEqualStrings("z", test_field.text());
    // A new run is a new document: the caret starts at its beginning instead of pointing into the old body.
    try std.testing.expectEqual(@as(usize, 0), test_field.editor.caret.offset);
}

test "the line window covers the viewport with an overscan, and never more than a frame can draw" {
    // 20 px rows, a 100 px viewport: five rows, one for the half row at the bottom, three of overscan either side.
    const top = windowFor(1000, 0, 100, 20);
    try std.testing.expectEqual(@as(usize, 0), top.first);
    try std.testing.expectEqual(@as(usize, 12), top.count);

    // Scrolled down: the window follows, minus the overscan above it.
    const scrolled = windowFor(1000, 400, 100, 20);
    try std.testing.expectEqual(@as(usize, 17), scrolled.first);
    try std.testing.expectEqual(@as(usize, 12), scrolled.count);

    // Near the end the window is clipped to what is left, so no row is drawn past the text.
    const tail = windowFor(20, 400, 100, 20);
    try std.testing.expectEqual(@as(usize, 17), tail.first);
    try std.testing.expectEqual(@as(usize, 3), tail.count);

    // A single line of movement still requests a sane window, and an empty field requests nothing.
    try std.testing.expectEqual(@as(usize, 0), windowFor(0, 0, 100, 20).count);
}

test "Ctrl+Enter submits a multiline field instead of typing another line" {
    frame_mod.setTime(0, 0);
    try startField("");
    test_field.multiline = true;
    try std.testing.expect(dispatchText("ab"));
    try std.testing.expect(dispatchKey(.{ .ctrl = true }, text_editor.KEY_ENTER));
    try std.testing.expectEqualStrings("ab", submitted());
    try std.testing.expectEqualStrings("", test_field.text());
}

test "a click in a multiline field lands on the line and column under the pointer" {
    var buf: [64]u8 = undefined;
    var field = Field{ .id = .{ .text = "m" }, .multiline = true, .font_size = .{ .px = 14 } };
    field.bindTo(&buf);
    field.setText("one\ntwo\nthree");
    const line_h = field.lineHeight();
    // The top-left corner is the first line's start.
    try std.testing.expectEqual(@as(usize, 0), field.caretOffsetAtPoint(0, 0));
    // Halfway down the second line at the left edge is its first byte.
    try std.testing.expectEqual(@as(usize, 4), field.caretOffsetAtPoint(0, line_h * 1.5));
    // Below the last line clamps to that line, not past the buffer.
    try std.testing.expectEqual(@as(usize, 8), field.caretOffsetAtPoint(0, line_h * 100));
    // Far right on the last line is its end.
    try std.testing.expectEqual(@as(usize, 13), field.caretOffsetAtPoint(500, line_h * 2.5));
}

// ---- clipboard: copy, cut and paste belong to the field, and a test supplies its own pasteboard ----

var clip_buf: [max_field_len]u8 = undefined;
var clip_len: usize = 0;

fn fakeClipRead(_: ?*anyopaque, buf: []u8) []const u8 {
    const n = @min(clip_len, buf.len);
    @memcpy(buf[0..n], clip_buf[0..n]);
    return buf[0..n];
}

fn fakeClipWrite(_: ?*anyopaque, text: []const u8) void {
    clip_len = @min(text.len, clip_buf.len);
    @memcpy(clip_buf[0..clip_len], text[0..clip_len]);
}

// A pasteboard that lives in this file, and starts empty.
fn fakeClipboard() Clipboard {
    clip_len = 0;
    return .{ .read_fn = fakeClipRead, .write_fn = fakeClipWrite };
}

fn selectRange(field: *Field, start: usize, end: usize) void {
    field.editor.caret = .{ .offset = end, .anchor = start };
}

test "Ctrl+C copies the selection, and Ctrl+V pastes it back as one edit" {
    try startField("hello world");
    test_field.clipboard = fakeClipboard();
    selectRange(&test_field, 0, 5);
    try std.testing.expect(dispatchKey(.{ .ctrl = true }, text_editor.KEY_C));
    try std.testing.expectEqualStrings("hello", clip_buf[0..clip_len]);
    // A copy leaves the draft exactly as it was.
    try std.testing.expectEqualStrings("hello world", test_field.text());
    try std.testing.expectEqual(@as(usize, 0), report_count);

    test_field.editor.setCaret(test_field.editor.len, false);
    try std.testing.expect(dispatchKey(.{ .ctrl = true }, text_editor.KEY_V));
    try std.testing.expectEqualStrings("hello worldhello", test_field.text());
    // One run, one report: not one per byte.
    try std.testing.expectEqual(@as(usize, 1), report_count);
    try std.testing.expectEqualStrings("hello worldhello", reported());
}

test "Ctrl+X moves the selection to the clipboard and out of the draft" {
    try startField("hello world");
    test_field.clipboard = fakeClipboard();
    selectRange(&test_field, 6, 11);
    try std.testing.expect(dispatchKey(.{ .ctrl = true }, text_editor.KEY_X));
    try std.testing.expectEqualStrings("world", clip_buf[0..clip_len]);
    try std.testing.expectEqualStrings("hello ", test_field.text());
    try std.testing.expectEqualStrings("hello ", reported());
}

test "Cmd+V pastes too, and replaces the selection it lands on" {
    try startField("abcdef");
    test_field.clipboard = fakeClipboard();
    // Seed the pasteboard the way a copy from another app would.
    fakeClipWrite(null, "XY");
    selectRange(&test_field, 2, 4);
    try std.testing.expect(dispatchKey(.{ .super = true }, text_editor.KEY_V));
    try std.testing.expectEqualStrings("abXYef", test_field.text());
}

test "a copy with nothing selected leaves the pasteboard alone" {
    try startField("abc");
    test_field.clipboard = fakeClipboard();
    fakeClipWrite(null, "kept");
    try std.testing.expect(!dispatchKey(.{ .ctrl = true }, text_editor.KEY_C));
    try std.testing.expectEqualStrings("kept", clip_buf[0..clip_len]);
    // Paste of an empty pasteboard is refused rather than inserting nothing.
    clip_len = 0;
    try std.testing.expect(!dispatchKey(.{ .ctrl = true }, text_editor.KEY_V));
    try std.testing.expectEqualStrings("abc", test_field.text());
}

test "a paste with newlines lands as lines, and copying across lines keeps them" {
    frame_mod.setTime(0, 0);
    try startField("");
    test_field.multiline = true;
    test_field.clipboard = fakeClipboard();
    fakeClipWrite(null, "one\ntwo");
    try std.testing.expect(dispatchKey(.{ .ctrl = true }, text_editor.KEY_V));
    try std.testing.expectEqualStrings("one\ntwo", test_field.text());
    try std.testing.expectEqual(@as(usize, 2), test_field.editor.lineCount());

    selectRange(&test_field, 0, 7);
    try std.testing.expect(dispatchKey(.{ .ctrl = true }, text_editor.KEY_C));
    try std.testing.expectEqualStrings("one\ntwo", clip_buf[0..clip_len]);
}

test "a value the caller changed replaces the draft, an unchanged one leaves it alone" {
    try startField("one");
    test_field.editor.setCaret(3, false);
    try std.testing.expect(dispatchText("!"));
    try std.testing.expectEqualStrings("one!", test_field.text());
    // The caller still declares "one": that is not a change, so the draft survives the next frame.
    _ = try layoutCommands(declareTestField);
    try std.testing.expectEqualStrings("one!", test_field.text());
    // The caller changed it: the model wins over the draft.
    test_field.value = "two";
    _ = try layoutCommands(declareTestField);
    try std.testing.expectEqualStrings("two", test_field.text());
}

test "an edit reports the new text; an arrow does not" {
    try startField("abc");
    test_field.editor.setCaret(3, false);
    try std.testing.expect(dispatchText("d"));
    try std.testing.expectEqual(@as(usize, 1), report_count);
    try std.testing.expectEqualStrings("abcd", reported());
    try std.testing.expect(dispatchKey(.{}, KEY_LEFT));
    try std.testing.expectEqual(@as(usize, 1), report_count);
}

test "Enter submits the draft, and a taken draft clears the field" {
    try startField("buy milk");
    try std.testing.expect(dispatchKey(.{}, text_editor.KEY_ENTER));
    try std.testing.expectEqualStrings("buy milk", submitted());
    try std.testing.expectEqualStrings("", test_field.text());
    // The clear is reported, so a controlled model empties with the field.
    try std.testing.expectEqualStrings("", reported());
    try std.testing.expectEqual(@as(usize, 1), report_count);
}

test "a refused submit leaves the draft where it was" {
    try startField("   ");
    submit_taken = false;
    try std.testing.expect(dispatchKey(.{}, text_editor.KEY_ENTER));
    try std.testing.expectEqualStrings("   ", test_field.text());
    try std.testing.expectEqual(@as(usize, 0), report_count);
}

test "with no field declared the engine consumes nothing" {
    beginFrame();
    try std.testing.expect(!dispatchText("a"));
    try std.testing.expect(!dispatchKey(.{}, KEY_A));
}

// ---- EditState: selection ----

test "selection normalizes anchor/caret order, null when caret-only" {
    try std.testing.expect(selection(.{}) == null);
    try std.testing.expect(selection(.{ .caret = 2, .anchor = 2 }) == null);
    const fwd = selection(.{ .caret = 3, .anchor = 1 }).?;
    try std.testing.expectEqual(@as(usize, 1), fwd.start);
    try std.testing.expectEqual(@as(usize, 3), fwd.end);
    const rev = selection(.{ .caret = 1, .anchor = 3 }).?;
    try std.testing.expectEqual(@as(usize, 1), rev.start);
    try std.testing.expectEqual(@as(usize, 3), rev.end);
    try std.testing.expect(hasSelection(.{ .caret = 1, .anchor = 3 }));
    try std.testing.expect(!hasSelection(.{ .caret = 1 }));
}

test "clampEdit keeps caret/anchor inside the buffer" {
    var st = EditState{ .caret = 9, .anchor = 7 };
    clampEdit(&st, 3);
    try std.testing.expectEqual(@as(usize, 3), st.caret);
    try std.testing.expectEqual(@as(usize, 3), st.anchor.?);
    try std.testing.expect(!hasSelection(st));
}

// ---- Arrows: move + Shift-select ----

test "arrows step and clamp at both ends" {
    var st = EditState{ .caret = 1 };
    moveLeft(&st, 3, false);
    try std.testing.expectEqual(@as(usize, 0), st.caret);
    moveLeft(&st, 3, false); // clamps
    try std.testing.expectEqual(@as(usize, 0), st.caret);
    moveRight(&st, 3, false);
    moveRight(&st, 3, false);
    moveRight(&st, 3, false);
    try std.testing.expectEqual(@as(usize, 3), st.caret);
    moveRight(&st, 3, false); // clamps
    try std.testing.expectEqual(@as(usize, 3), st.caret);
}

test "shift+arrows extend, moving back onto anchor clears" {
    var st = EditState{ .caret = 1 };
    moveRight(&st, 3, true);
    try std.testing.expectEqual(@as(usize, 2), st.caret);
    try std.testing.expectEqual(@as(usize, 1), st.anchor.?);
    moveLeft(&st, 3, true); // back onto anchor -> cleared
    try std.testing.expectEqual(@as(usize, 1), st.caret);
    try std.testing.expect(st.anchor == null);
    moveLeft(&st, 3, true);
    const sp = selection(st).?;
    try std.testing.expectEqual(@as(usize, 0), sp.start);
    try std.testing.expectEqual(@as(usize, 1), sp.end);
}

test "plain arrow collapses selection to the edge in its direction" {
    var left = EditState{ .caret = 3, .anchor = 1 };
    moveLeft(&left, 4, false);
    try std.testing.expectEqual(@as(usize, 1), left.caret);
    try std.testing.expect(left.anchor == null);
    var right = EditState{ .caret = 1, .anchor = 3 };
    moveRight(&right, 4, false);
    try std.testing.expectEqual(@as(usize, 3), right.caret);
    try std.testing.expect(right.anchor == null);
}

test "home/end jump, shift extends" {
    var st = EditState{ .caret = 2 };
    moveHome(&st, false);
    try std.testing.expectEqual(@as(usize, 0), st.caret);
    moveEnd(&st, 5, false);
    try std.testing.expectEqual(@as(usize, 5), st.caret);
    moveHome(&st, true);
    const sp = selection(st).?;
    try std.testing.expectEqual(@as(usize, 0), sp.start);
    try std.testing.expectEqual(@as(usize, 5), sp.end);
    try std.testing.expectEqual(@as(usize, 0), st.caret); // active end left
}

test "selectAll covers the buffer, empty selects nothing" {
    var st = EditState{};
    selectAll(&st, 4);
    const sp = selection(st).?;
    try std.testing.expectEqual(@as(usize, 0), sp.start);
    try std.testing.expectEqual(@as(usize, 4), sp.end);
    var empty = EditState{};
    selectAll(&empty, 0);
    try std.testing.expect(!hasSelection(empty));
}

// ---- Word jumps ----

test "ctrl+arrows jump whole words" {
    const buf = "foo bar-baz";
    const len = buf.len; // 11
    // From end: to start of "bar-baz" (dash splits words).
    try std.testing.expectEqual(@as(usize, 8), wordLeftEnd(buf, len, 11));
    try std.testing.expectEqual(@as(usize, 4), wordLeftEnd(buf, len, 8));
    try std.testing.expectEqual(@as(usize, 0), wordLeftEnd(buf, len, 4));
    try std.testing.expectEqual(@as(usize, 0), wordLeftEnd(buf, len, 0));
    // From start: to end of "foo", then end of "bar-baz".
    try std.testing.expectEqual(@as(usize, 4), wordRightEnd(buf, len, 0));
    try std.testing.expectEqual(@as(usize, 8), wordRightEnd(buf, len, 4));
    try std.testing.expectEqual(@as(usize, 11), wordRightEnd(buf, len, 8));
    try std.testing.expectEqual(@as(usize, 11), wordRightEnd(buf, len, 11));
}

test "ctrl+shift+arrows extend by word" {
    const buf = "foo bar";
    var st = EditState{ .caret = 7 };
    moveWordLeft(&st, buf, 7, true);
    const sp = selection(st).?;
    try std.testing.expectEqual(@as(usize, 4), sp.start);
    try std.testing.expectEqual(@as(usize, 7), sp.end);
}

// ---- insertAt / backspaceAt / deleteAt ----

fn fillBuf(buf: []u8, s: []const u8) usize {
    @memcpy(buf[0..s.len], s);
    return s.len;
}

test "insertAt writes at caret, shifting the tail" {
    var buf: [8]u8 = undefined;
    var len = fillBuf(&buf, "ac");
    var st = EditState{ .caret = 1 };
    try std.testing.expect(insertAt(&buf, &len, &st, 'b'));
    try std.testing.expectEqualStrings("abc", buf[0..len]);
    try std.testing.expectEqual(@as(usize, 2), st.caret);
}

test "insertAt replaces the selection (type-replaces)" {
    var buf: [8]u8 = undefined;
    var len = fillBuf(&buf, "abcd");
    var st = EditState{ .caret = 3, .anchor = 1 };
    try std.testing.expect(insertAt(&buf, &len, &st, 'X'));
    try std.testing.expectEqualStrings("aXd", buf[0..len]);
    try std.testing.expectEqual(@as(usize, 2), st.caret);
    try std.testing.expect(!hasSelection(st));
}

test "insertAt on a full buffer fails without growing" {
    var buf: [2]u8 = .{ 'a', 'b' };
    var len: usize = 2;
    var st = EditState{ .caret = 2 };
    try std.testing.expect(!insertAt(&buf, &len, &st, 'c'));
    try std.testing.expectEqual(@as(usize, 2), len);
}

test "backspaceAt deletes before caret, clamps at zero" {
    var buf: [8]u8 = undefined;
    var len = fillBuf(&buf, "abc");
    var st = EditState{ .caret = 2 };
    backspaceAt(&buf, &len, &st);
    try std.testing.expectEqualStrings("ac", buf[0..len]);
    try std.testing.expectEqual(@as(usize, 1), st.caret);
    st.caret = 0;
    backspaceAt(&buf, &len, &st); // no-op
    try std.testing.expectEqualStrings("ac", buf[0..len]);
}

test "backspaceAt and deleteAt remove the whole selection" {
    var buf: [8]u8 = undefined;
    var len = fillBuf(&buf, "abcd");
    var st = EditState{ .caret = 3, .anchor = 1 };
    backspaceAt(&buf, &len, &st);
    try std.testing.expectEqualStrings("ad", buf[0..len]);
    try std.testing.expectEqual(@as(usize, 1), st.caret);

    len = fillBuf(&buf, "abcd");
    st = .{ .caret = 1, .anchor = 3 };
    deleteAt(&buf, &len, &st);
    try std.testing.expectEqualStrings("ad", buf[0..len]);
    try std.testing.expectEqual(@as(usize, 1), st.caret);
}

test "deleteAt removes at caret, no-op at end" {
    var buf: [8]u8 = undefined;
    var len = fillBuf(&buf, "abc");
    var st = EditState{ .caret = 1 };
    deleteAt(&buf, &len, &st);
    try std.testing.expectEqualStrings("ac", buf[0..len]);
    try std.testing.expectEqual(@as(usize, 1), st.caret);
    st.caret = 2;
    deleteAt(&buf, &len, &st); // no-op
    try std.testing.expectEqualStrings("ac", buf[0..len]);
}

// ---- handleNavKey dispatch ----

test "handleNavKey routes arrows/home/end, ignores up/down/other" {
    const buf = "abcd";
    var st = EditState{ .caret = 2 };
    try std.testing.expect(handleNavKey(&st, buf, 4, KEY_LEFT, false, false));
    try std.testing.expectEqual(@as(usize, 1), st.caret);
    try std.testing.expect(handleNavKey(&st, buf, 4, KEY_RIGHT, true, false));
    try std.testing.expect(hasSelection(st));
    try std.testing.expect(handleNavKey(&st, buf, 4, KEY_HOME, false, false));
    try std.testing.expectEqual(@as(usize, 0), st.caret);
    try std.testing.expect(handleNavKey(&st, buf, 4, KEY_END, false, false));
    try std.testing.expectEqual(@as(usize, 4), st.caret);
    try std.testing.expect(!handleNavKey(&st, buf, 4, KEY_UP, false, false));
    try std.testing.expect(!handleNavKey(&st, buf, 4, KEY_DOWN, false, false));
    try std.testing.expect(!handleNavKey(&st, buf, 4, 30, false, false)); // 'a'
}

test "handleNavKey ctrl+arrows move by word" {
    const buf = "foo bar";
    var st = EditState{ .caret = 7 };
    try std.testing.expect(handleNavKey(&st, buf, 7, KEY_LEFT, false, true));
    try std.testing.expectEqual(@as(usize, 4), st.caret);
    try std.testing.expect(handleNavKey(&st, buf, 7, KEY_RIGHT, false, true));
    try std.testing.expectEqual(@as(usize, 7), st.caret);
}

test "Field selection color has a neutral default" {
    const p = Field{ .id = .{ .text = "x" } };
    try std.testing.expectEqual(Color.rgb(0x7a, 0xb8, 0xff), p.sel_fg);
}

// ---- Mods + handleKey: component owns the event state machine ----

test "Mods.track latches shift/ctrl, consumes only mods" {
    var m = Mods{};
    try std.testing.expect(m.track(42, true)); // left shift press
    try std.testing.expect(m.shift);
    try std.testing.expect(m.track(42, false));
    try std.testing.expect(!m.shift);
    try std.testing.expect(m.track(29, true)); // left ctrl press
    try std.testing.expect(m.ctrl);
    try std.testing.expect(m.track(97, false)); // right ctrl release
    try std.testing.expect(!m.ctrl);
    try std.testing.expect(!m.track(30, true)); // 'a' not consumed
    try std.testing.expect(!m.track(105, true)); // Left not consumed
}

test "handleKey ignores releases" {
    var buf: [8]u8 = undefined;
    var len = fillBuf(&buf, "ab");
    var st = EditState{ .caret = 2 };
    try std.testing.expectEqual(Action.ignored, handleKey(&buf, &len, &st, .{}, 30, false));
    try std.testing.expectEqualStrings("ab", buf[0..len]);
}

test "handleKey routes nav/edit/enter/printable per draft" {
    var buf: [8]u8 = undefined;
    var len = fillBuf(&buf, "abc");
    var st = EditState{ .caret = 3 };
    // Left moves caret.
    try std.testing.expectEqual(Action.edited, handleKey(&buf, &len, &st, .{}, KEY_LEFT, true));
    try std.testing.expectEqual(@as(usize, 2), st.caret);
    // Printable inserts at caret.
    try std.testing.expectEqual(Action.edited, handleKey(&buf, &len, &st, .{}, KEY_A, true));
    try std.testing.expectEqualStrings("abac", buf[0..len]);
    // Backspace removes before caret.
    try std.testing.expectEqual(Action.edited, handleKey(&buf, &len, &st, .{}, KEY_BACKSPACE, true));
    try std.testing.expectEqualStrings("abc", buf[0..len]);
    // Forward Delete removes at caret.
    st.caret = 1;
    try std.testing.expectEqual(Action.edited, handleKey(&buf, &len, &st, .{}, KEY_DELETE, true));
    try std.testing.expectEqualStrings("ac", buf[0..len]);
    // Enter confirms (business logic stays owner-side).
    try std.testing.expectEqual(Action.confirm, handleKey(&buf, &len, &st, .{}, KEY_ENTER, true));
    // Unknown key ignored.
    try std.testing.expectEqual(Action.ignored, handleKey(&buf, &len, &st, .{}, 59, true)); // F1
}

test "handleKey shift+arrow selects, typing replaces it" {
    var buf: [8]u8 = undefined;
    var len = fillBuf(&buf, "abc");
    var st = EditState{ .caret = 3 };
    try std.testing.expectEqual(Action.edited, handleKey(&buf, &len, &st, .{ .shift = true }, KEY_LEFT, true));
    try std.testing.expect(hasSelection(st));
    try std.testing.expectEqual(Action.edited, handleKey(&buf, &len, &st, .{}, KEY_A, true));
    try std.testing.expectEqualStrings("aba", buf[0..len]);
    try std.testing.expect(!hasSelection(st));
}

test "handleKey ctrl+A selects all, other ctrl combos insert nothing" {
    var buf: [8]u8 = undefined;
    var len = fillBuf(&buf, "abc");
    var st = EditState{ .caret = 1 };
    try std.testing.expectEqual(Action.edited, handleKey(&buf, &len, &st, .{ .ctrl = true }, KEY_A, true));
    const sp = selection(st).?;
    try std.testing.expectEqual(@as(usize, 0), sp.start);
    try std.testing.expectEqual(@as(usize, 3), sp.end);
    // Ctrl+C (evdev 46) must not type.
    try std.testing.expectEqual(Action.ignored, handleKey(&buf, &len, &st, .{ .ctrl = true }, 46, true));
    try std.testing.expectEqualStrings("abc", buf[0..len]);
}

var disabled_field: Field = .{ .id = .{ .text = "test-disabled-field" }, .value = "hi", .disabled = true };

fn declareDisabledField() void {
    textField(&disabled_field);
}

test "disabled field dims to disabled_bg" {
    const cmds = try layoutCommands(declareDisabledField);
    var found = false;
    for (cmds) |c| {
        if (c.command_type == .rectangle and c.id == cl.getElementId("test-disabled-field").id) {
            try std.testing.expectEqual(Color.rgb(0x1a, 0x1a, 0x1a).toClay(), c.render_data.rectangle.background_color);
            found = true;
        }
    }
    try std.testing.expect(found);
}

var border_field: Field = .{ .id = .{ .text = "test-border-field" }, .value = "hi", .border = .{ .width = .{ .px = 1 }, .color = Color.rgb(0xff, 0x00, 0x00) } };

fn declareBorderField() void {
    textField(&border_field);
}

test "field border emits a border command" {
    const cmds = try layoutCommands(declareBorderField);
    var borders: usize = 0;
    for (cmds) |c| if (c.command_type == .border) {
        borders += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), borders);
}

var placeholder_field: Field = .{ .id = .{ .text = "test-placeholder-field" }, .placeholder = "Filter requests", .placeholder_fg = Color.rgb(0x66, 0x66, 0x66) };

fn declarePlaceholderField() void {
    textField(&placeholder_field);
}

// The runs a layout drew, so a test can assert on the text and the tone it was drawn in.
fn drawnRun(cmds: []const cl.RenderCommand, want: []const u8) ?cl.TextRenderData {
    for (cmds) |c| {
        if (c.command_type != .text) continue;
        const run = c.render_data.text;
        const shown = run.string_contents.chars[0..@intCast(run.string_contents.length)];
        if (std.mem.eql(u8, shown, want)) return run;
    }
    return null;
}

test "an empty unfocused field draws its placeholder, and a draft replaces it" {
    // The suite shares the frame: a press or a focus another test left behind would take the keyboard on this field's first layout.
    frame_mod.ptr_down = false;
    frame_mod.setFocus(null);
    const hint = drawnRun(try layoutCommands(declarePlaceholderField), "Filter requests") orelse return error.PlaceholderMissing;
    try std.testing.expectEqual(Color.rgb(0x66, 0x66, 0x66).toClay(), hint.text_color);

    // Typing wins over the hint: with a draft the field draws the draft, never both.
    placeholder_field.setText("abc");
    const typed = try layoutCommands(declarePlaceholderField);
    try std.testing.expect(drawnRun(typed, "Filter requests") == null);
    try std.testing.expect(drawnRun(typed, "abc") != null);
}

var scroll_field: Field = .{
    .id = .{ .text = "test-scroll-field" },
    .multiline = true,
    .scroll_id = "test-scroll-box",
    .h = .{ .fixed = 200 },
};

fn declareScrollField(_: void) void {
    // Tall enough for its own lines, the way an app sizes a body editor; a fixed height would clip the content.
    const lines: f32 = @floatFromInt(scroll_field.editor.lineCount());
    scroll_field.h = .{ .fixed = @max(200, lines * scroll_field.lineHeight() + 12) };
    textField(&scroll_field);
}

fn declareScrollBox() void {
    scroll_mod.scroll(.{
        .id = .{ .text = "test-scroll-box" },
        .direction = .vertical,
        .w = .{ .fixed = 300 },
        .h = .{ .fixed = 100 },
    }, {}, declareScrollField);
}

test "a multiline field in a scroll keeps the caret's line in view" {
    scroll_field.bind();
    scroll_field.setText("1\n2\n3\n4\n5\n6\n7\n8\n9\n10");
    // The caret at the end is on line 9, five lines below the 100-point viewport.
    scroll_field.editor.setCaret(scroll_field.editor.len, false);
    frame_mod.ptr_down = false;
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
    frame_mod.setFocus("test-scroll-field");

    // Frames driven the way the Host drives one: declare, lay out, then apply the reveals the declare asked for.
    var pass: usize = 0;
    while (pass < 2) : (pass += 1) {
        cl.beginLayout();
        declareScrollBox();
        _ = cl.endLayout();
        scroll_mod.applyReveals();
    }
    try std.testing.expect(scroll_mod.view("test-scroll-box").y > 0);
    try std.testing.expectEqual(@as(usize, 9), scroll_field.caretLine());
}

test "a scrolled-away caret does not empty the window: the visible lines are still drawn" {
    scroll_field.bind();
    scroll_field.setText("0\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19");
    // The caret stays at the top while the hand scrolls to the bottom: the rows that cover the viewport must still be declared.
    scroll_field.editor.setCaret(0, false);
    frame_mod.ptr_down = false;
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
    frame_mod.setFocus("test-scroll-field");
    _ = layoutScrollBox();
    _ = layoutScrollBox();
    scroll_mod.scrollBy("test-scroll-box", 0, 10_000);
    const cmds = layoutScrollBox();
    const box = cl.getElementData(cl.getElementId("test-scroll-box")).bounding_box;
    var inside: usize = 0;
    for (cmds) |c| {
        if (c.command_type != .text) continue;
        const b = c.bounding_box;
        if (b.y + b.height > box.y and b.y < box.y + box.height) inside += 1;
    }
    try std.testing.expect(inside > 0);
}

test "a wheel scroll is not undone by the caret's reveal every frame" {
    scroll_field.bind();
    scroll_field.setText("1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20");
    // The caret stays on line 0, which is what a selection leaves behind while the hand scrolls away from it.
    scroll_field.editor.setCaret(0, false);
    frame_mod.ptr_down = false;
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
    frame_mod.setFocus("test-scroll-field");

    // Two frames: the caret's own reveal has already run, and no frame is left asking for it.
    _ = layoutScrollBox();
    _ = layoutScrollBox();
    try std.testing.expectEqual(@as(f32, 0), scroll_mod.view("test-scroll-box").y);

    // The wheel moves the box down; the caret has not moved, so nothing may pull it back.
    scroll_mod.scrollBy("test-scroll-box", 0, 60);
    _ = layoutScrollBox();
    try std.testing.expectApproxEqAbs(@as(f32, 60), scroll_mod.view("test-scroll-box").y, 1);
    _ = layoutScrollBox();
    try std.testing.expectApproxEqAbs(@as(f32, 60), scroll_mod.view("test-scroll-box").y, 1);

    // And a caret that DOES move still brings its line back into view.
    scroll_field.editor.setCaret(scroll_field.editor.len, false);
    _ = layoutScrollBox();
    _ = layoutScrollBox();
    try std.testing.expect(scroll_mod.view("test-scroll-box").y > 60);
}

test "a caret outside the viewport is not drawn: the clip of a scroll cannot cut a floating bar" {
    scroll_field.bind();
    scroll_field.setText("0\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19");
    scroll_field.editor.setCaret(0, false);
    frame_mod.ptr_down = false;
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
    frame_mod.setFocus("test-scroll-field");

    var pass: usize = 0;
    while (pass < 2) : (pass += 1) _ = layoutScrollBox();

    // Scrolled to the bottom by hand: line 0 is far above the viewport.
    scroll_mod.scrollBy("test-scroll-box", 0, 10_000);
    const scrolled = layoutScrollBox();
    try std.testing.expect(!hasCaret(scrolled, 0));

    // The caret moves to the last line; the reveal brings it back, and then it is drawn again.
    scroll_field.editor.setCaret(scroll_field.editor.len, false);
    _ = layoutScrollBox();
    _ = layoutScrollBox();
    try std.testing.expect(caretLineOnScreen(&scroll_field));

    // A field with no scroll has nothing off screen, so its caret is always drawn.
    try std.testing.expect(caretLineOnScreen(&blink_off_field));
}

// A field with no scroll: nothing can ever be off screen, so the caret is always drawn.
var blink_off_field: Field = .{ .id = .{ .text = "test-nos-croll-field" }, .multiline = true };

fn layoutScrollBox() []cl.RenderCommand {
    cl.beginLayout();
    declareScrollBox();
    const cmds = cl.endLayout();
    scroll_mod.applyReveals();
    return cmds;
}

fn hasCaret(cmds: []const cl.RenderCommand, line: usize) bool {
    const id = lineCaretId("test-scroll-field", line).id;
    for (cmds) |c| {
        if (c.command_type == .rectangle and c.id == id) return true;
    }
    return false;
}

// A selection is a highlight, not a resize: it must not move the glyphs it covers or grow the line they sit on.
var sel_field: Field = .{ .id = .{ .text = "test-sel-field" } };

fn declareSelField() void {
    textField(&sel_field);
}

fn firstTextRun(cmds: []const cl.RenderCommand) struct { y: f32, h: f32 } {
    for (cmds) |c| {
        if (c.command_type == .text) return .{ .y = c.bounding_box.y, .h = c.bounding_box.height };
    }
    return .{ .y = 0, .h = 0 };
}

fn hasRect(cmds: []const cl.RenderCommand, id: u32) bool {
    for (cmds) |c| {
        if (c.command_type == .rectangle and c.id == id) return true;
    }
    return false;
}

test "a selection highlights the text without moving it or resizing the field" {
    frame_mod.setTime(0, 0);
    frame_mod.resetFocus();
    frame_mod.ptr_down = false;
    beginFrame();
    sel_field = .{ .id = .{ .text = "test-sel-field" }, .value = "hello world", .w = .{ .fixed = 200 }, .h = .{ .fixed = 30 } };
    sel_field.bind();

    const plain = try layoutCommands(declareSelField);
    const field_a = cl.getElementData(cl.getElementId("test-sel-field")).bounding_box;
    const text_a = firstTextRun(plain);

    sel_field.editor.setCaret(0, false);
    sel_field.editor.setCaret(5, true);
    const marked = try layoutCommands(declareSelField);
    const field_b = cl.getElementData(cl.getElementId("test-sel-field")).bounding_box;
    const text_b = firstTextRun(marked);

    // The highlight is drawn, and the run under it sits exactly where it sat before the selection.
    try std.testing.expect(hasRect(marked, cl.ElementId.IDI("test-sel-field", 1).id));
    try std.testing.expectApproxEqAbs(text_a.y, text_b.y, 0.01);
    try std.testing.expectApproxEqAbs(text_a.h, text_b.h, 0.01);
    try std.testing.expectApproxEqAbs(field_a.height, field_b.height, 0.01);
}

test "a selection in a multiline field leaves every line row where it was" {
    frame_mod.setTime(0, 0);
    frame_mod.resetFocus();
    frame_mod.ptr_down = false;
    beginFrame();
    sel_field = .{
        .id = .{ .text = "test-sel-multi" },
        .value = "one\ntwo\nthree",
        .multiline = true,
        .w = .{ .fixed = 200 },
        .h = .{ .fixed = 90 },
    };
    sel_field.bind();

    _ = try layoutCommands(declareSelField);
    const row_a = cl.getElementData(lineBoxId("test-sel-multi", 0)).bounding_box;

    // The first line and the newline after it: the span runs into the second line.
    sel_field.editor.setCaret(0, false);
    sel_field.editor.setCaret(4, true);
    const marked = try layoutCommands(declareSelField);
    const row_b = cl.getElementData(lineBoxId("test-sel-multi", 0)).bounding_box;

    try std.testing.expect(hasRect(marked, cl.ElementId.IDI("test-sel-multi", lineSelIndex(0)).id));
    try std.testing.expectApproxEqAbs(row_a.y, row_b.y, 0.01);
    try std.testing.expectApproxEqAbs(row_a.height, row_b.height, 0.01);
}

// ---- the field's own context menu: Cut, Copy, Paste and Select All are mandatory, and an app's rows follow them ----

const menu_app_rows = [_][]const u8{ "Clear", "Copy as cURL" };
var menu_app_pick: struct { calls: usize = 0, index: usize = 0 } = .{};

fn onMenuAppRow(ctx: ?*anyopaque, index: usize) void {
    const c: *@TypeOf(menu_app_pick) = @ptrCast(@alignCast(ctx.?));
    c.calls += 1;
    c.index = index;
}

// One frame the way the Host drives it: the field, then the engine's card when one is up.
fn layoutWithCard() []cl.RenderCommand {
    registry.beginFrame();
    context_menu.beginFrame();
    cl.beginLayout();
    textField(&test_field);
    context_menu.declare();
    return cl.endLayout();
}

// A right click on the text raises the card, and the caret lands where the pointer did.
fn openFieldMenu() !void {
    return openFieldMenuAt(40);
}

fn openFieldMenuAt(from_left: f32) !void {
    const bb = cl.getElementData(cl.getElementId("test-field")).bounding_box;
    const x = bb.x + test_field.pad_lr.pts() + from_left;
    const y = bb.y + bb.height * 0.5;
    frame_mod.setPointer(x, y);
    try std.testing.expect(context_menu.secondaryClick(x, y, 720, 480));
    try std.testing.expect(context_menu.isOpen());
}

fn menuField(value: []const u8, readonly: bool) void {
    frame_mod.setTime(0, 0);
    frame_mod.resetFocus();
    frame_mod.ptr_down = false;
    beginFrame();
    menu_app_pick = .{};
    test_field = .{
        .id = .{ .text = "test-field" },
        .value = value,
        .readonly = readonly,
        .menu = .{ .items = &menu_app_rows, .on_select = .{ .f = onMenuAppRow, .ctx = &menu_app_pick } },
    };
    test_field.bind();
    test_field.clipboard = fakeClipboard();
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
}

test "a right click on a field offers Cut, Copy, Paste and Select All, then the app's own rows" {
    menuField("hello world", false);
    _ = layoutWithCard();
    _ = try openFieldMenu();
    // The caret followed the click in, so Copy has a field to copy from.
    try std.testing.expect(test_field.editor.caret.offset > 0);
    try std.testing.expect(frame_mod.isFocused("test-field"));

    // The card draws the field's four rows, then the app's, in that order.
    const cmds = layoutWithCard();
    for (menu_prefix) |label| try std.testing.expect(drawnRun(cmds, label) != null);
    try std.testing.expect(drawnRun(cmds, "Clear") != null);
    try std.testing.expect(drawnRun(cmds, "Copy as cURL") != null);

    // An app row reports the app's OWN index, so adding rows never shifts the field's four.
    const app_row = cl.getElementData(context_menu.rowId(menu_prefix.len)).bounding_box;
    try std.testing.expect(registry.dispatchClick(app_row.x + 4, app_row.y + 4));
    try std.testing.expectEqual(@as(usize, 1), menu_app_pick.calls);
    try std.testing.expectEqual(@as(usize, 0), menu_app_pick.index);
    try std.testing.expect(!context_menu.isOpen());
}

test "Select All, Copy and Paste work from the field's own menu rows" {
    menuField("hello world", false);
    _ = layoutWithCard();
    _ = try openFieldMenu();
    _ = layoutWithCard();
    // Select All is the field's fourth row.
    const all = cl.getElementData(context_menu.rowId(3)).bounding_box;
    try std.testing.expect(registry.dispatchClick(all.x + 4, all.y + 4));
    const span = test_field.editor.caret.selection() orelse return error.NoSelection;
    try std.testing.expectEqual(@as(usize, 0), span.start);
    try std.testing.expectEqual(@as(usize, 11), span.end);

    // Copy is the second row.
    _ = try openFieldMenu();
    _ = layoutWithCard();
    const copy = cl.getElementData(context_menu.rowId(1)).bounding_box;
    try std.testing.expect(registry.dispatchClick(copy.x + 4, copy.y + 4));
    try std.testing.expectEqualStrings("hello world", clip_buf[0..clip_len]);
    try std.testing.expectEqualStrings("hello world", test_field.text());

    // Paste is the third: right-clicked at the end of the line, it types the run back at the caret.
    test_field.editor.setCaret(test_field.editor.len, false);
    const width = cl.getElementData(cl.getElementId("test-field")).bounding_box.width;
    try openFieldMenuAt(width - 20);
    _ = layoutWithCard();
    const paste = cl.getElementData(context_menu.rowId(2)).bounding_box;
    try std.testing.expect(registry.dispatchClick(paste.x + 4, paste.y + 4));
    try std.testing.expectEqualStrings("hello worldhello world", test_field.text());
}

test "a read-only field still offers all four rows, and the two that would edit it do nothing" {
    menuField("abc", true);
    _ = layoutWithCard();
    _ = try openFieldMenu();
    const cmds = layoutWithCard();
    for (menu_prefix) |label| try std.testing.expect(drawnRun(cmds, label) != null);

    // Cut: the row is there, the click is swallowed by the card, and neither the text nor the pasteboard changes.
    const cut = cl.getElementData(context_menu.rowId(0)).bounding_box;
    try std.testing.expect(registry.dispatchClick(cut.x + 4, cut.y + 4));
    try std.testing.expectEqualStrings("abc", test_field.text());
    try std.testing.expectEqual(@as(usize, 0), clip_len);

    // Paste: same, so a response body can never be typed into from its menu.
    _ = try openFieldMenu();
    _ = layoutWithCard();
    const paste = cl.getElementData(context_menu.rowId(2)).bounding_box;
    try std.testing.expect(registry.dispatchClick(paste.x + 4, paste.y + 4));
    try std.testing.expectEqualStrings("abc", test_field.text());
    try std.testing.expect(!context_menu.isOpen());
}

var caret_field: Field = .{ .id = .{ .text = "test-caret-field" }, .w = .{ .fixed = 320 } };

fn declareCaretField() void {
    textField(&caret_field);
}

test "a single-line caret sits on the glyph boundary, with the field's padding counted once" {
    caret_field.bind();
    caret_field.setText("sss");
    caret_field.editor.setCaret(3, false);
    frame_mod.ptr_down = false;
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
    frame_mod.setFocus("test-caret-field");
    cl.beginLayout();
    declareCaretField();
    _ = cl.endLayout();

    const box = frame_mod.bounds(caret_field.id.clay()) orelse return error.FieldMissing;
    const caret = frame_mod.bounds(.IDI("test-caret-field", 2)) orelse return error.CaretMissing;
    const advance = caret_field.measure("sss", caret_field.font_size.whole());
    // The text starts at the field's padding, and the caret at the end of the run: the gap after "sss" is nothing.
    try std.testing.expectApproxEqAbs(box.x + caret_field.pad.left.pts() + advance, caret.x, 1.5);

    // One more glyph moves the bar by exactly one advance, so the gap cannot grow with the text.
    caret_field.setText("ssss");
    caret_field.editor.setCaret(4, false);
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
    frame_mod.setFocus("test-caret-field");
    cl.beginLayout();
    declareCaretField();
    _ = cl.endLayout();
    const longer = frame_mod.bounds(.IDI("test-caret-field", 2)) orelse return error.CaretMissing;
    try std.testing.expectApproxEqAbs(caret_field.measure("s", caret_field.font_size.whole()), longer.x - caret.x, 1.5);
}

var scrolled_field: Field = .{ .id = .{ .text = "test-scrolled-field" }, .w = .{ .fixed = 120 } };

fn declareScrolledField() void {
    textField(&scrolled_field);
}

test "a scrolled single-line caret slides with the text, and the scroll is counted once" {
    scrolled_field.bind();
    scrolled_field.setText(long_value);
    scrolled_field.editor.setCaret(scrolled_field.editor.len, false);
    // The scroll the field would settle on for a caret at the end of a run wider than it is.
    scrolled_field.h_scroll = 100;
    frame_mod.ptr_down = false;
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
    frame_mod.setFocus("test-scrolled-field");
    cl.beginLayout();
    declareScrolledField();
    _ = cl.endLayout();

    const box = frame_mod.bounds(scrolled_field.id.clay()) orelse return error.FieldMissing;
    const caret = frame_mod.bounds(.IDI("test-scrolled-field", 2)) orelse return error.CaretMissing;
    const advance = scrolled_field.measure(long_value, scrolled_field.font_size.whole());
    try std.testing.expectApproxEqAbs(box.x + scrolled_field.pad.left.pts() + advance - scrolled_field.h_scroll, caret.x, 1.5);
}

var shrink_field: Field = .{ .id = .{ .text = "test-shrink-field" }, .w = .{ .fixed = 200 } };

fn declareShrinkField() void {
    textField(&shrink_field);
}

test "a draft the model shortens in place cannot leave the caret past its end" {
    shrink_field.bind();
    shrink_field.setText("sssss");
    shrink_field.editor.setCaret(5, false);
    // A selection that reached the end, then a shorter run written into the same buffer.
    shrink_field.editor.caret.anchor = 1;
    shrink_field.editor.len = 2;
    frame_mod.ptr_down = false;
    headless.begin(.{ .x = 99999, .y = 99999 }, false);
    frame_mod.setFocus("test-shrink-field");
    cl.beginLayout();
    declareShrinkField();
    _ = cl.endLayout();
    try std.testing.expect(shrink_field.editor.caret.offset <= shrink_field.editor.len);
    try std.testing.expect((shrink_field.editor.caret.anchor orelse 0) <= shrink_field.editor.len);
}
