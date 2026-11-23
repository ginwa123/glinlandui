//! The network as a value: a request bounded to bytes a page can send, a reply bounded to bytes a page can hand back.
const std = @import("std");

/// The longest origin (scheme, host, port) a page may name, and the longest whole address a request may carry.
pub const max_origin: usize = 128;
pub const max_url: usize = 1024;

/// The most a staged request may weigh: its first line, its headers and its body together.
pub const max_request_bytes: usize = 8192;

/// The most a reply body may weigh, and the most an ETag or a schema version may.
pub const max_body_bytes: usize = 32 * 1024;
pub const max_tag: usize = 64;

/// A reply's status and its two headers as the page writes them: `"<status>\n<etag>\n<version>\n"`.
pub const max_meta_bytes: usize = 5 + 1 + max_tag + 1 + max_tag + 1;

/// The methods this toolkit speaks. A request the shape of a REST API needs, and nothing else.
pub const Method = enum {
    get,
    post,
    patch,
    delete,

    /// The method as HTTP spells it in a request line.
    pub fn text(self: Method) []const u8 {
        return switch (self) {
            .get => "GET",
            .post => "POST",
            .patch => "PATCH",
            .delete => "DELETE",
        };
    }
};

/// One request header, in the order the page will send it.
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// What a page answered: which ticket, the status, the two headers a delta sync needs, and the body.
pub const Reply = struct {
    ticket: u32 = 0,
    status: u16 = 0,
    etag: [max_tag]u8 = .{0} ** max_tag,
    etag_len: u8 = 0,
    version: [max_tag]u8 = .{0} ** max_tag,
    version_len: u8 = 0,
    body: [max_body_bytes]u8 = .{0} ** max_body_bytes,
    body_len: usize = 0,

    /// The body was longer than the slot: the page delivered the status and the headers, and no bytes with them.
    truncated: bool = false,

    /// The `ETag` the page read, without its quotes: the row version a client sends back.
    pub fn etagText(self: *const Reply) []const u8 {
        return self.etag[0..self.etag_len];
    }

    /// The `X-Schema-Version` the page read, or empty when the response carried none.
    pub fn versionText(self: *const Reply) []const u8 {
        return self.version[0..self.version_len];
    }

    pub fn bodyText(self: *const Reply) []const u8 {
        return self.body[0..self.body_len];
    }

    /// A 2xx answer: the shape that carries a resource.
    pub fn ok(self: *const Reply) bool {
        return self.status >= 200 and self.status < 300;
    }

    /// A 304: what the app already holds is still current, and nothing was sent to replace it.
    pub fn notModified(self: *const Reply) bool {
        return self.status == 304;
    }

    /// No answer at all: the page's fetch threw, and the app may try again.
    pub fn failed(self: *const Reply) bool {
        return self.status == 0;
    }
};

/// A status and the two headers, read from the bytes the page wrote. Null when the status is not a status.
pub const Meta = struct {
    status: u16,
    etag: []const u8,
    version: []const u8,
};

pub fn parseMeta(text: []const u8) ?Meta {
    var lines = std.mem.splitScalar(u8, text, '\n');
    const status_text = lines.next() orelse return null;
    const status = std.fmt.parseInt(u16, std.mem.trim(u8, status_text, " \t\r"), 10) catch return null;
    if (status > 599) return null;
    const etag = std.mem.trim(u8, lines.next() orelse "", " \t\r");
    const version = std.mem.trim(u8, lines.next() orelse "", " \t\r");
    return .{ .status = status, .etag = etag, .version = version };
}

