// Agnostic reusable Clay text field (toolkit-style, library only).
const std = @import("std");
const cl = @import("zclay");
const Color = @import("../color.zig").Color;
const registry = @import("click_registry.zig");
const caret_mod = @import("caret.zig");
const frame_mod = @import("../frame.zig");
const text_editor = @import("../text_editor.zig");
const text_backend = @import("../text_backend.zig");
const semantics = @import("../semantics.zig");

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
    // Ctrl held: only Ctrl+A selects; every other Ctrl combo inserts nothing (no clipboard in this environment — never garbage-type).
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

// Toolkit-style field props.
pub const FieldProps = struct {
    id: []const u8,
    font_size: u16 = 14,
    fg: Color = Color.rgb(0xe8, 0xe8, 0xe8),
    bg: Color = Color.rgb(0x26, 0x26, 0x26),
    // Selected-run text color for fieldEdit (text runs carry color only, no per-run bg at this renderer's fidelity).
    sel_fg: Color = Color.rgb(0x7a, 0xb8, 0xff),
    // The selection's background, used by `liveField`.
    sel_bg: Color = Color.rgb(0x2d, 0x3a, 0x52),
    // The caret's colour, or the text colour when null. A caret that matches the text merges with the glyph it touches and reads as a broken character,

    // which is why this is a prop.
    caret_fg: ?Color = null,
    radius: u32 = 4,
    pad_tb: u16 = 8,
    pad_lr: u16 = 12,
    // Fixed size overrides (null = grow width / fit height defaults).
    w: ?f32 = null,
    h: ?f32 = null,
    // Min/max clamps for the grow/fit axes (0 = no constraint).
    min_w: f32 = 0,
    max_w: f32 = 0,
    min_h: f32 = 0,
    max_h: f32 = 0,
    border_width: u16 = 0,
    border_color: Color = Color.rgb(0x00, 0x00, 0x00),
    disabled: bool = false,
    disabled_bg: Color = Color.rgb(0x1a, 0x1a, 0x1a),
    disabled_fg: Color = Color.rgb(0x77, 0x77, 0x77),
};

fn fieldSizingW(props: FieldProps) cl.SizingAxis {
    if (props.w) |v| return .fixed(v);
    if (props.min_w > 0 or props.max_w > 0) return .growMinMax(.{ .min = props.min_w, .max = props.max_w });
    return .grow;
}

fn fieldSizingH(props: FieldProps) cl.SizingAxis {
    if (props.h) |v| return .fixed(v);
    if (props.min_h > 0 or props.max_h > 0) return .fitMinMax(.{ .min = props.min_h, .max = props.max_h });
    return .fit;
}

fn fieldBorder(props: FieldProps) cl.BorderElementConfig {
    if (props.border_width == 0) return .{};
    return .{ .color = props.border_color.toClay(), .width = .outside(props.border_width) };
}

// Declare a text field: prompt + query + block cursor on the field bg.
pub fn field(props: FieldProps, query: []const u8) void {
    const bg: Color = if (props.disabled) props.disabled_bg else props.bg;
    const fg: Color = if (props.disabled) props.disabled_fg else props.fg;
    cl.UI()(.{
        .id = .ID(props.id),
        .layout = .{
            .direction = .left_to_right,
            .sizing = .{ .w = fieldSizingW(props), .h = fieldSizingH(props) },
            .padding = .axes(props.pad_tb, props.pad_lr),
            .child_alignment = .{ .x = .left, .y = .center },
            .child_gap = 0,
        },
        .background_color = bg.toClay(),
        .corner_radius = .all(@floatFromInt(props.radius)),
        .border = fieldBorder(props),
    })({
        const fg_c = fg.toClay();
        cl.text(">", .{
            .font_size = props.font_size,
            .color = fg_c,
        });
        cl.text(" ", .{
            .font_size = props.font_size,
            .color = fg_c,
        });
        if (query.len > 0) {
            cl.text(query, .{
                .font_size = props.font_size,
                .color = fg_c,
            });
        }
        cl.text("_", .{
            .font_size = props.font_size,
            .color = fg_c,
        });
    });
    // Semantics: an editable field declares `set_text`, so `Interaction.performTextInput` can refuse to type into a non-editable node and.
    if (!props.disabled and props.id.len > 0) {
        semantics.register(.{
            .id = cl.getElementId(props.id),
            .tag = props.id,
            .role = .text_field,
            .value = query,
            .flags = .{ .enabled = true },
            .actions = .{ .set_text = true },
        });
        registry.registerHover(cl.getElementId(props.id), .text);
    }
}

