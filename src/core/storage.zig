//! Persistence as a value: a bounded document with a version, and the slot a host's bytes pass through.
const std = @import("std");

/// The newest document this build writes. A payload numbered higher came from a newer build and is refused rather than guessed at.
pub const current_version: u32 = 2;

/// The largest document a host may hand back or be asked to store, in bytes of JSON.
pub const max_document_bytes: usize = 4096;

/// How many settings a document holds, and how long one key or one value may be.
pub const max_entries: usize = 16;
pub const max_key: usize = 16;
pub const max_value: usize = 128;

/// One setting: a bounded key and a bounded value. A document is a value type, so it cannot grow and cannot fail to allocate.
pub const Entry = struct {
    key: [max_key]u8 = .{0} ** max_key,
    key_len: u8 = 0,
    value: [max_value]u8 = .{0} ** max_value,
    value_len: u8 = 0,

    pub fn name(self: *const Entry) []const u8 {
        return self.key[0..self.key_len];
    }

    pub fn text(self: *const Entry) []const u8 {
        return self.value[0..self.value_len];
    }
};

/// What an app keeps: named settings, a version, and the two calls that turn it into the bytes a host stores.
pub const Document = struct {
    version: u32 = current_version,
    entries: [max_entries]Entry = .{Entry{}} ** max_entries,
    count: usize = 0,

    /// The value stored under `key`, or null when the document has no such setting.
    pub fn get(self: *const Document, key: []const u8) ?[]const u8 {
        for (self.entries[0..self.count]) |*entry| {
            if (std.mem.eql(u8, entry.name(), key)) return entry.text();
        }
        return null;
    }

    /// Store `value` under `key`, replacing an existing setting in place. False when the key or value is too long, or the document is full.
    pub fn set(self: *Document, key: []const u8, value: []const u8) bool {
        if (key.len == 0 or key.len > max_key or value.len > max_value) return false;
        const slot = self.find(key) orelse blk: {
            if (self.count == max_entries) return false;
            const index = self.count;
            self.count += 1;
            break :blk index;
        };
        const entry = &self.entries[slot];
        @memset(entry.key[0..], 0);
        @memset(entry.value[0..], 0);
        @memcpy(entry.key[0..key.len], key);
        @memcpy(entry.value[0..value.len], value);
        entry.key_len = @intCast(key.len);
        entry.value_len = @intCast(value.len);
        return true;
    }

    /// Forget `key`. False when the document never had it.
    pub fn remove(self: *Document, key: []const u8) bool {
        const index = self.find(key) orelse return false;
        const last = self.count - 1;
        var i = index;
        while (i < last) : (i += 1) self.entries[i] = self.entries[i + 1];
        self.entries[last] = .{};
        self.count = last;
        return true;
    }

    /// A setting read as a flag: `1` is on, `0` is off, and anything else is not a flag at all.
    pub fn getBool(self: *const Document, key: []const u8) ?bool {
        const raw = self.get(key) orelse return null;
        if (std.mem.eql(u8, raw, "1")) return true;
        if (std.mem.eql(u8, raw, "0")) return false;
        return null;
    }

    pub fn setBool(self: *Document, key: []const u8, on: bool) bool {
        return self.set(key, if (on) "1" else "0");
    }

    /// A setting read as a non-negative integer, or null when it is not one.
    pub fn getInt(self: *const Document, key: []const u8) ?u32 {
        const raw = self.get(key) orelse return null;
        if (raw.len == 0) return null;
        return std.fmt.parseInt(u32, raw, 10) catch null;
    }

    pub fn setInt(self: *Document, key: []const u8, value: u32) bool {
        var buf: [10]u8 = undefined;
        const raw = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return false;
        return self.set(key, raw);
    }

    /// The document as the bytes a host stores. Null when `buf` cannot hold them.
    pub fn encode(self: *const Document, buf: []u8) ?[]const u8 {
        var w = Writer{ .buf = buf };
        w.put("{\"v\":");
        w.putInt(self.version);
        w.put(",\"e\":{");
        for (self.entries[0..self.count], 0..) |*entry, i| {
            if (i != 0) w.put(",");
            w.putString(entry.name());
            w.put(":");
            w.putString(entry.text());
        }
        w.put("}}");
        if (!w.ok) return null;
        return buf[0..w.n];
    }

    /// Read the bytes a host stored. Null when they are not a document this build can read.
    pub fn decode(bytes: []const u8) ?Document {
        var doc = Document{};
        var r = Reader{ .bytes = bytes };
        if (!r.expect('{')) return null;
        var version: u32 = 1;
        var closed = r.atClose();
        while (!closed) {
            var key_buf: [max_key]u8 = undefined;
            const key = r.readString(&key_buf) orelse return null;
            if (!r.expect(':')) return null;
            if (std.mem.eql(u8, key, "v")) {
                const raw = r.readNumber() orelse return null;
                if (raw > std.math.maxInt(u32)) return null;
                version = @intCast(raw);
            } else if (std.mem.eql(u8, key, "e")) {
                if (!r.expect('{')) return null;
                var entries_closed = r.atClose();
                while (!entries_closed) {
                    var entry_key: [max_key]u8 = undefined;
                    const name = r.readString(&entry_key) orelse return null;
                    if (!r.expect(':')) return null;
                    var entry_value: [max_value]u8 = undefined;
                    const text = r.readString(&entry_value) orelse return null;
                    _ = doc.set(name, text);
                    entries_closed = !(r.nextMember() orelse return null);
                }
            } else {
                if (!r.skipValue()) return null;
            }
            closed = !(r.nextMember() orelse return null);
        }
        // Trailing bytes mean the payload is not the document it claims to be: refuse it rather than half-apply it.
        if (r.peek() != null) return null;
        if (version > current_version) return null;
        migrate(&doc, version);
        return doc;
    }

    fn find(self: *const Document, key: []const u8) ?usize {
        for (self.entries[0..self.count], 0..) |*entry, i| {
            if (std.mem.eql(u8, entry.name(), key)) return i;
        }
        return null;
    }
};

