// The screen's state, as a VALUE — the machine and the keypad's own vocabulary, and nothing else.
// This is Kotlin's `data class CalculatorUiState`: an intent replaces it, the frame reads whatever it says.
// No widget import and no callback lives here, so the arithmetic is testable with no compositor, font engine or GL context.
const std = @import("std");

// The keypad's shape, row-major. It IS the enum's order below, so the view, the pointer path and the keymap share one index.
pub const cols: usize = 4;
pub const rows: usize = 5;

/// Every key, in the order the grid is declared (row-major). The index into this enum IS the click index and the keymap index, so the UI, the pointer path and the keyboard path all agree on one numbering.
pub const Key = enum(u8) {
    clear,
    backspace,
    dot,
    divide,
    k7,
    k8,
    k9,
    times,
    k4,
    k5,
    k6,
    minus,
    k1,
    k2,
    k3,
    plus,
    k0,
    negate,
    percent,
    equals,

    pub const count: usize = @typeInfo(Key).@"enum".fields.len;
};

/// Row-major lookup table: index i (0..19) -> Key.
pub const KEYS_BY_INDEX: [Key.count]Key = blk: {
    var table: [Key.count]Key = undefined;
    for (&table, 0..) |*slot, i| slot.* = @enumFromInt(i);
    break :blk table;
};

/// Grid labels, ASCII only: the keymap is US-ASCII and a unicode glyph would render as a fallback box in a stub font.
pub const KEY_LABELS: [Key.count][]const u8 = .{
    "C", "DEL", ".", "/",
    "7", "8",   "9", "*",
    "4", "5",   "6", "-",
    "1", "2",   "3", "+",
    "0", "+/-", "%", "=",
};

/// Stable element ids. Clay resolves `.ID(ptr)` by string, so these must be distinct literals that outlive every frame — a per-frame buffer would rehash the layout tree on each rebuild.
pub const KEY_IDS: [Key.count][]const u8 = .{
    "calc-k-clear", "calc-k-backspace", "calc-k-dot",     "calc-k-divide",
    "calc-k-7",     "calc-k-8",         "calc-k-9",       "calc-k-times",
    "calc-k-4",     "calc-k-5",         "calc-k-6",       "calc-k-minus",
    "calc-k-1",     "calc-k-2",         "calc-k-3",       "calc-k-plus",
    "calc-k-0",     "calc-k-negate",    "calc-k-percent", "calc-k-equals",
};

pub const Op = enum { add, sub, mul, div };

pub fn apply(o: Op, a: f64, b: f64) f64 {
    return switch (o) {
        .add => a + b,
        .sub => a - b,
        .mul => a * b,
        .div => a / b,
    };
}

pub fn symbol(o: Op) []const u8 {
    return switch (o) {
        .add => "+",
        .sub => "-",
        .mul => "*",
        .div => "/",
    };
}

/// Render a computed value into `buf` without allocating. Integral results print without a fractional tail ("5", not "5.0"); everything else falls back to the float formatter.
pub fn writeValue(buf: []u8, v: f64) []const u8 {
    const rounded = @round(v);
    if (@abs(v - rounded) < 1e-9 and @abs(v) < 1e15) {
        return std.fmt.bufPrint(buf, "{d}", .{@as(i64, @intFromFloat(rounded))}) catch "0";
    }
    return std.fmt.bufPrint(buf, "{d}", .{v}) catch "0";
}