// Declare a text field with HTML-like caret + selection: prompt, then the query split around the caret (before / "|" / after), with the selected span.
pub const FieldCtx = struct {
    // The draft, owned here: a field that only DRAWS takes a `[]const u8`, and this one is the field an app types into.
    buf: [max_field_len]u8 = undefined,
    editor: text_editor.Editor = .{ .buf = &.{} },
    id: []const u8 = "",
    // Measures a run with the font that draws the field. The engine's text backend is that font.
    measure: *const fn ([]const u8, u16) f32 = text_backend.runWidth,
    // Left padding of the field, written by `liveField` each frame so a click and the caret share one origin.
    pad_lr: f32 = 8,
    // The field's font size, written by `liveField` each frame, for the same reason.
    font_size: u16 = 14,
    // Called after a click places the caret, so the app can take focus.
    on_focus: ?*const fn (?*anyopaque) void = null,
    focus_ctx: ?*anyopaque = null,
    // True while this field owns a drag in flight; the field ticks it, so the app never has to.
    dragging: bool = false,
    bound: bool = false,

    // Point the editor at this field's own buffer, once, after the FieldCtx is where it will stay.
    pub fn bind(self: *FieldCtx) void {
        if (self.bound) return;
        self.editor = text_editor.Editor.init(&self.buf);
        self.bound = true;
    }
};

// How much draft a field owns. A single-line input is not a document; an app that needs more uses `liveField` with its own editor.
pub const max_field_len: usize = 256;

// Anchor the caret on the press, extend it while the button stays down, and release the drag when it comes up.
fn dragSelect(ctx: *FieldCtx, id: []const u8) void {
    if (!frame_mod.ptr_down) {
        ctx.dragging = false;
        return;
    }
    const data = cl.getElementData(cl.getElementId(id));
    if (!data.found) return;
    const bb = data.bounding_box;
    // Only a press that BEGAN inside the field may take the caret, so a drag that wanders in from elsewhere does not steal it.
    const began_here = frame_mod.ptr_press_x >= bb.x and frame_mod.ptr_press_x <= bb.x + bb.width and
        frame_mod.ptr_press_y >= bb.y and frame_mod.ptr_press_y <= bb.y + bb.height;
    if (!ctx.dragging and !began_here) return;
    // `extend` is false on the anchoring frame (place the caret) and true after it (grow the selection from that anchor).
    const x = frame_mod.ptr_x - bb.x - ctx.pad_lr;
    ctx.editor.setCaret(text_editor.offsetAtX(ctx.editor.text(), x, ctx.font_size, ctx.measure), ctx.dragging);
    if (!ctx.dragging) {
        ctx.dragging = true;
        frame_mod.setFocus(ctx.id);
        if (ctx.on_focus) |f| f(ctx.focus_ctx);
    }
}

// A live text field: selection highlight, a blinking caret, and a click that places the caret.
pub fn liveField(props: FieldProps, ctx: *FieldCtx) void {
    ctx.bind();
    const input = &ctx.editor;
    // The click and drag handlers need the same origin and metrics the text is drawn with.
    ctx.pad_lr = @floatFromInt(props.pad_lr);
    ctx.font_size = props.font_size;
    // Drag-select first, so the caret and the selection this frame draws are the ones the pointer just asked for.
    dragSelect(ctx, props.id);
    const text = input.text();
    // Once a click has claimed the keyboard, the toolkit decides who owns it: clicking another component blurs this field.
    if (frame_mod.focusKnown()) input.focused = frame_mod.isFocused(props.id);
    // The field owns its own animation, and only while it is focused: an unfocused field holds its clock at zero and draws no caret.
    input.tickBlink(frame_mod.delta_s);
    const fg = (if (props.disabled) props.disabled_fg else props.fg).toClay();
    // Solid for half a second after the caret moves, then blinking: a caret that blinks while you type is a caret you cannot find.
    const blink_on = text_editor.caretVisible(input);

    cl.UI()(.{
        .id = .ID(props.id),
        .layout = .{
            .direction = .left_to_right,
            .sizing = .{ .w = fieldSizingW(props), .h = fieldSizingH(props) },
            .padding = .axes(props.pad_tb, props.pad_lr),
            .child_alignment = .{ .x = .left, .y = .center },
            .child_gap = 0,
        },
        .background_color = (if (props.disabled) props.disabled_bg else props.bg).toClay(),
        .corner_radius = .all(@floatFromInt(props.radius)),
        .border = fieldBorder(props),
    })({
        if (input.caret.hasSelection()) {
            const span = input.caret.selection().?;
            const s = span.start;
            const e = span.end;
            if (s > 0) cl.text(text[0..s], .{ .font_size = props.font_size, .color = fg });
            cl.UI()(.{
                .id = .IDI(props.id, 1),
                .layout = .{
                    .sizing = .{ .w = .fit, .h = .grow },
                    .padding = .{ .top = 1, .bottom = 1 },
                },
                .background_color = props.sel_bg.toClay(),
            })({
                cl.text(text[s..e], .{ .font_size = props.font_size, .color = props.sel_fg.toClay() });
            });
            if (e < text.len) cl.text(text[e..], .{ .font_size = props.font_size, .color = fg });
        } else {
            // One run for the whole value, with the caret floated over it. A caret in the flow takes a pixel of the text, so the tail of the value shifted every

            // time it moved and it sat flush against the next glyph.
            cl.text(text, .{ .font_size = props.font_size, .color = fg });
            if (blink_on) caretBar(props, ctx, text);
        }
    });

    registry.registerClickDoubleCursor(cl.getElementId(props.id), onFieldClick, onFieldDoubleClick, ctx, .text);
}