/// Bring an older payload forward: version 1 wrote flags as the words `JSON.stringify` gives, version 2 writes `1` and `0`.
fn migrate(doc: *Document, version: u32) void {
    if (version < 2) {
        for ([_][]const u8{ "dense", "checked", "toggled" }) |key| {
            const raw = doc.get(key) orelse continue;
            if (std.mem.eql(u8, raw, "true")) {
                _ = doc.set(key, "1");
            } else if (std.mem.eql(u8, raw, "false")) {
                _ = doc.set(key, "0");
            }
        }
    }
    doc.version = current_version;
}

/// How many keys or array elements a value this build does not know may nest: deeper is refused rather than guessed at.
const max_nesting: usize = 16;

/// A cursor into the document a host stored, tolerant by design: an unknown key is skipped, not refused.
const Reader = struct {
    bytes: []const u8,
    i: usize = 0,

    fn peek(self: *Reader) ?u8 {
        while (self.i < self.bytes.len) : (self.i += 1) {
            switch (self.bytes[self.i]) {
                ' ', '\t', '\n', '\r' => {},
                else => return self.bytes[self.i],
            }
        }
        return null;
    }

    fn atClose(self: *Reader) bool {
        const c = self.peek() orelse return false;
        if (c != '}') return false;
        self.i += 1;
        return true;
    }

    /// After one member of an object: true when a comma says another follows, false when the object closed. Null on a syntax error.
    fn nextMember(self: *Reader) ?bool {
        const c = self.peek() orelse return null;
        if (c == ',') {
            self.i += 1;
            return true;
        }
        if (c == '}') {
            self.i += 1;
            return false;
        }
        return null;
    }

    fn expect(self: *Reader, want: u8) bool {
        const c = self.peek() orelse return false;
        if (c != want) return false;
        self.i += 1;
        return true;
    }

    fn readNumber(self: *Reader) ?u64 {
        var value: u64 = 0;
        var digits: usize = 0;
        while (self.i < self.bytes.len) : (self.i += 1) {
            const c = self.bytes[self.i];
            if (c < '0' or c > '9') break;
            value = std.math.mul(u64, value, 10) catch return null;
            value = std.math.add(u64, value, c - '0') catch return null;
            digits += 1;
        }
        if (digits == 0) return null;
        return value;
    }

    /// A quoted string, written into `dst`. A string longer than the buffer is truncated rather than refused: the value is bounded, the payload is not.
    fn readString(self: *Reader, dst: []u8) ?[]const u8 {
        if (!self.expect('"')) return null;
        var n: usize = 0;
        while (self.i < self.bytes.len) {
            const c = self.bytes[self.i];
            self.i += 1;
            if (c == '"') return dst[0..n];
            var ch = c;
            if (c == '\\') {
                const esc = if (self.i < self.bytes.len) self.bytes[self.i] else return null;
                self.i += 1;
                ch = switch (esc) {
                    '"' => '"',
                    '\\' => '\\',
                    '/' => '/',
                    'b' => 8,
                    'f' => 12,
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    'u' => blk: {
                        if (self.i + 4 > self.bytes.len) return null;
                        const code = std.fmt.parseInt(u16, self.bytes[self.i..][0..4], 16) catch return null;
                        self.i += 4;
                        break :blk if (code < 0x80) @as(u8, @intCast(code)) else '?';
                    },
                    else => return null,
                };
            }
            if (n < dst.len) {
                dst[n] = ch;
                n += 1;
            }
        }
        return null;
    }

    /// Step over a value whose key this build does not know, so a newer payload still reads.
    fn skipValue(self: *Reader) bool {
        const c = self.peek() orelse return false;
        switch (c) {
            '"' => return self.skipString(),
            '{', '[' => {
                // A bounded stack of openers: deeper than this is not a document this build wrote, and `{"a":1]` is refused.
                var openers: [max_nesting]u8 = undefined;
                var depth: usize = 0;
                while (self.i < self.bytes.len) {
                    const ch = self.bytes[self.i];
                    // A string is stepped over whole: a brace inside it is text, not structure.
                    if (ch == '"') {
                        if (!self.skipString()) return false;
                        continue;
                    }
                    self.i += 1;
                    switch (ch) {
                        '{', '[' => {
                            if (depth == openers.len) return false;
                            openers[depth] = ch;
                            depth += 1;
                        },
                        '}', ']' => {
                            if (depth == 0) return false;
                            const opener = openers[depth - 1];
                            if ((ch == '}') != (opener == '{')) return false;
                            depth -= 1;
                            if (depth == 0) return true;
                        },
                        else => {},
                    }
                }
                return false;
            },
            't' => return self.skipWord("true"),
            'f' => return self.skipWord("false"),
            'n' => return self.skipWord("null"),
            else => return self.readNumber() != null,
        }
    }

    /// Step over a quoted string, escapes and all, without copying it; a `\uXXXX` needs no case, its hex digits cannot be a quote.
    fn skipString(self: *Reader) bool {
        if (!self.expect('"')) return false;
        while (self.i < self.bytes.len) {
            const c = self.bytes[self.i];
            self.i += 1;
            if (c == '\\') {
                if (self.i >= self.bytes.len) return false;
                self.i += 1;
                continue;
            }
            if (c == '"') return true;
        }
        return false;
    }

    fn skipWord(self: *Reader, word: []const u8) bool {
        if (self.i + word.len > self.bytes.len) return false;
        if (!std.mem.eql(u8, self.bytes[self.i..][0..word.len], word)) return false;
        self.i += word.len;
        return true;
    }
};

