// A multi-line text editor model: a byte buffer, a caret, and every edit and movement.

const std = @import("std");
const Allocator = std.mem.Allocator;
const keyboard = @import("keyboard_constant.zig");

pub const Action = enum {
    // The buffer or caret did not change.
    ignored,
    // Text was inserted or removed, or the caret moved.
    edited,
    // The caller should run the query (Ctrl+Enter).
    run_requested,
};

// A caret position within the buffer.
pub const Caret = struct {
    // Byte offset into the buffer, always in `0..=len`.
    offset: usize = 0,
    // The byte offset the selection was anchored at, if any.
    anchor: ?usize = null,

    // The selected byte range, normalised so `start <= end`.
    pub fn selection(self: Caret) ?Span {
        const a = self.anchor orelse return null;
        const o = self.offset;
        return .{ .start = @min(a, o), .end = @max(a, o) };
    }

    pub fn hasSelection(self: Caret) bool {
        return self.anchor != null and self.anchor.? != self.offset;
    }

    // Keep the caret and anchor inside `0..=len`.
    pub fn clamp(self: *Caret, len: usize) void {
        if (self.offset > len) self.offset = len;
        if (self.anchor) |a| {
            if (a > len) self.anchor = len;
        }
    }

    pub fn clearSelection(self: *Caret) void {
        self.anchor = null;
    }
};

pub const Span = struct {
    start: usize,
    end: usize,
};

// The byte that starts the codepoint ending at `offset`, so Backspace and Left step over a whole `\xc3\xa9` instead of one of its bytes.
pub fn prevCodepoint(buf: []const u8, offset: usize) usize {
    if (offset == 0) return 0;
    var i = offset - 1;
    // Continuation bytes are 0b10xxxxxx; a codepoint is at most four bytes, so three steps is the floor.
    var steps: usize = 0;
    while (i > 0 and (buf[i] & 0xC0) == 0x80 and steps < 3) : (steps += 1) i -= 1;
    return i;
}

// The byte length of the codepoint at `offset` (1 for ASCII, 2..4 for UTF-8), clamped to `buf`.
pub fn codepointLen(buf: []const u8, offset: usize) usize {
    if (offset >= buf.len) return 0;
    const lead = buf[offset];
    const n: usize = if (lead < 0x80) 1 else if (lead & 0xE0 == 0xC0) 2 else if (lead & 0xF0 == 0xE0) 3 else if (lead & 0xF8 == 0xF0) 4 else 1;
    return @min(n, buf.len - offset);
}

// ---- undo and redo: one step is the whole text plus the caret that was in it, captured once per run of typing ----

/// How many steps one editor remembers before the oldest is dropped.
pub const history_steps: usize = 64;

/// How many bytes one editor's history may hold. Past it the oldest steps go; the newest always stays.
pub const history_bytes: usize = 16 * 1024 * 1024;

/// One remembered state: the text as it was, and where the caret was in it.
pub const Step = struct {
    text: []u8,
    caret: Caret,
};

/// The steps behind and ahead of an editor's caret.
pub const History = struct {
    undo: std.ArrayList(Step) = .empty,
    redo: std.ArrayList(Step) = .empty,
    bytes: usize = 0,

    /// Free every remembered state.
    pub fn deinit(self: *History, alloc: Allocator) void {
        self.dropUndo(alloc);
        self.dropRedo(alloc);
        self.undo.deinit(alloc);
        self.redo.deinit(alloc);
        self.bytes = 0;
    }

    pub fn canUndo(self: *const History) bool {
        return self.undo.items.len > 0;
    }

    pub fn canRedo(self: *const History) bool {
        return self.redo.items.len > 0;
    }

    fn dropUndo(self: *History, alloc: Allocator) void {
        for (self.undo.items) |*step| alloc.free(step.text);
        self.undo.clearRetainingCapacity();
        self.bytes = 0;
    }

    /// Forget the steps that were undone: a fresh edit starts a new future, which is what every editor does.
    pub fn dropRedo(self: *History, alloc: Allocator) void {
        for (self.redo.items) |*step| alloc.free(step.text);
        self.redo.clearRetainingCapacity();
    }

    /// Past the step or byte budget the oldest step goes, so a long session costs a bounded amount of memory.
    fn trim(self: *History, alloc: Allocator) void {
        while (self.undo.items.len > history_steps or (self.bytes > history_bytes and self.undo.items.len > 1)) {
            const oldest = self.undo.orderedRemove(0);
            self.bytes -= oldest.text.len;
            alloc.free(oldest.text);
        }
    }
};