// Select the word under a double click, which is what every text field does.
fn onFieldDoubleClick(ctx: ?*anyopaque) void {
    const c: *FieldCtx = @ptrCast(@alignCast(ctx.?));
    const data = cl.getElementData(cl.getElementId(c.id));
    if (!data.found) return;
    const x = frame_mod.ptr_x - data.bounding_box.x - c.pad_lr;
    text_editor.selectWordAt(&c.editor, text_editor.offsetAtX(c.editor.text(), x, c.font_size, c.measure));
    c.editor.idle = 0;
    frame_mod.setFocus(c.id);
    if (c.on_focus) |f| f(c.focus_ctx);
}

// The caret, floated at the measured end of the run before it. The primitive snaps it and makes it one device pixel.
fn caretBar(props: FieldProps, ctx: *FieldCtx, text: []const u8) void {
    const at = @min(ctx.editor.caret.offset, text.len);
    caret_mod.declare(.{
        // The padding is part of the parent box, so the offset starts from the border box, not the text.
        .id = .IDI(props.id, 2),
        .x = @as(f32, @floatFromInt(props.pad_lr)) + ctx.measure(text[0..at], props.font_size),
        .height = @floatFromInt(props.font_size + 4),
        .color = props.caret_fg orelse Color.rgb(0xd8, 0xd8, 0xdc),
        .anchor = .center,
    });
}

// Place the caret from a click, using the field's own box and the frame's pointer.
fn onFieldClick(ctx: ?*anyopaque) void {
    const c: *FieldCtx = @ptrCast(@alignCast(ctx.?));
    const data = cl.getElementData(cl.getElementId(c.id));
    if (!data.found) return;
    const x = frame_mod.ptr_x - data.bounding_box.x - c.pad_lr;
    c.editor.setCaret(text_editor.offsetAtX(c.editor.text(), x, c.font_size, c.measure), false);
    c.editor.idle = 0;
    frame_mod.setFocus(c.id);
    if (c.on_focus) |f| f(c.focus_ctx);
}

pub fn fieldEdit(props: FieldProps, query: []const u8, st: EditState) void {
    var s = st;
    clampEdit(&s, query.len);
    const fg = (if (props.disabled) props.disabled_fg else props.fg).toClay();
    const sel_fg = (if (props.disabled) props.disabled_fg else props.sel_fg).toClay();
    cl.UI()(.{
        .id = .ID(props.id),
        .layout = .{
            .direction = .left_to_right,
            .sizing = .{ .w = fieldSizingW(props), .h = fieldSizingH(props) },
            .padding = .axes(props.pad_tb, props.pad_lr),
            .child_alignment = .{ .x = .left, .y = .center },
            .child_gap = 0,
        },
        .background_color = (if (props.disabled) props.disabled_bg else props.bg).toClay(),
        .corner_radius = .all(@floatFromInt(props.radius)),
        .border = fieldBorder(props),
    })({
        cl.text(">", .{ .font_size = props.font_size, .color = fg });
        cl.text(" ", .{ .font_size = props.font_size, .color = fg });
        if (selection(s)) |sp| {
            if (sp.start > 0) {
                cl.text(query[0..sp.start], .{ .font_size = props.font_size, .color = fg });
            }
            if (s.caret == sp.start) {
                cl.text("|", .{ .font_size = props.font_size, .color = fg });
            }
            cl.text(query[sp.start..sp.end], .{ .font_size = props.font_size, .color = sel_fg });
            if (s.caret == sp.end) {
                cl.text("|", .{ .font_size = props.font_size, .color = fg });
            }
            if (sp.end < query.len) {
                cl.text(query[sp.end..], .{ .font_size = props.font_size, .color = fg });
            }
        } else {
            if (s.caret > 0) {
                cl.text(query[0..s.caret], .{ .font_size = props.font_size, .color = fg });
            }
            cl.text("|", .{ .font_size = props.font_size, .color = fg });
            if (s.caret < query.len) {
                cl.text(query[s.caret..], .{ .font_size = props.font_size, .color = fg });
            }
        }
    });
    // Same contract as field(): editable, so it declares set_text.
    if (!props.disabled and props.id.len > 0) {
        semantics.register(.{
            .id = cl.getElementId(props.id),
            .tag = props.id,
            .role = .text_field,
            .value = query,
            .flags = .{ .enabled = true },
            .actions = .{ .set_text = true },
        });
        registry.registerHover(cl.getElementId(props.id), .text);
    }
}