/// A bounded JSON writer: no allocator, no formatting, and a `null` result the moment the caller's buffer runs out.
const Writer = struct {
    buf: []u8,
    n: usize = 0,
    ok: bool = true,

    fn put(self: *Writer, bytes: []const u8) void {
        if (!self.ok) return;
        if (self.n + bytes.len > self.buf.len) {
            self.ok = false;
            return;
        }
        @memcpy(self.buf[self.n..][0..bytes.len], bytes);
        self.n += bytes.len;
    }

    fn putInt(self: *Writer, value: u64) void {
        var tmp: [20]u8 = undefined;
        const raw = std.fmt.bufPrint(&tmp, "{d}", .{value}) catch {
            self.ok = false;
            return;
        };
        self.put(raw);
    }

    fn putString(self: *Writer, text: []const u8) void {
        self.put("\"");
        for (text) |c| {
            switch (c) {
                '"' => self.put("\\\""),
                '\\' => self.put("\\\\"),
                '\n' => self.put("\\n"),
                '\r' => self.put("\\r"),
                '\t' => self.put("\\t"),
                else => {
                    if (c < 0x20) {
                        const hex = "0123456789abcdef";
                        self.put(&[_]u8{ '\\', 'u', '0', '0', hex[(c >> 4) & 0xf], hex[c & 0xf] });
                    } else {
                        self.put(&[_]u8{c});
                    }
                },
            }
        }
        self.put("\"");
    }
};