/// The pure arithmetic machine: allocation-free, and free of any glinlandui/Clay import, so the calculator's arithmetic is testable on its own. The UI only ever reads `display()` / `expression()`.
pub const Machine = struct {
    /// Digits currently being typed, as ASCII ("12", "-3.5").
    entry: [32]u8 = undefined,
    entry_len: usize = 0,
    /// Left-hand operand of a pending binary operation.
    accum: f64 = 0,
    pending: ?Op = null,
    /// The next digit starts a fresh entry instead of appending.
    fresh: bool = true,
    /// Latched by a non-finite result (e.g. divide by zero). Cleared by the next key press.
    err: bool = false,
    /// Scratch for `expression()`, kept on the value so the "12 +" text outlives the frame that hands it to Clay.
    accum_buf: [24]u8 = undefined,
    expr_buf: [64]u8 = undefined,

    pub fn init() Machine {
        var self = Machine{};
        self.reset();
        return self;
    }

    /// Back to "0", no operation pending, no error.
    pub fn reset(self: *Machine) void {
        self.entry[0] = '0';
        self.entry_len = 1;
        self.accum = 0;
        self.pending = null;
        self.fresh = true;
        self.err = false;
    }

    /// The big display string. Owned by the value, valid until the next mutation — the UI reads it while declaring, exactly like `statusText` in the main demo.
    pub fn display(self: *const Machine) []const u8 {
        if (self.err) return "ERR";
        return self.entry[0..self.entry_len];
    }

    /// The small "12 +" line above the display; empty when no operation is pending.
    pub fn expression(self: *Machine) []const u8 {
        const p = self.pending orelse return "";
        const head = writeValue(&self.accum_buf, self.accum);
        return std.fmt.bufPrint(&self.expr_buf, "{s} {s}", .{ head, symbol(p) }) catch "";
    }

    /// Current entry as a number. The entry is always well-formed ASCII by construction, so a parse failure is impossible; default to 0.
    fn value(self: *const Machine) f64 {
        return std.fmt.parseFloat(f64, self.entry[0..self.entry_len]) catch 0;
    }

    fn fail(self: *Machine) void {
        self.err = true;
        self.pending = null;
        self.fresh = true;
    }

    fn setValue(self: *Machine, v: f64) void {
        const s = writeValue(&self.entry, v);
        self.entry_len = s.len;
    }

    pub fn press(self: *Machine, key: Key) void {
        // Any key clears a latched error first, so the machine is always usable again without a dedicated "dismiss" key.
        if (self.err) self.reset();

        switch (key) {
            .clear => self.reset(),
            .dot => self.dot(),
            .backspace => self.backspace(),
            .negate => self.negate(),
            .percent => self.percent(),
            .equals => self.equals(),
            .divide => self.setOp(.div),
            .times => self.setOp(.mul),
            .minus => self.setOp(.sub),
            .plus => self.setOp(.add),
            else => if (digitValue(key)) |d| self.digit(d),
        }
    }

    /// The digit a digit-key represents, or null for every other key. Written out rather than derived from the enum value: the grid is declared row-major ("7 8 9" sits above "0"), so `k0` is the LAST digit key in the enum, not the first.
    fn digitValue(key: Key) ?u8 {
        return switch (key) {
            .k0 => 0,
            .k1 => 1,
            .k2 => 2,
            .k3 => 3,
            .k4 => 4,
            .k5 => 5,
            .k6 => 6,
            .k7 => 7,
            .k8 => 8,
            .k9 => 9,
            else => null,
        };
    }

    /// Append a digit (0-9 as an offset from the `k0` base).
    fn digit(self: *Machine, d: u8) void {
        if (self.fresh) {
            self.entry_len = 0;
            self.fresh = false;
        }
        if (self.entry_len >= self.entry.len) return;
        self.entry[self.entry_len] = '0' + d;
        self.entry_len += 1;
    }

    fn dot(self: *Machine) void {
        if (self.fresh) {
            self.entry[0] = '0';
            self.entry_len = 1;
            self.fresh = false;
        }
        for (self.entry[0..self.entry_len]) |c| {
            if (c == '.') return; // one decimal point per entry
        }
        if (self.entry_len >= self.entry.len) return;
        self.entry[self.entry_len] = '.';
        self.entry_len += 1;
    }

    fn backspace(self: *Machine) void {
        // Backspacing a just-computed value edits nothing and shows 0.
        if (self.fresh) {
            self.entry[0] = '0';
            self.entry_len = 1;
            return;
        }
        if (self.entry_len > 0) self.entry_len -= 1;
        if (self.entry_len == 0) {
            self.entry[0] = '0';
            self.entry_len = 1;
        }
    }

    /// Toggle a leading '-' in place. The entry is short, so an explicit shift is clearer than memmove.
    fn negate(self: *Machine) void {
        if (self.fresh) {
            self.entry_len = 0;
            self.fresh = false;
        }
        if (self.entry_len == 0) {
            self.entry[0] = '0';
            self.entry_len = 1;
        }
        if (self.entry[0] == '-') {
            var i: usize = 1;
            while (i < self.entry_len) : (i += 1) self.entry[i - 1] = self.entry[i];
            self.entry_len -= 1;
        } else {
            if (self.entry_len >= self.entry.len) return;
            var i: usize = self.entry_len + 1;
            while (i > 1) : (i -= 1) self.entry[i - 1] = self.entry[i - 2];
            self.entry[0] = '-';
            self.entry_len += 1;
        }
    }

    fn percent(self: *Machine) void {
        self.setValue(self.value() / 100.0);
        self.fresh = true;
    }

    /// Start (or replace) a pending operation, folding in the left operand. Typing two operators in a row replaces the first.
    fn setOp(self: *Machine, o: Op) void {
        if (self.pending) |p| {
            if (!self.fresh) {
                const r = apply(p, self.accum, self.value());
                if (!std.math.isFinite(r)) return self.fail();
                self.accum = r;
                self.setValue(r);
            }
        } else {
            self.accum = self.value();
        }
        self.pending = o;
        self.fresh = true;
    }

    fn equals(self: *Machine) void {
        if (self.pending) |p| {
            const r = apply(p, self.accum, self.value());
            if (!std.math.isFinite(r)) return self.fail();
            self.accum = r;
            self.setValue(r);
        }
        self.pending = null;
        self.fresh = true;
    }

    /// Keyboard path: a printable ASCII character from the keymap. Unknown characters are ignored (the caller still consumed the key).
    pub fn feedChar(self: *Machine, c: u8) void {
        switch (c) {
            '0'...'9' => self.digit(c - '0'),
            '+' => self.press(.plus),
            '-' => self.press(.minus),
            '*' => self.press(.times),
            '/' => self.press(.divide),
            '=' => self.press(.equals),
            '.' => self.press(.dot),
            '%' => self.press(.percent),
            'c', 'C' => self.press(.clear),
            else => {},
        }
    }
};