/// The bytes one page and one app exchange: the request the app staged, and the answer the page settled.
pub const Slot = struct {
    origin: [max_origin]u8 = .{0} ** max_origin,
    origin_len: usize = 0,
    origin_pending: bool = false,
    staged: [max_request_bytes]u8 = .{0} ** max_request_bytes,
    staged_len: usize = 0,
    owed: bool = false,
    reply: Reply = .{},
    reply_pending: bool = false,
    revision_count: u32 = 1,

    /// The page naming the API it talks to: an address the app prepends to every path. False when it does not fit.
    pub fn setOrigin(self: *Slot, origin: []const u8) bool {
        if (origin.len > max_origin) return false;
        @memset(&self.origin, 0);
        @memcpy(self.origin[0..origin.len], origin);
        self.origin_len = origin.len;
        self.origin_pending = true;
        return true;
    }

    /// The named origin once, so an app reads it on the frame that follows rather than on every frame.
    pub fn takeOrigin(self: *Slot, buf: []u8) ?[]const u8 {
        if (!self.origin_pending) return null;
        self.origin_pending = false;
        const n = @min(self.origin_len, buf.len);
        @memcpy(buf[0..n], self.origin[0..n]);
        return buf[0..n];
    }

    /// The origin as it stands, for an address composed before the app takes it.
    pub fn originBytes(self: *const Slot) []const u8 {
        return self.origin[0..self.origin_len];
    }

    /// Stage a request for the page: `<ticket> <METHOD> <url>`, one `name: value` per header, a blank line, then the body.
    pub fn stage(self: *Slot, ticket: u32, method: Method, url: []const u8, headers: []const Header, body: []const u8) bool {
        // One request at a time from this side: the reply to the last one arrives before the next is written, so a ticket can never overtake.
        if (self.owed) return false;
        var w = Writer{ .buf = &self.staged };
        w.putInt(ticket);
        w.put(" ");
        w.put(method.text());
        w.put(" ");
        w.put(url);
        w.put("\n");
        for (headers) |header| {
            w.put(header.name);
            w.put(": ");
            w.put(header.value);
            w.put("\n");
        }
        w.put("\n");
        w.put(body);
        if (!w.ok) return false;
        self.staged_len = w.n;
        self.owed = true;
        return true;
    }

    /// What the page still owes a send, or null when there is nothing pending.
    pub fn stagedBytes(self: *Slot) ?[]const u8 {
        if (!self.owed) return null;
        return self.staged[0..self.staged_len];
    }

    /// The page confirming it read the request. A second call is a no-op, so a page may be generous.
    pub fn clean(self: *Slot) void {
        self.owed = false;
        self.staged_len = 0;
    }

    /// The page's answer: the ticket it belongs to, the bytes it serialised, and the body it read.
    pub fn settle(self: *Slot, ticket: u32, meta: []const u8, body: []const u8) bool {
        const parsed = parseMeta(meta) orelse return false;
        if (body.len > max_body_bytes) return self.settleOverlong(ticket, meta);
        self.write(ticket, parsed, body);
        return true;
    }

    /// The same answer when the body was longer than the block: the status and the headers arrive, the bytes deliberately do not.
    pub fn settleOverlong(self: *Slot, ticket: u32, meta: []const u8) bool {
        const parsed = parseMeta(meta) orelse return false;
        self.write(ticket, parsed, null);
        return true;
    }

    fn write(self: *Slot, ticket: u32, parsed: Meta, body: ?[]const u8) void {
        const reply = &self.reply;
        reply.ticket = ticket;
        reply.status = parsed.status;
        const etag_len = @min(parsed.etag.len, max_tag);
        @memcpy(reply.etag[0..etag_len], parsed.etag[0..etag_len]);
        reply.etag_len = @intCast(etag_len);
        const version_len = @min(parsed.version.len, max_tag);
        @memcpy(reply.version[0..version_len], parsed.version[0..version_len]);
        reply.version_len = @intCast(version_len);
        if (body) |bytes| {
            reply.truncated = false;
            @memcpy(reply.body[0..bytes.len], bytes);
            reply.body_len = bytes.len;
        } else {
            reply.truncated = true;
            reply.body_len = 0;
        }
        self.reply_pending = true;
        self.revision_count +%= 1;
    }

    /// The answer once. Null when the page has not answered since the last one was taken.
    pub fn takeReply(self: *Slot) ?*const Reply {
        if (!self.reply_pending) return null;
        self.reply_pending = false;
        return &self.reply;
    }

    /// Moves on every settle, so an app can tell an answer arrived without comparing bytes.
    pub fn revision(self: *const Slot) u32 {
        return self.revision_count;
    }

    /// A fresh slot: no origin, no request owed, no answer waiting. A new page, or a test starting from a known state.
    pub fn reset(self: *Slot) void {
        self.origin_len = 0;
        self.origin_pending = false;
        self.staged_len = 0;
        self.owed = false;
        self.reply_pending = false;
        self.reply.truncated = false;
        self.reply.body_len = 0;
        self.revision_count +%= 1;
    }
};

/// A bounded writer: no allocator, and a `false` the moment the caller's buffer runs out.
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
};

// ---- tests ---------------------------------------------------------------------------------------------------

const testing = std.testing;

test "a staged request reaches the page as its ticket, its method and its address on one line" {
    var slot = Slot{};
    try testing.expect(slot.stage(7, .get, "http://127.0.0.1:8099/api/companies", &.{}, ""));
    try testing.expectEqualStrings("7 GET http://127.0.0.1:8099/api/companies\n\n", slot.stagedBytes().?);
}

test "a request's headers and body follow the head after one blank line" {
    var slot = Slot{};
    const headers = [_]Header{
        .{ .name = "Authorization", .value = "Bearer abc" },
        .{ .name = "If-None-Match", .value = "\"0123456789abcdef\"" },
    };
    try testing.expect(slot.stage(8, .post, "http://h/api/companies/acme/projects", &headers, "{\"name\":\"Web\"}"));
    try testing.expectEqualStrings(
        "8 POST http://h/api/companies/acme/projects\n" ++
            "Authorization: Bearer abc\n" ++
            "If-None-Match: \"0123456789abcdef\"\n" ++
            "\n" ++
            "{\"name\":\"Web\"}",
        slot.stagedBytes().?,
    );
}

test "a request too large for the slot is refused instead of truncated" {
    var slot = Slot{};
    var oversized: [max_request_bytes + 1]u8 = undefined;
    @memset(&oversized, 'x');
    try testing.expect(!slot.stage(1, .post, "http://h/api/x", &.{}, &oversized));
    try testing.expect(slot.stagedBytes() == null);
}