/// The bytes one host and one app exchange: what the host handed back, and what the app wants stored.
pub const Slot = struct {
    adopted: [max_document_bytes]u8 = .{0} ** max_document_bytes,
    adopted_len: usize = 0,
    pending_adopt: bool = false,
    staged: [max_document_bytes]u8 = .{0} ** max_document_bytes,
    staged_len: usize = 0,
    dirty: bool = false,
    revision_count: u32 = 1,

    /// The host's bytes arriving: a page's IndexedDB read, a file's contents. False when they do not fit.
    pub fn adopt(self: *Slot, bytes: []const u8) bool {
        if (bytes.len > max_document_bytes) return false;
        @memcpy(self.adopted[0..bytes.len], bytes);
        self.adopted_len = bytes.len;
        self.pending_adopt = true;
        self.revision_count +%= 1;
        return true;
    }

    /// Take the adopted bytes into the caller's buffer, once. Null when nothing arrived, or it was already taken.
    pub fn takeAdopted(self: *Slot, buf: []u8) ?[]const u8 {
        if (!self.pending_adopt) return null;
        self.pending_adopt = false;
        const n = @min(self.adopted_len, buf.len);
        @memcpy(buf[0..n], self.adopted[0..n]);
        return buf[0..n];
    }

    /// The app's document, offered to the host. False when it does not fit.
    pub fn stage(self: *Slot, bytes: []const u8) bool {
        if (bytes.len > max_document_bytes) return false;
        @memcpy(self.staged[0..bytes.len], bytes);
        self.staged_len = bytes.len;
        self.dirty = true;
        return true;
    }

    /// What the host still owes a write, or null when there is nothing pending.
    pub fn stagedBytes(self: *Slot) ?[]const u8 {
        if (!self.dirty) return null;
        return self.staged[0..self.staged_len];
    }

    /// The host confirming it wrote `stagedBytes()`. A second call is a no-op, so a page may be generous.
    pub fn clean(self: *Slot) void {
        self.dirty = false;
        self.staged_len = 0;
    }

    /// Moves on every adopt, so an app can tell that the host answered without comparing bytes.
    pub fn revision(self: *const Slot) u32 {
        return self.revision_count;
    }

    /// A fresh slot: nothing adopted, nothing owed. A new window, or a test starting from a known state.
    pub fn reset(self: *Slot) void {
        self.adopted_len = 0;
        self.pending_adopt = false;
        self.staged_len = 0;
        self.dirty = false;
        self.revision_count +%= 1;
    }
};