// Edit operations on a buffer the caller owns, or on one this editor grows when it runs out.
pub const Editor = struct {
    buf: []u8,
    len: usize = 0,
    caret: Caret = .{},

    // Where a run longer than `buf` comes from. Null (the default) means `buf` is the whole story and an insert past it is refused.
    alloc: ?std.mem.Allocator = null,
    // True once `buf` came from `alloc`: only then may it be grown, and only then must `deinit` free it.
    owned: bool = false,

    // Seconds since the caret last moved, which is what a view blinks on.
    idle: f32 = 0,
    // True while this editor is the one the keyboard goes to. An unfocused editor draws NO caret, so the flag belongs to the model, not to a view.
    focused: bool = true,
    // Horizontal scroll in pixels, for a line wider than the field.
    scroll_x: f32 = 0,

    // The steps behind and ahead of the caret: empty, and free, until an editor with an allocator edits something.
    hist: History = .{},
    // True while the last edit was a run of typing that the next keystroke extends: a word costs one step, not one per byte.
    run_open: bool = false,

    // Bind an editor to storage it does not own: a run that does not fit is refused.
    pub fn init(buf: []u8) Editor {
        return .{ .buf = buf };
    }

    // The same, with room to grow: past the caller's buffer this editor asks `alloc` for more, so the text has no limit.
    pub fn initWithRoom(buf: []u8, alloc: std.mem.Allocator) Editor {
        return .{ .buf = buf, .alloc = alloc };
    }

    // Free the storage this editor grew into, and every step it remembered. The buffer it started with belongs to the caller and is left alone.
    pub fn deinit(self: *Editor) void {
        if (self.alloc) |a| self.hist.deinit(a);
        self.hist = .{};
        self.run_open = false;
        if (!self.owned) return;
        if (self.alloc) |a| a.free(self.buf);
        self.buf = &.{};
        self.len = 0;
        self.owned = false;
    }

    // Room for `need` bytes, doubling so a pasted megabyte costs a handful of copies. False when there is no allocator.
    fn reserve(self: *Editor, need: usize) bool {
        if (need <= self.buf.len) return true;
        const a = self.alloc orelse return false;
        var cap: usize = @max(self.buf.len, 64);
        while (cap < need) cap *= 2;
        if (self.owned) {
            self.buf = a.realloc(self.buf, cap) catch return false;
            return true;
        }
        // The first growth copies out of the buffer the caller declared, which stays the caller's.
        const fresh = a.alloc(u8, cap) catch return false;
        @memcpy(fresh[0..self.buf.len], self.buf);
        self.buf = fresh;
        self.owned = true;
        return true;
    }

    pub fn text(self: *const Editor) []const u8 {
        return self.buf[0..self.len];
    }

    // Advance the blink clock, but only while this editor is focused: an unfocused field holds its clock at zero, so re-focusing shows a solid caret.
    pub fn tickBlink(self: *Editor, dt: f32) void {
        if (!self.focused) {
            self.idle = 0;
            return;
        }
        self.idle += dt;
        // The blink toggles every half second of idle, so this is how long the window may sleep before drawing again.
        const phase_ms: u32 = @intFromFloat(@mod(self.idle * 1000.0, 500.0));
        const wait: u32 = 500 - @min(phase_ms, 499);
        next_toggle_ms = if (next_toggle_ms) |w| @min(w, wait) else wait;
    }

    // Replace the whole contents.
    pub fn setText(self: *Editor, new_text: []const u8) void {
        // A caller may hand this a slice of the buffer being replaced, so remember where it sits before any growth moves it.
        const base = @intFromPtr(self.buf.ptr);
        const at = @intFromPtr(new_text.ptr) -% base;
        const from_self = at < self.buf.len;
        _ = self.reserve(new_text.len);
        const run = if (from_self) self.buf[at..][0..new_text.len] else new_text;
        const n = @min(run.len, self.buf.len);
        // @memmove, not @memcpy: the run may overlap the destination it is being written to.
        @memmove(self.buf[0..n], run[0..n]);
        self.len = n;
        self.caret = .{};
        // A model edit puts the caret back on screen, solid, whatever the blink clock said.
        self.idle = 0;
    }

    // ---- undo and redo ----

    // Remember the state an edit is about to replace. `coalesce` extends the run the previous keystroke opened, so a word costs one step.
    fn capture(self: *Editor, coalesce: bool) void {
        if (coalesce and self.run_open) return;
        self.run_open = coalesce;
        const a = self.alloc orelse return;
        const copy = a.dupe(u8, self.text()) catch return;
        self.hist.undo.append(a, .{ .text = copy, .caret = self.caret }) catch {
            a.free(copy);
            return;
        };
        self.hist.bytes += copy.len;
        self.hist.dropRedo(a);
        self.hist.trim(a);
    }

    /// True when Cmd/Ctrl+Z has something to take back.
    pub fn canUndo(self: *const Editor) bool {
        return self.hist.canUndo();
    }

    /// True when Cmd/Ctrl+Shift+Z has something to put back.
    pub fn canRedo(self: *const Editor) bool {
        return self.hist.canRedo();
    }

    /// Take the last step back: the text and the caret return to where they were before it. False when there is nothing to undo.
    pub fn undo(self: *Editor) bool {
        const a = self.alloc orelse return false;
        const step = self.hist.undo.pop() orelse return false;
        self.hist.bytes -= step.text.len;
        // Where the text is NOW becomes the step forward, so redo can put it back.
        self.pushForward(a);
        const previous = step.text;
        self.restore(previous, step.caret);
        a.free(previous);
        return true;
    }

    /// Put back the step that was taken back. False when there is nothing to redo.
    pub fn redo(self: *Editor) bool {
        const a = self.alloc orelse return false;
        const step = self.hist.redo.pop() orelse return false;
        if (a.dupe(u8, self.text())) |copy| {
            if (self.hist.undo.append(a, .{ .text = copy, .caret = self.caret })) |_| {
                self.hist.bytes += copy.len;
            } else |_| {
                a.free(copy);
            }
        } else |_| {}
        const ahead = step.text;
        self.restore(ahead, step.caret);
        a.free(ahead);
        return true;
    }

    // Where the text is now, remembered as the step forward.
    fn pushForward(self: *Editor, a: Allocator) void {
        const copy = a.dupe(u8, self.text()) catch return;
        self.hist.redo.append(a, .{ .text = copy, .caret = self.caret }) catch {
            a.free(copy);
            return;
        };
    }

    // Write a remembered text and caret back into the buffer.
    fn restore(self: *Editor, remembered: []const u8, caret: Caret) void {
        _ = self.reserve(remembered.len);
        const n = @min(remembered.len, self.buf.len);
        @memmove(self.buf[0..n], remembered[0..n]);
        self.len = n;
        self.caret = caret;
        self.caret.clamp(n);
        // The restore moved the text, so the next keystroke is a new run.
        self.run_open = false;
        self.idle = 0;
    }

    // Insert one byte at the caret, replacing the selection if any.
    pub fn insertByte(self: *Editor, c: u8) bool {
        // One step per run of typing: the first keystroke of a word captures the text it is about to change.
        self.capture(true);
        if (self.caret.hasSelection()) _ = self.deleteSelectionQuietly();
        const inserted = self.insertByteQuietly(c);
        // A space or a new line ends the run, so the next word is a step of its own.
        if (inserted and (c == ' ' or c == '\n')) self.run_open = false;
        return inserted;
    }

    // The insert itself, with no history and no selection: what a run of bytes does byte by byte.
    fn insertByteQuietly(self: *Editor, c: u8) bool {
        // A field with an allocator has no length limit: it asks for more room instead of refusing the keystroke.
        if (!self.reserve(self.len + 1)) return false;

        // Shift the tail right by one byte, from the back so the copy does not overlap.
        var i = self.len;
        while (i > self.caret.offset) {
            i -= 1;
            self.buf[i + 1] = self.buf[i];
        }
        self.buf[self.caret.offset] = c;
        self.len += 1;
        self.caret.offset += 1;
        // Typing is exactly when the caret must be visible: an edit always restarts the solid half of the blink.
        self.idle = 0;
        return true;
    }

    // Insert a run of bytes. `s` must not be a slice of this editor's own buffer: growth can move it mid-run.
    pub fn insertSlice(self: *Editor, s: []const u8) usize {
        // A composed run is typing, so it joins the run the last keystroke opened instead of costing a step of its own.
        self.capture(true);
        if (self.caret.hasSelection()) _ = self.deleteSelectionQuietly();
        // One growth for the whole run, so a pasted megabyte is copied in a handful of steps and not one byte at a time.
        _ = self.reserve(self.len + s.len);
        var written: usize = 0;
        for (s) |c| {
            if (!self.insertByteQuietly(c)) break;
            written += 1;
        }
        if (written > 0 and s[s.len - 1] == ' ') self.endRun();
        return written;
    }

    // Close the typing run: the next edit starts a step of its own. A paste or a scripted insert is one step, not a continuation.
    pub fn endRun(self: *Editor) void {
        self.run_open = false;
    }

    // Delete the selection, if any. Returns true if something was removed.
    pub fn deleteSelection(self: *Editor) bool {
        if (!self.caret.hasSelection()) return false;
        self.capture(false);
        return self.deleteSelectionQuietly();
    }

    // The deletion itself, for an edit that already captured its step.
    fn deleteSelectionQuietly(self: *Editor) bool {
        const sel = self.caret.selection() orelse return false;
        if (sel.start == sel.end) return false;
        self.splice(sel.start, sel.end - sel.start);
        self.caret.offset = sel.start;
        self.caret.clearSelection();
        return true;
    }

    // Delete the byte before the caret (Backspace).
    pub fn backspace(self: *Editor) void {
        // A held Backspace is one run, like typing: it costs one step until the caret moves or something else happens.
        self.capture(true);
        if (self.caret.hasSelection()) {
            _ = self.deleteSelectionQuietly();
            return;
        }
        if (self.caret.offset == 0) return;
        // A whole codepoint, not a byte: deleting half of `\xc3\xa9` would leave invalid UTF-8 on screen.
        const start = prevCodepoint(self.text(), self.caret.offset);
        self.splice(start, self.caret.offset - start);
        self.caret.offset = start;
    }

    // Delete the byte at the caret (Delete).
    pub fn deleteForward(self: *Editor) void {
        self.capture(true);
        if (self.caret.hasSelection()) {
            _ = self.deleteSelectionQuietly();
            return;
        }
        if (self.caret.offset >= self.len) return;
        self.splice(self.caret.offset, codepointLen(self.text(), self.caret.offset));
    }

    // Delete the word before the caret: Ctrl/Cmd+Backspace, which is the keyboard equivalent of dragging over a word and deleting it.
    pub fn deleteWordLeft(self: *Editor) void {
        self.capture(false);
        if (self.deleteSelectionQuietly()) return;
        const from = self.caret.offset;
        self.moveWordLeft(false);
        const to = self.caret.offset;
        if (to < from) self.splice(to, from - to);
    }

    // Delete the word after the caret: Ctrl/Cmd+Delete.
    pub fn deleteWordRight(self: *Editor) void {
        self.capture(false);
        if (self.deleteSelectionQuietly()) return;
        const from = self.caret.offset;
        self.moveWordRight(false);
        const to = self.caret.offset;
        // The caret goes back to where the deletion started, so the next word is the one under the pen.
        self.caret.offset = from;
        if (to > from) self.splice(from, to - from);
    }

    // Remove `count` bytes at `at`, closing the gap.
    fn splice(self: *Editor, at: usize, count: usize) void {
        // Deleting is an edit too, so the caret is solid while a key is held down.
        self.idle = 0;
        const tail = self.len - (at + count);
        if (tail > 0) {
            std.mem.copyForwards(u8, self.buf[at .. at + tail], self.buf[at + count ..][0..tail]);
        }
        self.len -= count;
    }

    // Select everything, or clear the selection.
    pub fn selectAll(self: *Editor) void {
        self.caret.anchor = 0;
        self.caret.offset = self.len;
    }

    // Delete the selection, or delete the whole line the caret is on when nothing is selected.
    pub fn deleteLine(self: *Editor) void {
        self.capture(false);
        if (self.deleteSelectionQuietly()) return;
        const start = findLineStart(self.buf, 0, self.len, self.caret.offset);
        var end = findLineEnd(self.buf, 0, self.len, self.caret.offset);
        // Swallow the trailing newline so a second Ctrl-K is not a no-op.
        if (end < self.len and self.buf[end] == '\n') end += 1;
        self.splice(start, end - start);
        self.caret.offset = start;
    }

    // --- caret movement -------------------------------------------------

    // Offset of the first byte of the line containing `offset`.
    pub fn lineStart(self: *const Editor, offset: usize) usize {
        return findLineStart(self.buf, 0, self.len, offset);
    }

    // Offset just past the last byte of the line containing `offset`, excluding the newline.
    pub fn lineEnd(self: *const Editor, offset: usize) usize {
        return findLineEnd(self.buf, 0, self.len, offset);
    }

    // 0-based index of the line containing `offset`.
    pub fn lineNumber(self: *const Editor, offset: usize) usize {
        var n: usize = 0;
        var i: usize = 0;
        const limit = @min(offset, self.len);
        while (i < limit) : (i += 1) {
            if (self.buf[i] == '\n') n += 1;
        }
        return n;
    }

    // Total number of lines (an empty buffer is one empty line).
    pub fn lineCount(self: *const Editor) usize {
        return self.lineNumber(self.len) + 1;
    }

    // Start offset of 0-based `line`.
    pub fn lineStartAt(self: *const Editor, line: usize) usize {
        if (line == 0) return 0;
        var current: usize = 0;
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            if (self.buf[i] != '\n') continue;
            current += 1;
            if (current == line) return i + 1;
        }
        return self.len;
    }

    pub fn moveLeft(self: *Editor, shift: bool) void {
        // A bare arrow collapses a selection to the caret instead of moving past it, which is what every editor does.
        if (!shift and self.caret.hasSelection()) {
            self.setCaret(self.caret.offset, false);
            self.idle = 0;
            return;
        }
        self.setCaret(prevCodepoint(self.text(), self.caret.offset), shift);
    }

    pub fn moveRight(self: *Editor, shift: bool) void {
        // A bare arrow collapses a selection to the caret instead of moving past it, which is what every editor does.
        if (!shift and self.caret.hasSelection()) {
            self.setCaret(self.caret.offset, false);
            self.idle = 0;
            return;
        }
        self.setCaret(self.caret.offset + codepointLen(self.text(), self.caret.offset), shift);
    }

    pub fn moveHome(self: *Editor, shift: bool) void {
        self.setCaret(self.lineStart(self.caret.offset), shift);
    }

    pub fn moveEnd(self: *Editor, shift: bool) void {
        self.setCaret(self.lineEnd(self.caret.offset), shift);
    }

    // Move to the start of the previous line.
    pub fn moveLineUp(self: *Editor, shift: bool) void {
        const here = self.lineStart(self.caret.offset);
        if (here == 0) {
            self.setCaret(0, shift);
            return;
        }
        const previous = self.lineStartAt(self.lineNumber(self.caret.offset) - 1);
        const column = self.caret.offset - here;
        const prev_len = findLineEnd(self.buf, 0, self.len, previous) - previous;
        self.setCaret(previous + @min(column, prev_len), shift);
    }

    // Move to the start of the next line, preserving the column where possible (a short line clamps rather than jumping to the end).
    pub fn moveLineDown(self: *Editor, shift: bool) void {
        const here = self.lineStart(self.caret.offset);
        const column = self.caret.offset - here;
        const next_line = self.lineNumber(self.caret.offset) + 1;
        if (next_line >= self.lineCount()) {
            self.setCaret(self.len, shift);
            return;
        }
        const next = self.lineStartAt(next_line);
        const next_len = findLineEnd(self.buf, 0, self.len, next) - next;
        self.setCaret(next + @min(column, next_len), shift);
    }

    // Move the caret, maintaining the selection anchor when Shift is held.
    pub fn setCaret(self: *Editor, offset: usize, shift: bool) void {
        const clamped = @min(offset, self.len);
        if (shift) {
            // Start a selection on the first shifted move.
            if (self.caret.anchor == null) self.caret.anchor = self.caret.offset;
        } else {
            self.caret.clearSelection();
        }
        self.caret.offset = clamped;
        // A caret that moved is not a run of typing any more, so the next keystroke starts a new undo step.
        self.run_open = false;
        // EVERY caret move restarts the solid half of the blink, arrows included: a caret that lands mid-blink is a caret that vanishes as you move it.
        self.idle = 0;
    }

    // Delete everything and reset the caret.
    pub fn insert(self: *Editor, bytes: []const u8) void {
        _ = self.insertSlice(bytes);
        self.idle = 0;
    }

    // Delete the selection, or the character after the caret.
    pub fn delete(self: *Editor) void {
        self.deleteForward();
        self.idle = 0;
    }

    // Move by word, which is what ctrl+arrow does in a single-line field.
    pub fn moveWordLeft(self: *Editor, shift: bool) void {
        var i = self.caret.offset;
        while (i > 0 and !isWordByte(self.buf[i - 1])) i -= 1;
        while (i > 0 and isWordByte(self.buf[i - 1])) i -= 1;
        self.setCaret(i, shift);
        self.idle = 0;
    }

    // Move by word to the right.
    pub fn moveWordRight(self: *Editor, shift: bool) void {
        var i = self.caret.offset;
        while (i < self.len and isWordByte(self.buf[i])) i += 1;
        while (i < self.len and !isWordByte(self.buf[i])) i += 1;
        self.setCaret(i, shift);
        self.idle = 0;
    }

    // The byte offset nearest to a horizontal position, given a fixed character width.
    pub fn caretAtX(self: *const Editor, x: f32, char_w: f32) usize {
        if (char_w <= 0) return self.caret.offset;
        const col_f = @max(x, 0) / char_w;
        const col: usize = @intFromFloat(@round(col_f));
        return @min(col, self.len);
    }

    // Place the caret from a click. `extend` keeps the anchor, which is what a shift-click does.
    pub fn clickAt(self: *Editor, x: f32, char_w: f32, extend: bool) void {
        var at = self.caretAtX(x, char_w);
        // Never leave the caret inside a multi-byte codepoint: a click between the bytes of `\xc3\xa9` would split it on the next Backspace.
        while (at > 0 and at < self.len and (self.buf[at] & 0xC0) == 0x80) at -= 1;
        self.setCaret(at, extend);
        self.idle = 0;
    }

    // Extend the selection to a drag position.
    pub fn dragTo(self: *Editor, x: f32, char_w: f32) void {
        self.setCaret(self.caretAtX(x, char_w), true);
        self.idle = 0;
    }

    // Select the word under a position, which is what a double-click does.
    pub fn selectWordAt(self: *Editor, x: f32, char_w: f32) void {
        const at = self.caretAtX(x, char_w);
        var s = at;
        var e = at;
        while (s > 0 and isWordByte(self.buf[s - 1])) s -= 1;
        while (e < self.len and isWordByte(self.buf[e])) e += 1;
        self.caret.anchor = s;
        self.caret.offset = e;
        self.idle = 0;
    }

    pub fn clear(self: *Editor) void {
        if (self.len == 0) {
            self.caret = .{};
            return;
        }
        self.capture(false);
        self.len = 0;
        self.caret = .{};
    }

    // True when there is room for more text.
    pub fn hasRoom(self: *const Editor) bool {
        return self.len < self.buf.len;
    }
};