test "a second request is refused while the page still owes the first, and accepted once it confirms" {
    var slot = Slot{};
    try testing.expect(slot.stage(1, .get, "http://h/a", &.{}, ""));
    try testing.expect(!slot.stage(2, .get, "http://h/b", &.{}, ""));
    try testing.expectEqualStrings("1 GET http://h/a\n\n", slot.stagedBytes().?);
    slot.clean();
    try testing.expect(slot.stagedBytes() == null);
    try testing.expect(slot.stage(2, .get, "http://h/b", &.{}, ""));
}

test "the reply the page settled reads back with its ticket, status, tags and body" {
    var slot = Slot{};
    try testing.expect(slot.settle(4, "200\n\"0123456789abcdef\"\nabc123\n", "{\"ok\":true}"));
    const reply = slot.takeReply().?;
    try testing.expectEqual(@as(u32, 4), reply.ticket);
    try testing.expectEqual(@as(u16, 200), reply.status);
    try testing.expectEqualStrings("\"0123456789abcdef\"", reply.etagText());
    try testing.expectEqualStrings("abc123", reply.versionText());
    try testing.expectEqualStrings("{\"ok\":true}", reply.bodyText());
    try testing.expect(reply.ok());
    try testing.expect(!reply.truncated);
}

test "a reply is handed over once, and the next answer is a new one" {
    var slot = Slot{};
    try testing.expect(slot.settle(1, "200\n\n\n", "first"));
    try testing.expectEqualStrings("first", slot.takeReply().?.bodyText());
    try testing.expect(slot.takeReply() == null);
    try testing.expect(slot.settle(2, "204\n\n\n", ""));
    try testing.expectEqual(@as(u32, 2), slot.takeReply().?.ticket);
}

test "a not-modified answer is an answer, and it keeps the body empty" {
    var slot = Slot{};
    try testing.expect(slot.settle(3, "304\n\"0123456789abcdef\"\n\n", ""));
    const reply = slot.takeReply().?;
    try testing.expect(reply.notModified());
    try testing.expect(!reply.ok());
    try testing.expectEqualStrings("", reply.bodyText());
    try testing.expectEqualStrings("\"0123456789abcdef\"", reply.etagText());
}

test "no answer at all is a reply the app can retry, told apart from a refusal" {
    var slot = Slot{};
    try testing.expect(slot.settle(5, "0\n\n\n", ""));
    try testing.expect(slot.takeReply().?.failed());
    try testing.expect(slot.settle(6, "401\n\n\n", ""));
    try testing.expect(!slot.takeReply().?.failed());
}

test "a body larger than the slot arrives marked truncated rather than half-read" {
    var slot = Slot{};
    var oversized: [max_body_bytes + 1]u8 = undefined;
    @memset(&oversized, 'x');
    try testing.expect(slot.settle(9, "200\n\n\n", &oversized));
    const reply = slot.takeReply().?;
    try testing.expect(reply.truncated);
    try testing.expectEqualStrings("", reply.bodyText());
    try testing.expectEqual(@as(u16, 200), reply.status);
}

test "bytes that are not a status are refused rather than read as no answer" {
    var slot = Slot{};
    try testing.expect(!slot.settle(1, "\n\n", "x"));
    try testing.expect(!slot.settle(1, "OK\n\n\n", "x"));
    try testing.expect(!slot.settle(1, "700\n\n\n", "x"));
    try testing.expect(slot.takeReply() == null);
}

test "a settled answer moves the revision, so an app can poll instead of comparing bytes" {
    var slot = Slot{};
    const before = slot.revision();
    try testing.expect(slot.settle(1, "200\n\n\n", ""));
    try testing.expect(slot.revision() != before);
}

test "the origin the page names reads back once, and is refused when it cannot fit" {
    var slot = Slot{};
    var buf: [max_origin]u8 = undefined;
    try testing.expect(slot.takeOrigin(&buf) == null);
    try testing.expect(slot.setOrigin("http://127.0.0.1:8099"));
    try testing.expectEqualStrings("http://127.0.0.1:8099", slot.takeOrigin(&buf).?);
    try testing.expect(slot.takeOrigin(&buf) == null);
    try testing.expectEqualStrings("http://127.0.0.1:8099", slot.originBytes());
    var oversized: [max_origin + 1]u8 = undefined;
    @memset(&oversized, 'o');
    try testing.expect(!slot.setOrigin(&oversized));
}

test "reset forgets the origin, the request and the answer" {
    var slot = Slot{};
    var buf: [max_origin]u8 = undefined;
    _ = slot.setOrigin("http://h");
    _ = slot.stage(1, .get, "http://h/a", &.{}, "");
    _ = slot.settle(1, "200\n\n\n", "x");
    slot.reset();
    try testing.expect(slot.takeOrigin(&buf) == null);
    try testing.expect(slot.stagedBytes() == null);
    try testing.expect(slot.takeReply() == null);
}