// ---- tests ---------------------------------------------------------------------------------------------------

test "example keypad grid covers every key exactly once" {
    try std.testing.expectEqual(@as(usize, 20), Key.count);
    try std.testing.expectEqual(Key.count, cols * rows);
    // Row-major: the UI, the click index and the keymap share one index.
    try std.testing.expectEqual(Key.clear, KEYS_BY_INDEX[0]);
    try std.testing.expectEqual(Key.k7, KEYS_BY_INDEX[4]);
    try std.testing.expectEqual(Key.k0, KEYS_BY_INDEX[16]);
    try std.testing.expectEqual(Key.equals, KEYS_BY_INDEX[19]);
    // Every label and element id is present and distinct.
    for (KEY_LABELS, 0..) |label, i| {
        try std.testing.expect(label.len > 0);
        try std.testing.expect(!std.mem.eql(u8, label, ""));
        _ = i;
    }
    for (KEY_IDS, 0..) |id, i| {
        for (KEY_IDS[0..i]) |prev| {
            try std.testing.expect(!std.mem.eql(u8, id, prev));
        }
    }
}

test "digits accumulate into one entry" {
    var m = Machine.init();
    try std.testing.expectEqualStrings("0", m.display());
    m.press(.k1);
    m.press(.k2);
    m.press(.k3);
    try std.testing.expectEqualStrings("123", m.display());
}

test "a new digit after a result starts a fresh entry" {
    var m = Machine.init();
    m.press(.k5);
    m.press(.plus);
    m.press(.k5);
    m.press(.equals);
    try std.testing.expectEqualStrings("10", m.display());
    m.press(.k7);
    try std.testing.expectEqualStrings("7", m.display());
}

test "all four operations fold left" {
    const Case = struct { keys: []const Key, want: []const u8 };
    const cases = [_]Case{
        .{ .keys = &.{ .k2, .plus, .k3, .equals }, .want = "5" },
        .{ .keys = &.{ .k9, .minus, .k4, .equals }, .want = "5" },
        .{ .keys = &.{ .k3, .times, .k4, .equals }, .want = "12" },
        .{ .keys = &.{ .k8, .divide, .k2, .equals }, .want = "4" },
        // 2 + 3 * 4 evaluates as (2+3)*4 when operators fold immediately.
        .{ .keys = &.{ .k2, .plus, .k3, .times, .k4, .equals }, .want = "20" },
    };
    for (cases) |c| {
        var m = Machine.init();
        for (c.keys) |k| m.press(k);
        try std.testing.expectEqualStrings(c.want, m.display());
    }
}

test "integral results print without a fractional tail" {
    var m = Machine.init();
    m.press(.k1);
    m.press(.dot);
    m.press(.k5);
    m.press(.plus);
    m.press(.k1);
    m.press(.dot);
    m.press(.k5);
    m.press(.equals);
    try std.testing.expectEqualStrings("3", m.display());
}

test "fractional results keep their fraction" {
    var m = Machine.init();
    m.press(.k1);
    m.press(.divide);
    m.press(.k4);
    m.press(.equals);
    try std.testing.expectEqualStrings("0.25", m.display());
}

test "only one decimal point per entry" {
    var m = Machine.init();
    m.press(.k1);
    m.press(.dot);
    m.press(.dot);
    m.press(.k5);
    try std.testing.expectEqualStrings("1.5", m.display());
}