fn findLineStart(buf: []const u8, from: usize, len: usize, offset: usize) usize {
    var i = @min(offset, len);
    while (i > from) {
        i -= 1;
        if (buf[i] == '\n') return i + 1;
    }
    return from;
}

fn findLineEnd(buf: []const u8, from: usize, len: usize, offset: usize) usize {
    _ = from;
    var i = @min(offset, len);
    while (i < len) : (i += 1) {
        if (buf[i] == '\n') return i;
    }
    return len;
}

// The result of feeding one key event to the editor.
pub fn handleKey(
    editor: *Editor,
    keycode: u32,
    shift: bool,
    ctrl: bool,
) Action {
    // Navigation keys, using the same evdev codes glinlandui exposes.
    switch (keycode) {
        KEY_LEFT => {
            // Ctrl/Cmd+Left is a word: the same reach a pointer gets by dragging over one, and the reason a long URL is editable by keyboard.
            if (ctrl) editor.moveWordLeft(shift) else editor.moveLeft(shift);
            return .edited;
        },
        KEY_RIGHT => {
            if (ctrl) editor.moveWordRight(shift) else editor.moveRight(shift);
            return .edited;
        },
        KEY_HOME => {
            if (ctrl) {
                editor.setCaret(0, shift);
            } else {
                editor.moveHome(shift);
            }
            return .edited;
        },
        KEY_END => {
            // Ctrl/Cmd+End is the end of the WHOLE text in a multiline field, not the end of the line under the caret.
            if (ctrl) editor.setCaret(editor.len, shift) else editor.moveEnd(shift);
            return .edited;
        },
        KEY_UP => {
            editor.moveLineUp(shift);
            return .edited;
        },
        KEY_DOWN => {
            editor.moveLineDown(shift);
            return .edited;
        },
        KEY_BACKSPACE => {
            if (editor.len == 0) return .ignored;
            if (ctrl) editor.deleteWordLeft() else editor.backspace();
            return .edited;
        },
        KEY_DELETE => {
            if (ctrl) editor.deleteWordRight() else editor.deleteForward();
            return .edited;
        },
        KEY_ENTER => {
            // Ctrl+Enter runs; a bare Enter inserts a newline.
            if (ctrl) return .run_requested;
            if (!editor.insertByte('\n')) return .ignored;
            return .edited;
        },
        KEY_K => {
            if (ctrl) {
                editor.deleteLine();
                return .edited;
            }
        },
        KEY_A => {
            if (ctrl) {
                editor.selectAll();
                return .edited;
            }
        },
        else => {},
    }

    // A Ctrl/Cmd combo is a shortcut, never a character: inserting a literal control byte is always wrong, and the app owns the clipboard.
    if (ctrl) return .ignored;
    // Printable ASCII only, for the backends that send a keycode instead of the composed text.
    if (keyChar(keycode, shift)) |c| {
        if (!editor.insertByte(c)) return .ignored;
        return .edited;
    }
    return .ignored;
}

