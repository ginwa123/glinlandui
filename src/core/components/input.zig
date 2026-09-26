// Agnostic reusable Clay text field (toolkit-style, library only).
// Single-line ASCII input: prompt + query + block cursor, on a distinct
// background so it reads as a field; optional Clay BORDER chrome
// (border_width/color) is drawn by the GLES3 renderer — see renderer.zig.
// Imports: std + zclay + core/render_common ONLY.
// Never: app/theme/layout/views/content/sidebar.
const std = @import("std");
const cl = @import("zclay");
const render = @import("../render_common.zig");
const registry = @import("click_registry.zig");
const semantics = @import("../semantics.zig");

/// Raw evdev keycode → printable ASCII under the US layout.
/// Returns null for non-printables (Escape/Backspace/Enter/Shift are
/// handled by the owner, not here). Covers letters, digits + shifted
/// symbols, space and the punctuation in timezones/formats (/, -, _,
/// :, ., ,, ;).
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

/// Append a char to a caller-owned draft buffer. Returns false when
/// full (input ignored). Buffers stay owner-side (Shell state); this
/// never allocates.
pub fn insert(buf: []u8, len: *usize, c: u8) bool {
    if (len.* >= buf.len) return false;
    buf[len.*] = c;
    len.* += 1;
    return true;
}

/// Drop the last byte (keymap is ASCII-only, so byte == char).
pub fn backspace(len: *usize) void {
    if (len.* > 0) len.* -= 1;
}

// ---- HTML-like caret + keyboard selection (single-line, ASCII) ----
//
// The field used to be append-only (caret pinned at end). EditState adds
// an owner-held caret + Shift anchor per draft buffer so arrows move,
// Shift+arrows select, Home/End jump, Ctrl+arrows jump words, typing
// replaces the selection and Backspace/Delete remove it — like an HTML
// <input>. All ops are pure over caller buffers (never allocate) and
// clamp defensively, so Shell can hold one state per draft and pass it
// to fieldEdit() for rendering.

/// Raw evdev codes for navigation (observed live: no +8 offset).
pub const KEY_LEFT: u32 = 105;
pub const KEY_RIGHT: u32 = 106;
pub const KEY_UP: u32 = 103;
pub const KEY_DOWN: u32 = 108;
pub const KEY_HOME: u32 = 102;
pub const KEY_END: u32 = 107;
pub const KEY_DELETE: u32 = 111;
pub const KEY_BACKSPACE: u32 = 14;

/// Caret + keyboard-selection state (owner-held, one per draft buffer).
/// `caret` is the active end (byte offset, 0..len); `anchor` is the
/// fixed end while Shift is held (null = caret only, no selection).
pub const EditState = struct {
    caret: usize = 0,
    anchor: ?usize = null,
};

/// Normalized selection span (start < end), or null when caret-only.
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

/// Clamp caret/anchor into 0..len (call after external len edits).
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

/// Arrow left: with an active selection and no Shift, collapses to the
/// selection start (HTML); otherwise steps one byte left.
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

/// Arrow right: mirror of moveLeft (collapses to selection end).
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