// ---- tests ---------------------------------------------------------------------------------------------------

const testing = std.testing;

test "a setting written to a document reads back under the same key" {
    var doc = Document{};
    try testing.expect(doc.get("dense") == null);
    try testing.expect(doc.set("dense", "1"));
    try testing.expectEqualStrings("1", doc.get("dense").?);
    try testing.expect(doc.get("absent") == null);
}

test "writing the same key twice replaces the value instead of growing the document" {
    var doc = Document{};
    try testing.expect(doc.set("tab", "1"));
    try testing.expect(doc.set("tab", "3"));
    try testing.expectEqual(@as(usize, 1), doc.count);
    try testing.expectEqualStrings("3", doc.get("tab").?);
}

test "removing a setting keeps the ones written after it" {
    var doc = Document{};
    try testing.expect(doc.set("a", "1"));
    try testing.expect(doc.set("b", "2"));
    try testing.expect(doc.set("c", "3"));
    try testing.expect(doc.remove("b"));
    try testing.expect(doc.get("b") == null);
    try testing.expectEqualStrings("1", doc.get("a").?);
    try testing.expectEqualStrings("3", doc.get("c").?);
    try testing.expectEqual(@as(usize, 2), doc.count);
    try testing.expect(!doc.remove("b"));
}

test "a document survives a round trip through its encoded bytes" {
    var doc = Document{};
    try testing.expect(doc.set("route", "text-field"));
    try testing.expect(doc.setInt("tab", 2));
    var buf: [max_document_bytes]u8 = undefined;
    const bytes = doc.encode(&buf).?;
    const back = Document.decode(bytes).?;
    try testing.expectEqual(current_version, back.version);
    try testing.expectEqualStrings("text-field", back.get("route").?);
    try testing.expectEqual(@as(?u32, 2), back.getInt("tab"));
}

test "a value carrying quotes, backslashes and newlines survives the round trip" {
    var doc = Document{};
    try testing.expect(doc.set("draft", "a\"b\\c\nd\te"));
    var buf: [max_document_bytes]u8 = undefined;
    const back = Document.decode(doc.encode(&buf).?).?;
    try testing.expectEqualStrings("a\"b\\c\nd\te", back.get("draft").?);
}

test "a key this build does not know is skipped, and the settings around it still read" {
    const payload =
        \\{"v":2,"future":{"nested":[1,2,{"x":"y"}]},"e":{"dense":"1","route":"tabs"}}
    ;
    const doc = Document.decode(payload).?;
    try testing.expectEqualStrings("1", doc.get("dense").?);
    try testing.expectEqualStrings("tabs", doc.get("route").?);
}

test "a brace inside a skipped string is text, not structure" {
    // The nested value is a message a newer build wrote: its `}` must not end the object it sits in.
    const payload =
        \\{"v":2,"note":"a } and a ] walk in","future":{"msg":"ends with }"},"e":{"dense":"1"}}
    ;
    const doc = Document.decode(payload).?;
    try testing.expectEqualStrings("1", doc.get("dense").?);
}

test "a payload whose bytes run past its document, or whose brackets do not pair, is refused" {
    // A truncated write or a corrupted value must fall back to defaults, not half-apply the settings it happens to contain.
    try testing.expect(Document.decode("{\"v\":2,\"e\":{\"dense\":\"1\"}}}") == null);
    try testing.expect(Document.decode("{\"v\":2,\"e\":{\"dense\":\"1\"}} trailing") == null);
    try testing.expect(Document.decode("{\"v\":2,\"future\":{\"a\":1],\"e\":{\"dense\":\"1\"}}") == null);
    try testing.expect(Document.decode("{\"v\":2,\"future\":\"unterminated}") == null);
}