// Select the run around `offset` the way a double click does: the word (letters, digits, underscore), or the run of non-word bytes between two words. A

// newline always ends a run, so a double click never selects across lines.
pub fn selectWordAt(editor: *Editor, offset: usize) void {
    if (editor.len == 0) return;
    var at = @min(offset, editor.len);
    // The end of the buffer has no byte at `at`, so anchor on the one before it.
    if (at == editor.len) at -= 1;
    const text = editor.buf[0..editor.len];
    const word = isWordByte(text[at]);
    var start = at;
    while (start > 0 and text[start - 1] != '\n' and isWordByte(text[start - 1]) == word) start -= 1;
    var end = at;
    while (end < text.len and text[end] != '\n' and isWordByte(text[end]) == word) end += 1;
    editor.setCaret(start, false);
    editor.setCaret(end, true);
    editor.idle = 0;
}

// The byte offset in `text` closest to `x`, using the font that DRAWS it. `measure` must be the same function the layout uses, or a click lands on the

// wrong character: a guessed cell width drifts further off the glyphs the longer the line is.
pub fn offsetAtX(text: []const u8, x: f32, font_size: u16, measure: *const fn ([]const u8, u16) f32) usize {
    if (text.len == 0 or x <= 0) return 0;
    var lo: usize = 0;
    var hi: usize = text.len;
    // Largest offset whose prefix still ends left of x.
    while (lo < hi) {
        const mid = (lo + hi + 1) / 2;
        if (measure(text[0..mid], font_size) <= x) lo = mid else hi = mid - 1;
    }
    // Never leave the caret inside a codepoint.
    while (lo > 0 and lo < text.len and (text[lo] & 0xC0) == 0x80) lo -= 1;
    // The nearer edge wins, which is what makes a click between two letters feel right.
    if (lo < text.len) {
        const step = codepointLen(text, lo);
        if (x - measure(text[0..lo], font_size) > measure(text[0 .. lo + step], font_size) - x) return lo + step;
    }
    return lo;
}

// Milliseconds until the next caret toggle, or null when no focused field is blinking. A window uses it to wake once per toggle.
var next_toggle_ms: ?u32 = null;

// Forget the last frame's blink schedule; every focused field that ticks this frame sets it again.
pub fn beginBlinkFrame() void {
    next_toggle_ms = null;
}

// Milliseconds until the next caret toggle, or null when nothing needs a repaint for a caret.
pub fn blinkPendingMs() ?u32 {
    return next_toggle_ms;
}

// True when the caret should be drawn: only in the focused field, solid for half a second after it moved, then a 1 Hz blink.
pub fn caretVisible(editor: *const Editor) bool {
    if (!editor.focused) return false;
    return editor.idle < 0.5 or @mod(editor.idle, 1.0) < 0.5;
}

// Copy the selection into `out`; null when nothing is selected. `out` is truncated, never overrun.
pub fn copySelection(editor: *const Editor, out: []u8) ?[]const u8 {
    const span = editor.caret.selection() orelse return null;
    if (span.start >= span.end) return null;
    const n = @min(span.end - span.start, out.len);
    @memcpy(out[0..n], editor.buf[span.start..][0..n]);
    return out[0..n];
}

// Cut: copy the selection, then remove it. Null when nothing is selected.
pub fn cutSelection(editor: *Editor, out: []u8) ?[]const u8 {
    const copied = copySelection(editor, out) orelse return null;
    _ = editor.deleteSelection();
    editor.idle = 0;
    return copied;
}

// Paste a run at the caret, replacing any selection: the same edit as `handleText`, named for the gesture.
pub fn paste(editor: *Editor, text: []const u8) Action {
    return handleText(editor, text);
}

// Insert a run the platform already composed, which is how `A` (Caps Lock), `*`, `(` and `\xc3\xa9` arrive on macOS.
pub fn handleText(editor: *Editor, text: []const u8) Action {
    if (text.len == 0) return .ignored;
    if (editor.insertSlice(text) == 0) return .ignored;
    // A fresh edit restarts the blink, so the caret stays solid while the user is typing.
    editor.idle = 0;
    return .edited;
}

// The keys this model names, from the one table in `keyboard_constant.zig`: no code is spelled twice in the engine.
pub const KEY_TAB: u32 = keyboard.KEY_TAB;
pub const KEY_BACKSPACE: u32 = keyboard.KEY_BACKSPACE;
pub const KEY_ENTER: u32 = keyboard.KEY_ENTER;
pub const KEY_A: u32 = keyboard.KEY_A;
pub const KEY_LEFTSHIFT: u32 = keyboard.KEY_LEFTSHIFT;
pub const KEY_RIGHTSHIFT: u32 = keyboard.Key.right_shift.code();
pub const KEY_LEFTCTRL: u32 = keyboard.KEY_LEFTCTRL;
pub const KEY_LEFT: u32 = keyboard.KEY_LEFT;
pub const KEY_RIGHT: u32 = keyboard.KEY_RIGHT;
pub const KEY_UP: u32 = keyboard.KEY_UP;
pub const KEY_DOWN: u32 = keyboard.KEY_DOWN;
pub const KEY_HOME: u32 = keyboard.KEY_HOME;
pub const KEY_END: u32 = keyboard.KEY_END;
pub const KEY_DELETE: u32 = keyboard.KEY_DELETE;
pub const KEY_X: u32 = keyboard.KEY_X;
pub const KEY_C: u32 = keyboard.KEY_C;
pub const KEY_V: u32 = keyboard.KEY_V;
pub const KEY_Y: u32 = keyboard.KEY_Y;
pub const KEY_Z: u32 = keyboard.KEY_Z;
pub const KEY_K: u32 = keyboard.KEY_K;
pub const KEY_O: u32 = keyboard.KEY_O;
pub const KEY_ESCAPE: u32 = keyboard.KEY_ESCAPE;

// Map a keycode to a printable ASCII byte (US layout), or null.
pub fn keyChar(keycode: u32, shift: bool) ?u8 {
    // Letters: q..p, a..l, z..m, in evdev order.
    const lower_letters = "qwertyuiopasdfghjklzxcvbnm";
    const letter_codes = [_]u32{
        16, 17, 18, 19, 20, 21, 22, 23, 24, 25,
        30, 31, 32, 33, 34, 35, 36, 37, 38, 44,
        45, 46, 47, 48, 49, 50,
    };
    for (letter_codes, 0..) |code, i| {
        if (keycode != code) continue;
        const c = lower_letters[i];
        return if (shift) std.ascii.toUpper(c) else c;
    }

    // Digits: evdev 2..11 are 1,2,...,0 -- NOT 0..9.
    if (keycode >= 2 and keycode <= 11) {
        // evdev 11 is the '0' key, so the run is 1..0 and the last one does not follow the +1 pattern.
        if (!shift) return if (keycode == 11) '0' else @intCast(keycode - 2 + '1');
        // Shifted 1..0 is  ! @ # $ % ^ & * ( )
        const shifted_digits = [_]u8{ '!', '@', '#', '$', '%', '^', '&', '*', '(', ')' };
        return shifted_digits[keycode - 2];
    }

    // Punctuation.
    const punct = [_]struct { code: u32, plain: u8, shifted: u8 }{
        .{ .code = 12, .plain = 0x2D, .shifted = 0x5F }, // - _
        .{ .code = 13, .plain = 0x3D, .shifted = 0x2B }, // = +
        .{ .code = 26, .plain = 0x5B, .shifted = 0x7B }, // [ {
        .{ .code = 27, .plain = 0x5D, .shifted = 0x7D }, // ] }
        .{ .code = 39, .plain = 0x3B, .shifted = 0x3A }, // ; :
        .{ .code = 40, .plain = 0x27, .shifted = 0x22 }, // '  "
        .{ .code = 41, .plain = 0x60, .shifted = 0x7E }, // `  ~
        .{ .code = 43, .plain = 0x5C, .shifted = 0x7C }, // \  |
        .{ .code = 51, .plain = 0x2C, .shifted = 0x3C }, // ,  <
        .{ .code = 52, .plain = 0x2E, .shifted = 0x3E }, // .  >
        .{ .code = 53, .plain = 0x2F, .shifted = 0x3F }, // /  ?
        .{ .code = 57, .plain = 0x20, .shifted = 0x20 }, // space
    };
    for (punct) |p| {
        if (keycode != p.code) continue;
        return if (shift) p.shifted else p.plain;
    }
    return null;
}