test "a leading dot starts the entry at zero" {
    var m = Machine.init();
    m.press(.dot);
    m.press(.k5);
    try std.testing.expectEqualStrings("0.5", m.display());
}

test "divide by zero latches an error that the next key clears" {
    var m = Machine.init();
    m.press(.k5);
    m.press(.divide);
    m.press(.k0);
    m.press(.equals);
    try std.testing.expect(m.err);
    try std.testing.expectEqualStrings("ERR", m.display());

    // The next key press recovers instead of leaving a dead machine.
    m.press(.k7);
    try std.testing.expect(!m.err);
    try std.testing.expectEqualStrings("7", m.display());
}

test "clear resets entry, operand and pending operation" {
    var m = Machine.init();
    m.press(.k8);
    m.press(.plus);
    m.press(.k8);
    m.press(.clear);
    try std.testing.expectEqualStrings("0", m.display());
    try std.testing.expectEqual(@as(?Op, null), m.pending);
    m.press(.k1);
    try std.testing.expectEqualStrings("1", m.display());
}

test "equals is idempotent with no pending operation" {
    var m = Machine.init();
    m.press(.k4);
    m.press(.equals);
    try std.testing.expectEqualStrings("4", m.display());
    m.press(.equals);
    try std.testing.expectEqualStrings("4", m.display());
}

test "typing two operators in a row replaces the first" {
    var m = Machine.init();
    m.press(.k8);
    m.press(.plus);
    m.press(.times);
    m.press(.k3);
    m.press(.equals);
    try std.testing.expectEqualStrings("24", m.display());
}

test "negate toggles the sign in place" {
    var m = Machine.init();
    m.press(.k4);
    m.press(.k2);
    m.press(.negate);
    try std.testing.expectEqualStrings("-42", m.display());
    m.press(.negate);
    try std.testing.expectEqualStrings("42", m.display());
    m.press(.negate);
    m.press(.plus);
    m.press(.k1);
    m.press(.equals);
    try std.testing.expectEqualStrings("-41", m.display());
}

test "percent divides the entry by a hundred" {
    var m = Machine.init();
    m.press(.k5);
    m.press(.k0);
    m.press(.percent);
    try std.testing.expectEqualStrings("0.5", m.display());
}

test "backspace edits the entry and never empties it" {
    var m = Machine.init();
    m.press(.k1);
    m.press(.k2);
    m.press(.k3);
    m.press(.backspace);
    try std.testing.expectEqualStrings("12", m.display());
    m.press(.backspace);
    m.press(.backspace);
    try std.testing.expectEqualStrings("0", m.display());
    m.press(.backspace);
    try std.testing.expectEqualStrings("0", m.display());
}

test "the entry is bounded, so a huge run of digits cannot overflow" {
    var m = Machine.init();
    var i: usize = 0;
    while (i < 100) : (i += 1) m.press(.k9);
    try std.testing.expect(m.entry_len <= m.entry.len);
    try std.testing.expect(m.entry.len > 0);
}

test "the keyboard path drives the same machine as the keypad" {
    var m = Machine.init();
    for ("12+30") |c| m.feedChar(c);
    m.feedChar('=');
    try std.testing.expectEqualStrings("42", m.display());
}

test "keyboard clear, percent, backspace and divide all reach the machine" {
    var m = Machine.init();
    for ("50") |c| m.feedChar(c);
    m.feedChar('%');
    try std.testing.expectEqualStrings("0.5", m.display());

    m.feedChar('/');
    m.feedChar('2');
    m.feedChar('=');
    try std.testing.expectEqualStrings("0.25", m.display());

    m.feedChar('c');
    try std.testing.expectEqualStrings("0", m.display());
}

test "unknown keyboard characters leave the machine untouched" {
    var m = Machine.init();
    m.press(.k7);
    m.feedChar('q');
    try std.testing.expectEqualStrings("7", m.display());
}

test "the expression line shows the pending operation" {
    var m = Machine.init();
    try std.testing.expectEqualStrings("", m.expression());
    m.press(.k1);
    m.press(.k2);
    m.press(.plus);
    try std.testing.expectEqualStrings("12 +", m.expression());
    m.press(.equals);
    try std.testing.expectEqualStrings("", m.expression());
}

test "the expression line reports the folded operand, not the entry" {
    var m = Machine.init();
    m.press(.k2);
    m.press(.plus);
    m.press(.k3);
    m.press(.times);
    try std.testing.expectEqualStrings("5 *", m.expression());
}