test "a payload with no version is read as version 1 and its flags are migrated" {
    const payload =
        \\{"e":{"dense":"true","checked":"false","route":"tabs"}}
    ;
    const doc = Document.decode(payload).?;
    try testing.expectEqual(current_version, doc.version);
    try testing.expectEqual(@as(?bool, true), doc.getBool("dense"));
    try testing.expectEqual(@as(?bool, false), doc.getBool("checked"));
    try testing.expectEqualStrings("tabs", doc.get("route").?);
}

test "a payload from a newer build is refused rather than guessed at" {
    const payload =
        \\{"v":99,"e":{"dense":"1"}}
    ;
    try testing.expect(Document.decode(payload) == null);
}

test "bytes that are not a document are refused" {
    try testing.expect(Document.decode("") == null);
    try testing.expect(Document.decode("not json") == null);
    try testing.expect(Document.decode("{\"e\":{\"a\"}}") == null);
}

test "an encoded document that does not fit the caller's buffer is refused" {
    var doc = Document{};
    try testing.expect(doc.set("route", "text-field"));
    var small: [8]u8 = undefined;
    try testing.expect(doc.encode(&small) == null);
    var roomy: [max_document_bytes]u8 = undefined;
    try testing.expect(doc.encode(&roomy) != null);
}

test "a setting that cannot fit its bound is refused instead of truncated" {
    var doc = Document{};
    var long_key: [max_key + 1]u8 = undefined;
    @memset(&long_key, 'k');
    try testing.expect(!doc.set(&long_key, "1"));
    var long_value: [max_value + 1]u8 = undefined;
    @memset(&long_value, 'v');
    try testing.expect(!doc.set("route", &long_value));
    try testing.expectEqual(@as(usize, 0), doc.count);
}

test "a full document refuses a new key but still replaces an existing one" {
    var doc = Document{};
    var name: [max_key]u8 = undefined;
    for (0..max_entries) |i| {
        const key = std.fmt.bufPrint(&name, "k{d}", .{i}) catch @panic("a one-digit index fits a key");
        try testing.expect(doc.set(key, "x"));
    }
    try testing.expect(!doc.set("overflow", "x"));
    try testing.expect(doc.set("k0", "y"));
    try testing.expectEqualStrings("y", doc.get("k0").?);
}

test "a slot hands its adopted bytes over exactly once" {
    var slot = Slot{};
    var buf: [max_document_bytes]u8 = undefined;
    try testing.expect(slot.takeAdopted(&buf) == null);
    const before = slot.revision();
    try testing.expect(slot.adopt("{\"v\":2,\"e\":{}}"));
    try testing.expect(slot.revision() != before);
    try testing.expectEqualStrings("{\"v\":2,\"e\":{}}", slot.takeAdopted(&buf).?);
    try testing.expect(slot.takeAdopted(&buf) == null);
}

test "a slot keeps the staged bytes until the host says it wrote them" {
    var slot = Slot{};
    try testing.expect(slot.stagedBytes() == null);
    try testing.expect(slot.stage("{\"v\":2,\"e\":{}}"));
    try testing.expectEqualStrings("{\"v\":2,\"e\":{}}", slot.stagedBytes().?);
    slot.clean();
    try testing.expect(slot.stagedBytes() == null);
}

test "a slot refuses a document larger than it can hold" {
    var slot = Slot{};
    var oversized: [max_document_bytes + 1]u8 = undefined;
    @memset(&oversized, 'x');
    try testing.expect(!slot.adopt(&oversized));
    try testing.expect(!slot.stage(&oversized));
    try testing.expect(slot.stagedBytes() == null);
}

test "reset forgets what was adopted and what was still owed" {
    var slot = Slot{};
    var buf: [max_document_bytes]u8 = undefined;
    _ = slot.adopt("a");
    _ = slot.stage("b");
    slot.reset();
    try testing.expect(slot.takeAdopted(&buf) == null);
    try testing.expect(slot.stagedBytes() == null);
}