// A key press: the evdev code, and whether Shift must be held.
pub const Keystroke = struct { code: u32, shift: bool };

// The inverse of `keyChar`: the key that produces `ch`.
pub fn keyCodeFor(ch: u8) ?Keystroke {
    if (ch >= 'a' and ch <= 'z') {
        const lower_letters = "qwertyuiopasdfghjklzxcvbnm";
        const letter_codes = [_]u32{
            16, 17, 18, 19, 20, 21, 22, 23, 24, 25,
            30, 31, 32, 33, 34, 35, 36, 37, 38, 44,
            45, 46, 47, 48, 49, 50,
        };
        for (lower_letters, 0..) |c, i| {
            if (c == ch) return .{ .code = letter_codes[i], .shift = false };
        }
    }
    if (ch >= 'A' and ch <= 'Z') {
        if (keyCodeFor(std.ascii.toLower(ch))) |k| {
            return .{ .code = k.code, .shift = true };
        }
    }
    if (ch >= '1' and ch <= '9') return .{ .code = 2 + (ch - '1'), .shift = false };
    if (ch == '0') return .{ .code = 11, .shift = false };

    // Digits under shift, which are not letters and not punctuation.
    const shifted_digits = [_]u8{ '!', '@', '#', '$', '%', '^', '&', '*', '(', ')' };
    if (std.mem.indexOfScalar(u8, &shifted_digits, ch)) |i| {
        return .{ .code = 2 + @as(u32, @intCast(i)), .shift = true };
    }

    // Punctuation, mirroring the table in keyChar.
    const punct = [_]struct { code: u32, plain: u8, shifted: u8 }{
        .{ .code = 12, .plain = 0x2D, .shifted = 0x5F },
        .{ .code = 13, .plain = 0x3D, .shifted = 0x2B },
        .{ .code = 26, .plain = 0x5B, .shifted = 0x7B },
        .{ .code = 27, .plain = 0x5D, .shifted = 0x7D },
        .{ .code = 39, .plain = 0x3B, .shifted = 0x3A },
        .{ .code = 40, .plain = 0x27, .shifted = 0x22 },
        .{ .code = 41, .plain = 0x60, .shifted = 0x7E },
        .{ .code = 43, .plain = 0x5C, .shifted = 0x7C },
        .{ .code = 51, .plain = 0x2C, .shifted = 0x3C },
        .{ .code = 52, .plain = 0x2E, .shifted = 0x3E },
        .{ .code = 53, .plain = 0x2F, .shifted = 0x3F },
        .{ .code = 57, .plain = 0x20, .shifted = 0x20 },
    };
    if (!shifted_digit(ch)) {
        for (punct) |p| {
            if (p.plain == ch) return .{ .code = p.code, .shift = false };
        }
    }
    for (punct) |p| {
        if (p.shifted == ch and ch != 0x20) return .{ .code = p.code, .shift = true };
    }
    return null;
}

// True for the characters the digit row produces under Shift.
fn shifted_digit(ch: u8) bool {
    const shifted_digits = [_]u8{ '!', '@', '#', '$', '%', '^', '&', '*', '(', ')' };
    return std.mem.indexOfScalar(u8, &shifted_digits, ch) != null;
}

// Tests

const testing = std.testing;

test "insert and read back" {
    var buf: [64]u8 = undefined;
    var e = Editor.init(&buf);
    try testing.expectEqual(@as(usize, 5), e.insertSlice("hello"));
    try testing.expectEqualStrings("hello", e.text());
    try testing.expectEqual(@as(usize, 5), e.caret.offset);
}

test "insert respects the buffer capacity" {
    var buf: [4]u8 = undefined;
    var e = Editor.init(&buf);
    try testing.expectEqual(@as(usize, 4), e.insertSlice("hello world"));
    try testing.expectEqualStrings("hell", e.text());
    try testing.expect(!e.hasRoom());
    // A further insert must not corrupt anything.
    _ = e.insertByte('!');
    try testing.expectEqualStrings("hell", e.text());
}

test "an editor with an allocator grows past its buffer instead of refusing the run" {
    var buf: [4]u8 = undefined;
    var e = Editor.initWithRoom(&buf, testing.allocator);
    defer e.deinit();
    try testing.expectEqual(@as(usize, 20), e.insertSlice("well past four bytes"));
    try testing.expectEqualStrings("well past four bytes", e.text());
    // It grew once, so the buffer it started with is untouched and the text lives past it.
    try testing.expect(e.owned);
    try testing.expect(e.buf.len >= 20);
}

test "backspace and delete" {
    var buf: [64]u8 = undefined;
    var e = Editor.init(&buf);
    _ = e.insertSlice("abc");
    e.backspace();
    try testing.expectEqualStrings("ab", e.text());
    e.caret.offset = 0;
    e.deleteForward();
    try testing.expectEqualStrings("b", e.text());
}

test "a newline makes a second line and backspace joins them" {
    var buf: [64]u8 = undefined;
    var e = Editor.init(&buf);
    _ = e.insertSlice("SELECT 1");
    _ = e.insertByte('\n');
    _ = e.insertSlice("FROM t");
    try testing.expectEqual(@as(usize, 2), e.lineCount());
    try testing.expectEqualStrings("SELECT 1\nFROM t", e.text());

    // The '\n' is at offset 8; place the caret just past it and delete, which is what joining two lines means.
    const newline_offset = std.mem.indexOfScalar(u8, e.text(), '\n').?;
    e.caret.offset = newline_offset + 1;
    e.backspace();
    try testing.expectEqualStrings("SELECT 1FROM t", e.text());
}

test "line navigation" {
    var buf: [64]u8 = undefined;
    var e = Editor.init(&buf);
    _ = e.insertSlice("aaa\nbbbbbb\ncc");

    e.setCaret(0, false);
    try testing.expectEqual(@as(usize, 0), e.lineNumber(0));
    try testing.expectEqual(@as(usize, 1), e.lineNumber(5));

    e.setCaret(0, false);
    e.moveLineDown(false);
    try testing.expectEqual(@as(usize, 4), e.caret.offset);
    e.moveLineDown(false);
    // Line 2 is "cc"; the column (0) still fits, so the caret lands at its start.
    try testing.expectEqual(@as(usize, 11), e.caret.offset);
    e.moveLineUp(false);
    try testing.expectEqual(@as(usize, 4), e.caret.offset);
}

test "home and end work per line" {
    var buf: [64]u8 = undefined;
    var e = Editor.init(&buf);
    _ = e.insertSlice("aaa\nbbbbbb\ncc");
    e.setCaret(0, false);
    e.moveEnd(false);
    try testing.expectEqual(@as(usize, 3), e.caret.offset);
    e.moveLineDown(false);
    // moveLineDown preserves the COLUMN (3), so the caret is at 4 + 3.
    try testing.expectEqual(@as(usize, 7), e.caret.offset);
    e.moveEnd(false);
    // End of "bbbbbb" is 4 + 6 = 10.
    try testing.expectEqual(@as(usize, 10), e.caret.offset);
    e.moveHome(false);
    // Start of "bbbbbb" is 4.
    try testing.expectEqual(@as(usize, 4), e.caret.offset);
}

test "selection deletes the span" {
    var buf: [64]u8 = undefined;
    var e = Editor.init(&buf);
    _ = e.insertSlice("hello world");
    e.caret.anchor = 0;
    e.caret.offset = 6;
    try testing.expect(e.caret.hasSelection());
    try testing.expect(e.deleteSelection());
    try testing.expectEqualStrings("world", e.text());
    try testing.expect(!e.caret.hasSelection());
}

test "shift+arrow builds a selection" {
    var buf: [64]u8 = undefined;
    var e = Editor.init(&buf);
    _ = e.insertSlice("abcdef");
    e.setCaret(0, false);
    e.moveRight(true);
    e.moveRight(true);
    try testing.expect(e.caret.hasSelection());
    const sel = e.caret.selection().?;
    try testing.expectEqual(@as(usize, 0), sel.start);
    try testing.expectEqual(@as(usize, 2), sel.end);
}

test "typing replaces the selection" {
    var buf: [64]u8 = undefined;
    var e = Editor.init(&buf);
    _ = e.insertSlice("hello world");
    e.selectAll();
    _ = e.insertByte('X');
    try testing.expectEqualStrings("X", e.text());
}