// Stub text estimator for headless tests (no font backend needed).
fn stubMeasure(s: []const u8, cfg: *cl.TextElementConfig, _: void) cl.Dimensions {
    return .{
        .w = @as(f32, @floatFromInt(s.len)) * @as(f32, @floatFromInt(cfg.font_size)) * 0.6,
        .h = @as(f32, @floatFromInt(cfg.font_size)),
    };
}

fn layoutCommands(declare_fn: *const fn () void) ![]cl.RenderCommand {
    const mem_size = cl.minMemorySize();
    // NOTE: intentionally leaked (page_allocator, never freed).
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declare_fn();
    return cl.endLayout();
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

test "FieldProps carries neutral dark defaults" {
    const p = FieldProps{ .id = "x" };
    try std.testing.expectEqual(@as(u16, 14), p.font_size);
    try std.testing.expectEqual(Color.rgb(0xe8, 0xe8, 0xe8), p.fg);
    try std.testing.expectEqual(Color.rgb(0x26, 0x26, 0x26), p.bg);
    try std.testing.expectEqual(@as(u32, 4), p.radius);
}

fn declareField() void {
    field(.{ .id = "test-field" }, "jak");
}

fn declareEmptyField() void {
    field(.{ .id = "test-empty-field" }, "");
}

fn countTexts(declare_fn: *const fn () void) !usize {
    const cmds = try layoutCommands(declare_fn);
    var t: usize = 0;
    for (cmds) |c| switch (c.command_type) {
        .text => t += 1,
        else => {},
    };
    return t;
}

test "field renders prompt, query and cursor texts" {
    // ">", " ", "jak", "_" — 4 text commands.
    try std.testing.expectEqual(@as(usize, 4), try countTexts(declareField));
    // Empty query skips the query text: ">", " ", "_".
    try std.testing.expectEqual(@as(usize, 3), try countTexts(declareEmptyField));
}

test "field declares a stable id for hit-testing" {
    _ = try layoutCommands(declareField);
    try std.testing.expect(cl.getElementData(cl.getElementId("test-field")).found);
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

// ---- fieldEdit render ----

fn declareCaretMid() void {
    fieldEdit(.{ .id = "test-caret-mid" }, "jak", .{ .caret = 1 });
}

fn declareCaretSel() void {
    fieldEdit(.{ .id = "test-caret-sel" }, "jak", .{ .caret = 3, .anchor = 1 });
}

fn declareCaretEmpty() void {
    fieldEdit(.{ .id = "test-caret-empty" }, "", .{});
}

test "fieldEdit splits runs around the caret" {
    // ">", " ", "j", "|", "ak" — 5 text commands.
    try std.testing.expectEqual(@as(usize, 5), try countTexts(declareCaretMid));
    // ">", " ", "j", "ak"(sel), "|" — 5 text commands.
    try std.testing.expectEqual(@as(usize, 5), try countTexts(declareCaretSel));
    // ">", " ", "|" — 3 text commands.
    try std.testing.expectEqual(@as(usize, 3), try countTexts(declareCaretEmpty));
}

test "fieldEdit declares a stable id for hit-testing" {
    _ = try layoutCommands(declareCaretMid);
    try std.testing.expect(cl.getElementData(cl.getElementId("test-caret-mid")).found);
}

test "FieldProps selection color has a neutral default" {
    const p = FieldProps{ .id = "x" };
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

fn declareDisabledField() void {
    field(.{ .id = "test-disabled-field", .disabled = true }, "hi");
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

fn declareBorderField() void {
    field(.{ .id = "test-border-field", .border_width = 1, .border_color = Color.rgb(0xff, 0x00, 0x00) }, "hi");
}

test "field border emits a border command" {
    const cmds = try layoutCommands(declareBorderField);
    var borders: usize = 0;
    for (cmds) |c| if (c.command_type == .border) {
        borders += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), borders);
}