/// Ctrl+A: select the whole buffer (empty buffer selects nothing).
pub fn selectAll(st: *EditState, len: usize) void {
    clampEdit(st, len);
    st.caret = len;
    st.anchor = if (len > 0) 0 else null;
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Ctrl+Left target: skip non-word bytes leftward, then word bytes.
pub fn wordLeftEnd(buf: []const u8, len: usize, caret: usize) usize {
    var c = @min(caret, len);
    while (c > 0 and !isWordChar(buf[c - 1])) : (c -= 1) {}
    while (c > 0 and isWordChar(buf[c - 1])) : (c -= 1) {}
    return c;
}

/// Ctrl+Right target: skip word bytes rightward, then non-word bytes
/// (lands at the end of the current/next word, like browsers).
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

/// Delete span [start,end), shifting the tail left. Returns the new len.
fn deleteSpan(buf: []u8, len: usize, start: usize, end: usize) usize {
    std.debug.assert(start <= end and end <= len);
    std.mem.copyForwards(u8, buf[start .. len - (end - start)], buf[end..len]);
    return len - (end - start);
}

/// Type a char: replaces the selection when present, else inserts at
/// the caret. Returns false when the buffer is full (state untouched
/// apart from a cleared selection — same as browsers dropping the key).
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

/// Backspace: deletes the selection when present, else the byte before
/// the caret (no-op at 0).
pub fn backspaceAt(buf: []u8, len: *usize, st: *EditState) void {
    if (selection(st.*)) |sp| {
        len.* = deleteSpan(buf, len.*, sp.start, sp.end);
        st.caret = sp.start;
        st.anchor = null;
        return;
    }
    clampEdit(st, len.*);
    if (st.caret == 0) return;
    len.* = deleteSpan(buf, len.*, st.caret - 1, st.caret);
    st.caret -= 1;
}

/// Forward Delete: deletes the selection when present, else the byte at
/// the caret (no-op at end).
pub fn deleteAt(buf: []u8, len: *usize, st: *EditState) void {
    if (selection(st.*)) |sp| {
        len.* = deleteSpan(buf, len.*, sp.start, sp.end);
        st.caret = sp.start;
        st.anchor = null;
        return;
    }
    clampEdit(st, len.*);
    if (st.caret >= len.*) return;
    len.* = deleteSpan(buf, len.*, st.caret, st.caret + 1);
}

/// Arrow/Home/End dispatch for a single-line field (Up/Down ignored).
/// `ctrl` makes Left/Right word-wise. Returns true when consumed.
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

// ---- Key-event state machine (component owns interpretation) ----
//
// Why this lives here instead of views.zig: the Wayland loop delivers
// raw evdev to the Host delegate (only ui knows drafts/views), but
// *interpreting* the event — mod latch, nav vs edit vs confirm — needs
// no AppState, so it belongs to the component. The owner feeds every
// key event to Mods.track first, then to handleKey per active draft,
// and switches on the Action for business logic only (Enter = apply or
// pick-first). Views keep routing + meaning, never keycode tables.

/// Modifier latch: one per window (a single keyboard). Consumes
/// Shift (42/54) and Ctrl (29/97) press + release.
pub const Mods = struct {
    shift: bool = false,
    ctrl: bool = false,

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
            else => return false,
        }
    }
};

/// What a key event means for the draft. `.confirm` (Enter) is the only
/// action with business meaning; `.edited` needs nothing (declare reads
/// the draft); `.ignored` falls through to the owner.
pub const Action = enum { ignored, edited, confirm };

pub const KEY_ENTER: u32 = 28;
pub const KEY_A: u32 = 30;

/// Full key handling for one draft buffer: arrows/Home/End (via
/// handleNavKey), Backspace/Delete-at-caret, Ctrl+A select-all, Enter,
/// printables. Releases are ignored (the owner must route them to
/// Mods.track first). Never allocates; clamps defensively.
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
    // Ctrl held: only Ctrl+A selects; every other Ctrl combo inserts
    // nothing (no clipboard in this environment — never garbage-type).
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

/// Toolkit-style field props. All styling via props with neutral dark
/// defaults — no theme/app imports. `id` becomes the Clay element ID
/// (stable across frames for hit-testing).
pub const FieldProps = struct {
    id: []const u8,
    font_size: u16 = 14,
    fg: u32 = 0xe8e8e8,
    bg: u32 = 0x262626,
    /// Selected-run text color for fieldEdit (text runs carry color only,
    /// no per-run bg at this renderer's fidelity).
    sel_fg: u32 = 0x7ab8ff,
    radius: u32 = 4,
    pad_tb: u16 = 8,
    pad_lr: u16 = 12,
    /// Fixed size overrides (null = grow width / fit height defaults).
    /// `w` fixes the width axis, `h` fixes the height axis.
    w: ?f32 = null,
    h: ?f32 = null,
    /// Min/max clamps for the grow/fit axes (0 = no constraint).
    min_w: f32 = 0,
    max_w: f32 = 0,
    min_h: f32 = 0,
    max_h: f32 = 0,
    border_width: u16 = 0,
    border_color: u32 = 0x000000,
    disabled: bool = false,
    disabled_bg: u32 = 0x1a1a1a,
    disabled_fg: u32 = 0x777777,
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
    return .{ .color = render.u32ToClayColor(props.border_color), .width = .outside(props.border_width) };
}