test "select all then delete empties the buffer" {
    var buf: [64]u8 = undefined;
    var e = Editor.init(&buf);
    _ = e.insertSlice("SELECT * FROM t");
    e.selectAll();
    try testing.expect(e.deleteSelection());
    try testing.expectEqualStrings("", e.text());
    try testing.expectEqual(@as(usize, 0), e.caret.offset);
}

test "ctrl-K deletes the caret's line" {
    var buf: [64]u8 = undefined;
    var e = Editor.init(&buf);
    _ = e.insertSlice("one\ntwo\nthree");
    e.setCaret(5, false); // inside "two"
    try testing.expectEqual(handleKey(&e, KEY_K, false, true), Action.edited);
    try testing.expectEqualStrings("one\nthree", e.text());
}

test "ctrl-K with no selection removes the newline too" {
    var buf: [64]u8 = undefined;
    var e = Editor.init(&buf);
    _ = e.insertSlice("one\ntwo");
    e.setCaret(0, false);
    _ = handleKey(&e, KEY_K, false, true);
    try testing.expectEqualStrings("two", e.text());
}

test "ctrl-Enter asks to run, plain Enter inserts a newline" {
    var buf: [64]u8 = undefined;
    var e = Editor.init(&buf);
    _ = e.insertSlice("SELECT 1");
    try testing.expectEqual(handleKey(&e, KEY_ENTER, false, true), Action.run_requested);
    // The run request must not have inserted anything.
    try testing.expectEqualStrings("SELECT 1", e.text());

    try testing.expectEqual(handleKey(&e, KEY_ENTER, false, false), Action.edited);
    try testing.expectEqualStrings("SELECT 1\n", e.text());
}

test "backspace at offset 0 is a no-op, not a crash" {
    var buf: [16]u8 = undefined;
    var e = Editor.init(&buf);
    e.backspace();
    try testing.expectEqual(@as(usize, 0), e.len);
}

test "deleteForward at the end is a no-op" {
    var buf: [16]u8 = undefined;
    var e = Editor.init(&buf);
    _ = e.insertSlice("abc");
    e.deleteForward();
    try testing.expectEqualStrings("abc", e.text());
}

test "movement clamps at both ends" {
    var buf: [16]u8 = undefined;
    var e = Editor.init(&buf);
    _ = e.insertSlice("ab");
    e.setCaret(0, false);
    e.moveLeft(false);
    try testing.expectEqual(@as(usize, 0), e.caret.offset);
    e.moveRight(false);
    e.moveRight(false);
    e.moveRight(false);
    try testing.expectEqual(@as(usize, 2), e.caret.offset);
}

test "selectWordAt takes the whole word under the offset, and never crosses a newline" {
    var buf: [64]u8 = undefined;
    var e = Editor.init(&buf);
    _ = e.insertSlice("SELECT name FROM t\nWHERE id = 1");
    // Inside `name`.
    selectWordAt(&e, 9);
    var span = e.caret.selection().?;
    try testing.expectEqual(@as(usize, 7), span.start);
    try testing.expectEqual(@as(usize, 11), span.end);
    // A click on the space before `name` takes the run of non-word bytes.
    selectWordAt(&e, 6);
    span = e.caret.selection().?;
    try testing.expectEqual(@as(usize, 6), span.start);
    try testing.expectEqual(@as(usize, 7), span.end);
    // The end of the buffer anchors on the last byte, not past it.
    selectWordAt(&e, e.len);
    span = e.caret.selection().?;
    try testing.expectEqual(@as(usize, e.len - 1), span.start);
    try testing.expectEqual(@as(usize, e.len), span.end);
    // `id` is a word even though it is short.
    selectWordAt(&e, 25);
    span = e.caret.selection().?;
    try testing.expectEqual(@as(usize, 25), span.start);
    try testing.expectEqual(@as(usize, 27), span.end);
}

test "the caret is solid right after an edit and blinks after half a second" {
    var buf: [8]u8 = undefined;
    var e = Editor.init(&buf);
    try testing.expect(caretVisible(&e));
    // 0.6 s idle is the dark half of the blink.
    e.idle = 0.6;
    try testing.expect(!caretVisible(&e));
    // 1.1 s is the bright half again.
    e.idle = 1.1;
    try testing.expect(caretVisible(&e));
}

test "an edit makes a caret that had blinked out solid again" {
    var buf: [16]u8 = undefined;
    var e = Editor.init(&buf);
    // 0.6 s of idle is the dark half, which is exactly when a typist must never lose the caret.
    e.idle = 0.6;
    try testing.expect(!caretVisible(&e));
    _ = e.insertByte('a');
    try testing.expect(caretVisible(&e));
    e.idle = 0.7;
    e.backspace();
    try testing.expect(caretVisible(&e));
    e.idle = 0.7;
    e.setText("xyz");
    try testing.expect(caretVisible(&e));
}

test "the blink schedule says when the next caret toggle is due" {
    var buf: [8]u8 = undefined;
    var e = Editor.init(&buf);
    beginBlinkFrame();
    try testing.expect(blinkPendingMs() == null);
    // 0.1 s of idle: the caret is still in its solid half, and the next toggle is 0.4 s away.
    e.tickBlink(0.1);
    try testing.expectEqual(@as(?u32, 400), blinkPendingMs());
    // A fresh frame starts a fresh schedule; 0.5 s lands exactly on a toggle.
    beginBlinkFrame();
    e.tickBlink(0.4);
    try testing.expectEqual(@as(?u32, 500), blinkPendingMs());
    // An unfocused field schedules nothing, so a window with no focused caret never wakes for one.
    beginBlinkFrame();
    e.focused = false;
    e.tickBlink(0.2);
    try testing.expect(blinkPendingMs() == null);
}

test "an unfocused editor draws no caret and holds its blink clock at zero" {
    var buf: [32]u8 = undefined;
    var e = Editor.init(&buf);
    _ = e.insertSlice("select");
    try testing.expect(caretVisible(&e));
    // Losing focus stops the blink AND resets the clock, so coming back shows a solid caret instead of landing mid-blink.
    e.focused = false;
    e.tickBlink(0.9);
    try testing.expect(!caretVisible(&e));
    try testing.expectEqual(@as(f32, 0), e.idle);
    e.focused = true;
    try testing.expect(caretVisible(&e));
}

test "an arrow, Home, End or a word jump brings the caret back solid instead of leaving it mid-blink" {
    var buf: [32]u8 = undefined;
    var e = Editor.init(&buf);
    _ = e.insertSlice("one two");
    // Mid-blink: the caret is in its OFF half, which is where an arrow used to leave it, so a move looked like a vanishing caret.
    e.idle = 0.9;
    try testing.expect(!caretVisible(&e));
    e.moveLeft(false);
    try testing.expect(caretVisible(&e));
    try testing.expectEqual(@as(f32, 0), e.idle);

    e.idle = 0.6;
    e.moveRight(false);
    try testing.expect(caretVisible(&e));

    e.idle = 0.7;
    e.moveHome(false);
    try testing.expect(caretVisible(&e));

    e.idle = 0.8;
    e.moveEnd(false);
    try testing.expect(caretVisible(&e));

    e.idle = 0.9;
    e.moveWordLeft(false);
    try testing.expect(caretVisible(&e));

    e.idle = 0.9;
    e.moveWordRight(false);
    try testing.expect(caretVisible(&e));

    // A shift-move extends the selection and restarts the blink the same way: the active end has to be visible to be dragged.
    e.idle = 0.9;
    e.moveLeft(true);
    try testing.expect(caretVisible(&e));
}

test "backspace, delete and the arrows step over a whole multi-byte codepoint" {
    var buf: [32]u8 = undefined;
    var e = Editor.init(&buf);
    _ = e.insertSlice("a\xc3\xa9b");
    try testing.expectEqual(@as(usize, 4), e.len);
    // Left from the end lands before `b`, then before `\xc3\xa9` -- one move, not two.
    e.moveLeft(false);
    try testing.expectEqual(@as(usize, 3), e.caret.offset);
    e.moveLeft(false);
    try testing.expectEqual(@as(usize, 1), e.caret.offset);
    e.moveRight(false);
    try testing.expectEqual(@as(usize, 3), e.caret.offset);
    // Backspace removes the two bytes of `\xc3\xa9`, leaving valid UTF-8.
    e.backspace();
    try testing.expectEqualStrings("ab", e.text());
    // Delete-forward removes a whole codepoint too.
    e.setCaret(0, false);
    e.deleteForward();
    try testing.expectEqualStrings("b", e.text());
}

test "a bare arrow collapses a selection instead of moving the caret" {
    var buf: [16]u8 = undefined;
    var e = Editor.init(&buf);
    _ = e.insertSlice("abcd");
    e.setCaret(3, false);
    e.setCaret(1, true);
    e.moveRight(false);
    try testing.expectEqual(@as(usize, 1), e.caret.offset);
    try testing.expect(!e.caret.hasSelection());
    e.setCaret(1, false);
    e.setCaret(3, true);
    e.moveLeft(false);
    try testing.expectEqual(@as(usize, 3), e.caret.offset);
    try testing.expect(!e.caret.hasSelection());
}

test "a click never lands inside a multi-byte codepoint" {
    var buf: [16]u8 = undefined;
    var e = Editor.init(&buf);
    _ = e.insertSlice("\xc3\xa9a");
    // Byte column 1 is the middle of `e-acute`, so the click snaps back to its start.
    e.clickAt(10, 10, false);
    try testing.expectEqual(@as(usize, 0), e.caret.offset);
    // Byte column 2 is the `a`.
    e.clickAt(20, 10, false);
    try testing.expectEqual(@as(usize, 2), e.caret.offset);
}

test "copy and cut hand back the selection, and paste puts a run back in its place" {
    var buf: [32]u8 = undefined;
    var e = Editor.init(&buf);
    _ = e.insertSlice("SELECT name");
    // Select `name`.
    e.setCaret(14, false);
    e.setCaret(7, true);
    var out: [32]u8 = undefined;
    try testing.expectEqualStrings("name", copySelection(&e, &out).?);
    // Copying leaves the text alone.
    try testing.expectEqualStrings("SELECT name", e.text());

    try testing.expectEqualStrings("name", cutSelection(&e, &out).?);
    try testing.expectEqualStrings("SELECT ", e.text());

    try testing.expectEqual(Action.edited, paste(&e, "id, name"));
    try testing.expectEqualStrings("SELECT id, name", e.text());

    // With no selection there is nothing to copy or cut.
    try testing.expect(copySelection(&e, &out) == null);
    try testing.expect(cutSelection(&e, &out) == null);
}

test "paste replaces a selection instead of doubling it" {
    var buf: [32]u8 = undefined;
    var e = Editor.init(&buf);
    _ = e.insertSlice("abc");
    e.setCaret(0, false);
    e.setCaret(3, true);
    try testing.expectEqual(Action.edited, paste(&e, "xy"));
    try testing.expectEqualStrings("xy", e.text());
}

test "handleText inserts a composed run and restarts the blink" {
    var buf: [32]u8 = undefined;
    var e = Editor.init(&buf);
    e.idle = 2.5;
    try testing.expectEqual(Action.edited, handleText(&e, "A"));
    try testing.expectEqualStrings("A", e.text());
    try testing.expectEqual(@as(f32, 0), e.idle);
    try testing.expectEqual(Action.edited, handleText(&e, "*("));
    try testing.expectEqualStrings("A*(", e.text());
    try testing.expectEqual(@as(usize, 3), e.caret.offset);
}

test "handleText inserts multi-byte UTF-8 whole and ignores an empty run" {
    var buf: [32]u8 = undefined;
    var e = Editor.init(&buf);
    try testing.expectEqual(Action.edited, handleText(&e, "\xc3\xa9"));
    try testing.expectEqualStrings("\xc3\xa9", e.text());
    try testing.expectEqual(@as(usize, 2), e.caret.offset);
    try testing.expectEqual(Action.ignored, handleText(&e, ""));
    try testing.expectEqual(@as(usize, 2), e.len);
}

test "keyChar maps every letter to its real evdev code" {
    // The evdev letter codes are NOT contiguous: q=16, a=30, z=44, and the run 30..38 stops at L, not M.
    const cases = [_]struct { ch: u8, code: u32 }{
        .{ .ch = 'q', .code = 16 }, .{ .ch = 'p', .code = 25 },
        .{ .ch = 'a', .code = 30 }, .{ .ch = 'l', .code = 38 },
        .{ .ch = 'z', .code = 44 }, .{ .ch = 'm', .code = 50 },
    };
    for (cases) |c| {
        try testing.expectEqual(@as(?u8, c.ch), keyChar(c.code, false));
        try testing.expectEqual(@as(?u8, std.ascii.toUpper(c.ch)), keyChar(c.code, true));
    }
}

test "keyChar maps the digits and the SQL punctuation" {
    try testing.expectEqual(@as(?u8, '1'), keyChar(2, false));
    try testing.expectEqual(@as(?u8, '0'), keyChar(11, false));
    try testing.expectEqual(@as(?u8, '!'), keyChar(2, true));
    try testing.expectEqual(@as(?u8, '&'), keyChar(8, true)); // shifted 7
    try testing.expectEqual(@as(?u8, '*'), keyChar(9, true)); // shifted 8
    // The characters a query actually needs, checked through the INVERSE so the two tables cannot drift apart in the test itself.
    const needed = [_]u8{ ' ', '*', '=', ',', '.', '/', 0x27, '_', '<', '>' };
    for (needed) |ch| {
        const stroke = keyCodeFor(ch) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(?u8, ch), keyChar(stroke.code, stroke.shift));
    }
}

test "an unmapped key returns null rather than a placeholder" {
    try testing.expectEqual(@as(?u8, null), keyChar(KEY_LEFT, false));
    try testing.expectEqual(@as(?u8, null), keyChar(KEY_ENTER, false));
    try testing.expectEqual(@as(?u8, null), keyChar(999, false));
}

test "keyCodeFor is the exact inverse of keyChar" {
    // The E2E test types through keyCodeFor, so the two must agree for every character a query uses -- or the test would pass on a keyboard that types the.
    const text = "SELECT name, score FROM users WHERE id > 1 AND x <= 2";
    for (text) |ch| {
        const stroke = keyCodeFor(ch) orelse {
            std.debug.print("no keycode for this character", .{});
            return error.TestUnexpectedResult;
        };
        try testing.expectEqual(@as(?u8, ch), keyChar(stroke.code, stroke.shift));
    }
}

test "keyCodeFor covers upper case and shifted symbols" {
    try testing.expectEqual(@as(u32, 30), keyCodeFor('a').?.code);
    try testing.expectEqual(@as(u32, 30), keyCodeFor('A').?.code);
    try testing.expect(keyCodeFor('A').?.shift);
    try testing.expect(!keyCodeFor('a').?.shift);
    try testing.expectEqual(@as(u32, 12), keyCodeFor('_').?.code);
    try testing.expectEqual(@as(u32, 57), keyCodeFor(' ').?.code);
}

test "typing through handleKey produces the SQL" {
    var buf: [64]u8 = undefined;
    var e = Editor.init(&buf);
    // Seed with a slice, then prove the KEY path appends the right byte, using the shared inverse so the test cannot disagree with keyChar.
    _ = e.insertSlice("SELE");
    const stroke = keyCodeFor('c') orelse return error.TestUnexpectedResult;
    try testing.expectEqual(handleKey(&e, stroke.code, stroke.shift, false), Action.edited);
    try testing.expectEqualStrings("SELEc", e.text());
}

test "a 4 KB buffer holds a realistic query" {
    var buf: [4096]u8 = undefined;
    var e = Editor.init(&buf);
    const q =
        \\SELECT u.id, u.name, COUNT(p.id) AS posts
        \\FROM users u
        \\LEFT JOIN posts p ON p.user_id = u.id
        \\WHERE u.active = 1 AND u.created_at > '2024-01-01'
        \\GROUP BY u.id, u.name
        \\HAVING COUNT(p.id) > 0
        \\ORDER BY posts DESC
        \\LIMIT 50
    ;
    const n = e.insertSlice(q);
    try testing.expectEqual(q.len, n);
    try testing.expectEqualStrings(q, e.text());
    try testing.expectEqual(@as(usize, 8), e.lineCount());
}

test "setText truncates rather than overflowing" {
    var buf: [8]u8 = undefined;
    var e = Editor.init(&buf);
    e.setText("a much longer string");
    try testing.expectEqual(@as(usize, 8), e.len);
    try testing.expectEqualStrings("a much l", e.text());
}

// Rendering

// Copy `text` into `buf`, truncated to fit. Never writes past the end.
pub fn clampTo(text: []const u8, buf: []u8) []const u8 {
    const n = @min(text.len, buf.len -| 1);
    // Overlap-tolerant: the destination is a scratch buffer the caller may have carved out of the very text being copied.
    @memmove(buf[0..n], text[0..n]);
    return buf[0..n];
}

// Render one editor line with a visible caret, into `buf`. A one-run fallback for a renderer that can only emit one text run per line: the caret becomes

// a `|` glyph. A real UI should not use this. The bar is a glyph, so it takes a character cell and the tail of the line shifts every time it blinks;