/// Declare a text field: prompt + query + block cursor on the field bg.
/// The query slice is caller-owned (Shell draft buffers) and read
/// synchronously during declare — no lifetime beyond the frame.
/// Hover cursor: registers a hover-only entry for the field bg id
/// (.ID(props.id), the outer container) with .text. Disabled skips so
/// hover stays .default; empty id skips (headless-safe).
pub fn field(props: FieldProps, query: []const u8) void {
    const bg: u32 = if (props.disabled) props.disabled_bg else props.bg;
    const fg: u32 = if (props.disabled) props.disabled_fg else props.fg;
    cl.UI()(.{
        .id = .ID(props.id),
        .layout = .{
            .direction = .left_to_right,
            .sizing = .{ .w = fieldSizingW(props), .h = fieldSizingH(props) },
            .padding = .axes(props.pad_tb, props.pad_lr),
            .child_alignment = .{ .x = .left, .y = .center },
            .child_gap = 0,
        },
        .background_color = render.u32ToClayColor(bg),
        .corner_radius = .all(@floatFromInt(props.radius)),
        .border = fieldBorder(props),
    })({
        const fg_c = render.u32ToClayColor(fg);
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
    // Semantics: an editable field declares `set_text`, so
    // `Interaction.performTextInput` can refuse to type into a non-editable
    // node and `assertValueEquals` can read the committed query.
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

/// Declare a text field with HTML-like caret + selection: prompt, then
/// the query split around the caret (before / "|" / after), with the
/// selected span in `sel_fg` when present. The caret sits at the active
/// end (selection start when selecting leftward, end when rightward).
/// Empty runs are skipped (Clay text takes non-empty slices only).
/// Hover cursor: same hover-only .text entry on .ID(props.id) as field().
pub fn fieldEdit(props: FieldProps, query: []const u8, st: EditState) void {
    var s = st;
    clampEdit(&s, query.len);
    const fg = render.u32ToClayColor(if (props.disabled) props.disabled_fg else props.fg);
    const sel_fg = render.u32ToClayColor(if (props.disabled) props.disabled_fg else props.sel_fg);
    cl.UI()(.{
        .id = .ID(props.id),
        .layout = .{
            .direction = .left_to_right,
            .sizing = .{ .w = fieldSizingW(props), .h = fieldSizingH(props) },
            .padding = .axes(props.pad_tb, props.pad_lr),
            .child_alignment = .{ .x = .left, .y = .center },
            .child_gap = 0,
        },
        .background_color = render.u32ToClayColor(if (props.disabled) props.disabled_bg else props.bg),
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
    // NOTE: intentionally leaked (page_allocator, never freed). Clay keeps
    // a global currentContext pointer inside this arena, so freeing it
    // would dangle the *next* test's minMemorySize/initialize (segfault).
    const buf = try std.heap.page_allocator.alloc(u8, mem_size);
    const arena = cl.Arena.init(buf);
    _ = cl.initialize(arena, .{ .w = 720, .h = 480 }, .{});
    cl.setMeasureTextFunction(void, {}, stubMeasure);
    cl.setPointerState(.{ .x = 99999, .y = 99999 }, false);
    cl.beginLayout();
    declare_fn();
    return cl.endLayout();
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
    try std.testing.expectEqual(@as(u32, 0xe8e8e8), p.fg);
    try std.testing.expectEqual(@as(u32, 0x262626), p.bg);
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
    try std.testing.expectEqual(@as(u32, 0x7ab8ff), p.sel_fg);
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
            try std.testing.expectEqual(render.u32ToClayColor(0x1a1a1a), c.render_data.rectangle.background_color);
            found = true;
        }
    }
    try std.testing.expect(found);
}

fn declareBorderField() void {
    field(.{ .id = "test-border-field", .border_width = 1, .border_color = 0xff0000 }, "hi");
}

test "field border emits a border command" {
    const cmds = try layoutCommands(declareBorderField);
    var borders: usize = 0;
    for (cmds) |c| if (c.command_type == .border) {
        borders += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), borders);
}