// draw a 1px box at `column * char_width` instead (meja's `editor.caret` does).
pub fn renderLineWithCaret(line_text: []const u8, caret_at: ?usize, buf: []u8) []const u8 {
    const at = caret_at orelse return clampTo(line_text, buf);
    if (buf.len == 0) return buf[0..0];

    const caret = @min(at, line_text.len);
    // A visible bar INSERTED at the caret, not a space that replaces the character under it: a space is invisible, which is why the editor looked like it

    // had no cursor at all.
    const head = @min(caret, buf.len -| 1);
    @memmove(buf[0..head], line_text[0..head]);

    var written = head;
    if (written < buf.len) {
        buf[written] = '|';
        written += 1;
    }
    var i = caret;
    while (i < line_text.len and written < buf.len) : (i += 1) {
        buf[written] = line_text[i];
        written += 1;
    }
    return buf[0..written];
}

test "the caret lands at the caret position" {
    var buf: [64]u8 = undefined;
    // "SELECT" with the caret at index 3: "SEL" + marker + "ECT".
    const out = renderLineWithCaret("SELECT", 3, &buf);
    try testing.expectEqual(@as(usize, 7), out.len);
    try testing.expectEqualStrings("SEL", out[0..3]);
    try testing.expectEqual(@as(u8, '|'), out[3]);
    try testing.expectEqualStrings("ECT", out[4..7]);
}

test "a caret on a space is drawn as a bar, and the space survives" {
    var buf: [64]u8 = undefined;
    // "a b", caret on the space at index 1.
    try testing.expectEqualStrings("a| b", renderLineWithCaret("a b", 1, &buf));
}

test "a caret on a letter is drawn as a space" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("ab|", renderLineWithCaret("ab", 2, &buf));
}

test "a caret past the end of the line still renders" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("abc|", renderLineWithCaret("abc", 99, &buf));
}

test "an empty line with a caret renders one space" {
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("|", renderLineWithCaret("", 0, &buf));
}

test "no caret just clamps the text" {
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("abcdefgh"[0..7], renderLineWithCaret("abcdefgh", null, &buf));
}

test "rendering never writes past the buffer" {
    // The regression this guards: the destination was sized from the TEXT length and a trailing NUL was written past it, so any line that filled the buffer.
    var tiny: [1]u8 = undefined;
    try testing.expect(renderLineWithCaret("hello world", 3, &tiny).len <= tiny.len);

    var exact: [12]u8 = undefined;
    try testing.expect(renderLineWithCaret("hello world", 0, &exact).len <= exact.len);

    var zero: [0]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), renderLineWithCaret("abc", 1, &zero).len);
}

test "clampTo never writes past the buffer" {
    var buf: [4]u8 = undefined;
    try testing.expectEqualStrings("abc", clampTo("abcdefgh", &buf));
    var one: [1]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), clampTo("abc", &one).len);
}

fn isWordByte(b: u8) bool {
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9') or b == '_';
}

test "ctrl+arrow, ctrl+end and ctrl+backspace reach a word, not a byte" {
    var buf: [64]u8 = undefined;
    var e = Editor.init(&buf);
    _ = e.insertSlice("one two\nthree four");
    try testing.expectEqual(@as(usize, 18), e.len);

    // A bare arrow moves one byte; with ctrl it moves a word, which is what a keyboard user needs in a long URL.
    e.setCaret(0, false);
    _ = handleKey(&e, KEY_RIGHT, false, false);
    try testing.expectEqual(@as(usize, 1), e.caret.offset);
    _ = handleKey(&e, KEY_RIGHT, false, true);
    try testing.expectEqual(@as(usize, 4), e.caret.offset);
    _ = handleKey(&e, KEY_RIGHT, false, true);
    try testing.expectEqual(@as(usize, 8), e.caret.offset);

    // Ctrl+End is the end of the whole text, not of the line the caret is on.
    _ = handleKey(&e, KEY_END, false, true);
    try testing.expectEqual(@as(usize, 18), e.caret.offset);

    // Ctrl+Backspace takes the word before the caret, and leaves the rest alone.
    _ = handleKey(&e, KEY_BACKSPACE, false, true);
    try testing.expectEqualStrings("one two\nthree ", e.text());
    try testing.expectEqual(@as(usize, 14), e.caret.offset);
}

// ---- undo and redo: a word is one step, and a run ends at a space, a newline, or a caret that moved ----

// An editor that can remember: it needs an allocator, because a step is a copy of the text it replaced.
fn undoEditor(buf: []u8) Editor {
    return Editor.initWithRoom(buf, testing.allocator);
}

test "a run of typing is one step, and undo takes the whole word back" {
    var buf: [64]u8 = undefined;
    var e = undoEditor(&buf);
    defer e.deinit();

    _ = e.insertSlice("hello");
    // The caret moved between runs, so the next word is a step of its own.
    e.setCaret(e.len, false);
    _ = e.insertSlice(" world");
    try testing.expectEqualStrings("hello world", e.text());

    try testing.expect(e.canUndo());
    try testing.expect(e.undo());
    try testing.expectEqualStrings("hello", e.text());
    try testing.expect(e.undo());
    try testing.expectEqualStrings("", e.text());
    try testing.expect(!e.canUndo());
    try testing.expect(!e.undo());
}

test "typing byte by byte is one step until a space, and then the next word is its own" {
    var buf: [64]u8 = undefined;
    var e = undoEditor(&buf);
    defer e.deinit();

    for ("ab") |c| _ = e.insertByte(c);
    _ = e.insertByte(' ');
    for ("cd") |c| _ = e.insertByte(c);
    try testing.expectEqualStrings("ab cd", e.text());

    // A step holds the text as it was BEFORE the run, so the first undo drops the word and keeps the space it followed.
    try testing.expect(e.undo());
    try testing.expectEqualStrings("ab ", e.text());
    try testing.expect(e.undo());
    try testing.expectEqualStrings("", e.text());
}

test "redo puts back what undo took, and a fresh edit drops the steps ahead" {
    var buf: [64]u8 = undefined;
    var e = undoEditor(&buf);
    defer e.deinit();

    _ = e.insertSlice("one");
    e.setCaret(e.len, false);
    _ = e.insertSlice(" two");
    try testing.expect(e.undo());
    try testing.expectEqualStrings("one", e.text());
    try testing.expect(e.canRedo());
    try testing.expect(e.redo());
    try testing.expectEqualStrings("one two", e.text());
    try testing.expect(!e.canRedo());

    // Undo again, then type: the future that was undone is gone.
    try testing.expect(e.undo());
    _ = e.insertSlice("!");
    try testing.expectEqualStrings("one!", e.text());
    try testing.expect(!e.canRedo());
}

test "undo puts the caret back where the edit happened" {
    var buf: [64]u8 = undefined;
    var e = undoEditor(&buf);
    defer e.deinit();

    _ = e.insertSlice("abcdef");
    e.setCaret(3, false);
    _ = e.insertSlice("XY");
    try testing.expectEqualStrings("abcXYdef", e.text());
    try testing.expect(e.undo());
    try testing.expectEqualStrings("abcdef", e.text());
    try testing.expectEqual(@as(usize, 3), e.caret.offset);
}

test "a paste is one step however long it is, and a selection delete is one too" {
    var buf: [4]u8 = undefined;
    var e = undoEditor(&buf);
    defer e.deinit();

    _ = e.insertSlice("start ");
    _ = e.insertSlice("a whole pasted run");
    try testing.expectEqualStrings("start a whole pasted run", e.text());
    try testing.expect(e.undo());
    try testing.expectEqualStrings("start ", e.text());

    // A selection deleted as one gesture comes back as one step, with the selection it was.
    e.selectAll();
    try testing.expect(e.deleteSelection());
    try testing.expectEqualStrings("", e.text());
    try testing.expect(e.undo());
    try testing.expectEqualStrings("start ", e.text());
}

test "an editor with no allocator has no history, and undo is a no-op rather than a crash" {
    var buf: [16]u8 = undefined;
    var e = Editor.init(&buf);
    _ = e.insertSlice("abc");
    try testing.expect(!e.canUndo());
    try testing.expect(!e.undo());
    try testing.expect(!e.redo());
    try testing.expectEqualStrings("abc", e.text());
}

test "the history stops at its step cap and keeps the newest steps" {
    var buf: [64]u8 = undefined;
    var e = undoEditor(&buf);
    defer e.deinit();

    // Every byte is its own run because each one moves the caret back to the end first.
    var i: usize = 0;
    while (i < history_steps + 10) : (i += 1) {
        e.setCaret(e.len, false);
        _ = e.insertByte('a');
    }
    try testing.expectEqual(@as(usize, history_steps), e.hist.undo.items.len);
    // The newest step is still the one the last keystroke took, so undo works from the end of the buffer.
    try testing.expectEqual(@as(usize, history_steps + 10), e.text().len);
    try testing.expect(e.undo());
    try testing.expectEqual(@as(usize, history_steps + 9), e.text().len);
}
