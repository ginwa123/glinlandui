//! The XDG Desktop Portal `FileChooser` protocol, as PURE data.
const std = @import("std");
const dbus = @import("dbus.zig");
const contract = @import("../core/file_dialog_contract.zig");

/// The portal's well-known bus name.
pub const uriToPath = contract.fileUriToPath;
pub const pathToUri = contract.pathToFileUri;

pub const desktop_service = "org.freedesktop.portal.Desktop";
/// Every portal object lives here.
pub const desktop_path = "/org/freedesktop/portal/desktop";
/// The chooser interface.
pub const chooser_interface = "org.freedesktop.portal.FileChooser";
/// The signal that carries the answer, on the request path.
pub const response_interface = "org.freedesktop.portal.Response";
/// The `Close` method, on the request path, for cancelling.
pub const request_interface = "org.freedesktop.portal.Request";
/// Where every request path begins.
pub const request_path_prefix = "/org/freedesktop/portal/desktop/request/";

/// The D-Bus method that asks for each kind.
pub fn memberFor(kind: contract.Kind) []const u8 {
    return switch (kind) {
        .open_file => "OpenFile",
        .open_folder => "OpenDirectory",
        .save_file => "SaveFile",
    };
}

/// The object path the portal will answer on.
pub fn writeRequestPath(sender: []const u8, token: []const u8, out: []u8) ![]const u8 {
    var i: usize = 0;
    const prefix = request_path_prefix;
    if (out.len < prefix.len + sender.len + token.len + 2) return error.NoSpaceLeft;
    @memcpy(out[i..][0..prefix.len], prefix);
    i += prefix.len;
    const folded = try foldSenderName(sender, out[i..]);
    i += folded.len;
    out[i] = '/';
    i += 1;
    @memcpy(out[i..][0..token.len], token);
    i += token.len;
    return out[0..i];
}

/// Fold a unique bus name into the form the portal uses in a request path: the leading colon is dropped and every character a path element may not.
pub fn foldSenderName(sender: []const u8, out: []u8) ![]const u8 {
    var n: usize = 0;
    var first = true;
    for (sender) |ch| {
        if (first and ch == ':') {
            first = false;
            continue;
        }
        first = false;
        if (n >= out.len) return error.NoSpaceLeft;
        const ok = (ch >= '0' and ch <= '9') or (ch >= 'A' and ch <= 'Z') or
            (ch >= 'a' and ch <= 'z') or ch == '_';
        out[n] = if (ok) ch else '_';
        n += 1;
    }
    return out[0..n];
}

/// A request token, unique among this connection's requests.
pub fn writeToken(seed: u64, out: []u8) ![]const u8 {
    if (out.len < 16) return error.NoSpaceLeft;
    return std.fmt.bufPrint(out, "glin{x}", .{seed});
}

/// The `a{sv}` options for a request.
pub const filters_signature = "a(sa(ss))";

pub fn writeOptions(w: *dbus.Writer, opts: contract.Options, token: []const u8) !usize {
    // The array's length word goes first.
    const array_at = w.reserveU32();
    w.alignTo(8);
    const first_element = w.count();

    // handle_token: not optional.
    try dictEntry(w, "handle_token", "s");
    w.writeString(token);

    if (opts.modal) {
        try dictEntry(w, "modal", "b");
        w.writeBool(true);
    }
    if (opts.multiple and opts.kind.allowsMultiple()) {
        try dictEntry(w, "multiple", "b");
        w.writeBool(true);
    }
    if (opts.accept_label.len != 0) {
        try dictEntry(w, "accept_label", "s");
        w.writeString(opts.accept_label);
    }
    if (opts.title.len != 0) {
        try dictEntry(w, "title", "s");
        w.writeString(opts.title);
    }
    if (opts.filters.len != 0) {
        try dictEntry(w, "filters", filters_signature);
        try writeFilterList(w, opts.filters);
    }
    if (opts.current_folder) |folder| {
        // The `ay`, not a `s`. See the file header.
        try dictEntry(w, "current_folder", "ay");
        var uri_buf: [1024]u8 = undefined;
        const uri = try pathToUri(folder, &uri_buf);
        w.writeByteArray(uri);
    }
    if (opts.current_name) |name| {
        if (opts.kind == .save_file) {
            // Only SaveFile reads it; sending it on an open request is noise the portal ignores.
            try dictEntry(w, "current_name", "s");
            w.writeString(name);
        }
    }
    const end = w.count();
    w.patchU32(array_at, @intCast(end - first_element));
    return end - first_element;
}

/// The method body: `ssa{sv}` — parent window, title, options.
pub fn writeMethodBody(w: *dbus.Writer, opts: contract.Options, token: []const u8) !void {
    w.writeString(""); // parent_window
    w.writeString(if (opts.title.len != 0) opts.title else opts.kind.defaultTitle());
    _ = try writeOptions(w, opts, token);
}

/// The `filters` value: `a(sa(us))` — a list of (name, [(label, pattern)]).
fn writeFilterList(w: *dbus.Writer, filters: []const contract.Filter) !void {
    const array_at = w.reserveU32();
    w.alignTo(8);
    const first_element = w.count();
    for (filters) |f| {
        // 8: the element is a STRUCT, and a struct is 8-aligned in the D-Bus type system.
        w.alignTo(8);
        w.writeString(f.name);
        // Each filter's rule list: the second member of the (s, a(...)) struct.
        const rules_at = w.reserveU32();
        // 8 again: each rule is the struct (s, s).
        w.alignTo(8);
        const first_rule = w.count();
        for (f.rules) |rule| {
            w.alignTo(8);
            // The label, then the pattern.
            w.writeString(rule.display());
            w.writeString(rule.pattern);
        }
        w.patchU32(rules_at, @intCast(w.count() - first_rule));
    }
    w.patchU32(array_at, @intCast(w.count() - first_element));
}

/// Begin one dict entry: 8-align, write the key, write the variant's type signature.
fn dictEntry(w: *dbus.Writer, key: []const u8, variant_sig: []const u8) !void {
    w.alignTo(8);
    w.writeString(key);
    w.writeSignature(variant_sig);
}

/// A decoded `Response` signal: the code, and the URIs it carried.
pub const Decoded = struct {
    /// 0 = the request was cancelled, 1 = success, anything else = neither.
    code: u32,
    /// Borrowed from the signal body, and from `out` in `decodeResponse`.
    uris: []const []const u8 = &.{},

    pub fn status(self: Decoded) contract.Status {
        return switch (self.code) {
            0 => .cancelled,
            1 => .selected,
            else => .other,
        };
    }
};

/// Decode a `Response` body (`ua{sv}`) and pick out the `uris`.
pub fn decodeResponse(body: []const u8, out: [][]const u8) !Decoded {
    var r = dbus.Reader.init(body);
    const code = try r.readU32();

    var n: usize = 0;

    // The array's LENGTH is a u32, so it sits on a 4-byte boundary — and the first element is then aligned to 8.
    const dict_len = try r.readU32();
    if (dict_len > r.rest().len) return error.Truncated;
    const dict_end = r.pos + dict_len;

    // The reader keeps walking the WHOLE body rather than a sub-slice, and that is not a style choice.
    while (r.pos < dict_end) {
        r.alignTo(8);
        if (r.pos >= dict_end) break;
        _ = try r.readString(); // key
        const vsig = try r.readSignature();
        if (std.mem.eql(u8, vsig, "as")) {
            const arr_len = try r.readU32();
            if (arr_len > r.rest().len) return error.Truncated;
            const arr_end = r.pos + arr_len;
            while (r.pos < arr_end) {
                if (n >= out.len) return error.TooManyUris;
                out[n] = try r.readString();
                n += 1;
            }
        } else {
            try skipVariant(&r, vsig);
        }
    }
    return .{ .code = code, .uris = out[0..n] };
}

/// Step over a value of the given signature.
fn skipVariant(r: *dbus.Reader, sig: []const u8) !void {
    if (sig.len == 0) return error.BadValue;
    switch (sig[0]) {
        's', 'o', 'g' => _ = try r.readString(),
        'y' => {
            r.alignTo(4);
            const n = try r.readU32();
            r.pos += n;
        },
        'b', 'u', 'i', 'x', 't', 'd', 'n', 'q' => r.alignTo(8),
        'a' => {
            const inner = sig[1..];
            const n = try r.readU32();
            if (n > r.rest().len) return error.Truncated;
            const end = r.pos + n;
            // Only the array shapes the portal actually uses are walked; anything else is refused rather than mis-strided.
            if (!std.mem.eql(u8, inner, "s") and
                !std.mem.eql(u8, inner, "o") and
                !std.mem.eql(u8, inner, "y") and
                !std.mem.eql(u8, inner, "as") and
                !std.mem.eql(u8, inner, "a{sv}") and
                !std.mem.eql(u8, inner, "sa(us)")) return error.BadValue;
            var ar = dbus.Reader.init(r.buf[r.pos..end]);
            while (ar.pos < ar.buf.len) {
                if (std.mem.eql(u8, inner, "s") or std.mem.eql(u8, inner, "o")) {
                    _ = try ar.readString();
                } else if (std.mem.eql(u8, inner, "y")) {
                    const m = try ar.readU32();
                    ar.pos += m;
                } else {
                    try skipVariant(&ar, inner);
                }
            }
            r.pos = end;
        },
        else => return error.BadValue,
    }
}

/// The `AddMatch` rule that routes ONE request's Response to us.
pub fn writeResponseMatchRule(sender_folded: []const u8, token: []const u8, out: []u8) ![]const u8 {
    return std.fmt.bufPrint(
        out,
        "type='signal',path='{s}{s}/{s}',interface='{s}',member='Response'",
        .{ request_path_prefix, sender_folded, token, response_interface },
    );
}

// Tests

test "each kind asks for its own portal method" {
    try std.testing.expectEqualStrings("OpenFile", memberFor(.open_file));
    try std.testing.expectEqualStrings("OpenDirectory", memberFor(.open_folder));
    try std.testing.expectEqualStrings("SaveFile", memberFor(.save_file));
}

test "the request path folds the sender's colon and dots" {
    var buf: [128]u8 = undefined;
    const path = try writeRequestPath(":1.42", "glin1", &buf);
    try std.testing.expectEqualStrings(
        "/org/freedesktop/portal/desktop/request/1_42/glin1",
        path,
    );
}

test "a sender with no colon is still usable" {
    var buf: [128]u8 = undefined;
    const path = try writeRequestPath("1.42", "t", &buf);
    try std.testing.expectEqualStrings("/org/freedesktop/portal/desktop/request/1_42/t", path);
}

test "the folded sender is the AddMatch rule's sender" {
    var buf: [64]u8 = undefined;
    // The match rule and the request path must be built from the SAME folded name; a client that folded one and not the other waits for a signal on a path.
    try std.testing.expectEqualStrings("1_42", try foldSenderName(":1.42", &buf));
    try std.testing.expectEqualStrings("1_99", try foldSenderName(":1.99", &buf));
}

test "a token uses only characters the portal accepts" {
    var buf: [32]u8 = undefined;
    const token = try writeToken(1, &buf);
    try std.testing.expectEqualStrings("glin1", token);
    for (token) |ch| {
        const ok = (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or
            (ch >= '0' and ch <= '9') or ch == '_';
        try std.testing.expect(ok);
    }
}

test "an open request asks for a title, modality and its token" {
    var buf: [1024]u8 = undefined;
    var w = dbus.Writer.init(&buf);
    const opts = contract.Options{ .kind = .open_file, .title = "Open a file" };
    try writeMethodBody(&w, opts, "glin1");

    var d = try scanDict(w.written());
    // The body's first two members are the two strings.
    try std.testing.expectEqualStrings("", try d.readString());
    try std.testing.expectEqualStrings("Open a file", try d.readString());

    var options = try d.dict();
    try std.testing.expect(try options.nextKey()); // handle_token
    try std.testing.expectEqualStrings("handle_token", options.key);
    try std.testing.expectEqualStrings("s", try options.variant());
    try std.testing.expectEqualStrings("glin1", try options.readString());

    try std.testing.expect(try options.nextKey());
    try std.testing.expectEqualStrings("modal", options.key);
    try std.testing.expectEqualStrings("b", try options.variant());
    try std.testing.expect(try options.readBool());

    try std.testing.expect(try options.nextKey());
    try std.testing.expectEqualStrings("title", options.key);
    try std.testing.expectEqualStrings("s", try options.variant());
    try std.testing.expectEqualStrings("Open a file", try options.readString());

    // And nothing else: a request with a title, a token and modality is exactly those three options.
    try std.testing.expect(!try options.nextKey());
}

test "a request with no title of its own gets the kind's default" {
    var buf: [1024]u8 = undefined;
    var w = dbus.Writer.init(&buf);
    try writeMethodBody(&w, .{ .kind = .open_folder }, "glin1");
    var d = try scanDict(w.written());
    _ = try d.readString();
    try std.testing.expectEqualStrings("Open Folder", try d.readString());
}

test "multiple is sent for an open request and not for a save target" {
    {
        var buf: [1024]u8 = undefined;
        var w = dbus.Writer.init(&buf);
        try writeMethodBody(&w, .{ .multiple = true }, "t");
        var d = try scanDict(w.written());
        _ = try d.readString();
        _ = try d.readString();
        var options = try d.dict();
        try std.testing.expect(try options.nextKey());
        try std.testing.expectEqualStrings("s", try options.variant());
        _ = try options.readString(); // handle_token
        try std.testing.expect(try options.nextKey());
        try std.testing.expectEqualStrings("modal", options.key);
        try std.testing.expectEqualStrings("b", try options.variant());
        _ = try options.readBool();
        try std.testing.expect(try options.nextKey());
        try std.testing.expectEqualStrings("multiple", options.key);
        try std.testing.expectEqualStrings("b", try options.variant());
        try std.testing.expect(try options.readBool());
    }
    {
        // A save target is one path.
        var buf: [1024]u8 = undefined;
        var w = dbus.Writer.init(&buf);
        try writeMethodBody(&w, .{ .kind = .save_file, .multiple = true, .current_name = "name.txt" }, "t");
        var d = try scanDict(w.written());
        _ = try d.readString();
        _ = try d.readString();
        var options = try d.dict();
        try std.testing.expect(try options.nextKey());
        try std.testing.expectEqualStrings("s", try options.variant());
        _ = try options.readString();
        try std.testing.expect(try options.nextKey());
        try std.testing.expectEqualStrings("b", try options.variant());
        _ = try options.readBool(); // modal
        // The next key is the save name, not `multiple`.
        try std.testing.expect(try options.nextKey());
        try std.testing.expectEqualStrings("current_name", options.key);
        try std.testing.expectEqualStrings("s", try options.variant());
        try std.testing.expectEqualStrings("name.txt", try options.readString());
        try std.testing.expect(!try options.nextKey());
    }
}

test "current_folder is a byte array holding a file URI, not a string" {
    var buf: [1024]u8 = undefined;
    var w = dbus.Writer.init(&buf);
    const opts = contract.Options{ .current_folder = "/home/u/My Docs" };
    try writeMethodBody(&w, opts, "t");
    var d = try scanDict(w.written());
    _ = try d.readString();
    _ = try d.readString();
    var options = try d.dict();
    while (try options.nextKey()) {
        const sig = try options.variant();
        if (std.mem.eql(u8, options.key, "current_folder")) {
            // This is the assertion that matters: `ay`, and the bytes are the percent-encoded URI.
            try std.testing.expectEqualStrings("ay", sig);
            const uri = try options.readByteArray();
            try std.testing.expectEqualStrings("file:///home/u/My%20Docs", uri);
            return;
        }
        try options.skipValue(sig);
    }
    return error.TestUnexpectedResult;
}

test "filters arrive as the declared type: a name, then label/pattern pairs" {
    var buf: [1024]u8 = undefined;
    var w = dbus.Writer.init(&buf);
    const filters = [_]contract.Filter{
        .{
            .name = "Images",
            .rules = &.{
                .{ .pattern = "*.png" },
                .{ .label = "JPEG", .pattern = "*.jpg" },
            },
        },
        .{ .name = "All files", .rules = &.{.{ .pattern = "*" }} },
    };
    try writeMethodBody(&w, .{ .filters = &filters }, "t");

    var d = try scanDict(w.written());
    _ = try d.readString();
    _ = try d.readString();
    var options = try d.dict();
    while (try options.nextKey()) {
        const sig = try options.variant();
        if (std.mem.eql(u8, options.key, "filters")) {
            // The constant, not a literal: the declared type is a decision (`filters_signature` explains it at length), and a test that hard-coded the documented.
            try std.testing.expectEqualStrings(filters_signature, sig);
            var list = try options.array();
            try std.testing.expectEqualStrings("Images", try list.readFilterName());
            try std.testing.expectEqual(@as(usize, 2), try list.rules());
            try list.enterRules();
            try std.testing.expectEqualStrings("*.png", try list.readRuleLabel());
            try std.testing.expectEqualStrings("*.png", try list.readRulePattern());
            try std.testing.expectEqualStrings("JPEG", try list.readRuleLabel());
            try std.testing.expectEqualStrings("*.jpg", try list.readRulePattern());
            try std.testing.expectEqualStrings("All files", try list.readFilterName());
            try std.testing.expectEqual(@as(usize, 1), try list.rules());
            try list.enterRules();
            try std.testing.expectEqualStrings("*", try list.readRuleLabel());
            try std.testing.expectEqualStrings("*", try list.readRulePattern());
            return;
        }
        try options.skipValue(sig);
    }
    return error.TestUnexpectedResult;
}

test "a cancelled response is code 0, a success is 1" {
    var body: [64]u8 = undefined;
    var w = dbus.Writer.init(&body);
    w.writeU32(0);
    w.alignTo(8); // an a{sv} length word is 8-aligned, padding and all
    w.writeU32(0); // empty a{sv}
    var list: [4][]const u8 = undefined;
    const cancelled = try decodeResponse(w.written(), &list);
    try std.testing.expectEqual(contract.Status.cancelled, cancelled.status());
    try std.testing.expectEqual(@as(usize, 0), cancelled.uris.len);

    var w2 = dbus.Writer.init(&body);
    w2.writeU32(2);
    w2.alignTo(8);
    w2.writeU32(0);
    const other = try decodeResponse(w2.written(), &list);
    try std.testing.expectEqual(contract.Status.other, other.status());
}

test "the uris come out of the results dict, and other keys are skipped" {
    var body: [256]u8 = undefined;
    var w = dbus.Writer.init(&body);
    w.writeU32(1); // success
    // The length word is a plain u32; only the ELEMENTS are 8-aligned.
    const dict_at = w.reserveU32();
    w.alignTo(8);
    const first = w.count();
    // An unfamiliar key FIRST, with a type the decoder must step over, so a decoder that assumes `uris` is the only key fails here.
    w.alignTo(8);
    w.writeString("other-key");
    w.writeSignature("u");
    w.writeU32(42);
    w.alignTo(8);
    w.writeString("uris");
    w.writeSignature("as");
    w.writeU32(2 * 17);
    w.writeString("file:///tmp/one");
    w.writeString("file:///tmp/two");
    w.patchU32(dict_at, @intCast(w.count() - first));

    var list: [4][]const u8 = undefined;
    const decoded = try decodeResponse(w.written(), &list);
    try std.testing.expectEqual(contract.Status.selected, decoded.status());
    try std.testing.expectEqual(@as(usize, 2), decoded.uris.len);
    try std.testing.expectEqualStrings("file:///tmp/one", decoded.uris[0]);
    try std.testing.expectEqualStrings("file:///tmp/two", decoded.uris[1]);
}

test "a response with more uris than the caller's list is an error, not a smash" {
    var body: [256]u8 = undefined;
    var w = dbus.Writer.init(&body);
    w.writeU32(1);
    const dict_at = w.reserveU32();
    w.alignTo(8);
    const first = w.count();
    w.alignTo(8);
    w.writeString("uris");
    w.writeSignature("as");
    w.writeU32(2 * 17);
    w.writeString("file:///tmp/one");
    w.writeString("file:///tmp/two");
    w.patchU32(dict_at, @intCast(w.count() - first));

    var list: [1][]const u8 = undefined; // deliberately one short
    try std.testing.expectError(error.TooManyUris, decodeResponse(w.written(), &list));
}

test "the match rule names this request's path and nothing else" {
    var buf: [256]u8 = undefined;
    const rule = try writeResponseMatchRule("1_42", "glin1", &buf);
    try std.testing.expectEqualStrings(
        "type='signal',path='/org/freedesktop/portal/desktop/request/1_42/glin1'," ++
            "interface='org.freedesktop.portal.Response',member='Response'",
        rule,
    );
}

// A test-side D-Bus reader Deliberately independent of `dbus.zig`'s `parse`: these tests are checking what the ENCODER wrote, and a reader built on the.

const TestReader = struct {
    r: dbus.Reader,
    fn init(buf: []const u8) TestReader {
        return .{ .r = dbus.Reader.init(buf) };
    }

    fn readString(self: *TestReader) ![]const u8 {
        return self.r.readString();
    }
    fn readU32(self: *TestReader) !u32 {
        return self.r.readU32();
    }
    fn readBool(self: *TestReader) !bool {
        return self.r.readBool();
    }
    fn readByteArray(self: *TestReader) ![]const u8 {
        return self.r.readBytes();
    }

    /// Reinterpret the rest of the body as the options dictionary.
    fn dict(self: *TestReader) !TestDict {
        self.r.alignTo(8);
        const len = try self.r.readU32();
        if (len > self.r.rest().len) return error.Truncated;
        const start = self.r.pos;
        self.r.pos += len;
        return .{ .r = .{ .buf = self.r.buf, .pos = start }, .limit = self.r.pos };
    }
};

const TestDict = struct {
    r: dbus.Reader,
    key: []const u8 = "",
    /// One past the dictionary's last byte, in body coordinates.
    limit: usize = 0,

    /// True while another entry remains; leaves `key` set.
    fn nextKey(self: *TestDict) !bool {
        self.r.alignTo(8);
        if (self.r.pos >= self.limit) return false;
        self.key = try self.r.readString();
        return true;
    }

    fn variant(self: *TestDict) ![]const u8 {
        return self.r.readSignature();
    }

    fn readString(self: *TestDict) ![]const u8 {
        return self.r.readString();
    }

    fn readBool(self: *TestDict) !bool {
        return self.r.readBool();
    }

    fn readByteArray(self: *TestDict) ![]const u8 {
        return self.r.readBytes();
    }

    fn array(self: *TestDict) !TestFilterList {
        const len = try self.r.readU32();
        if (len > self.r.rest().len) return error.Truncated;
        const start = self.r.pos;
        self.r.pos += len;
        // Body coordinates again — a (sa(us)) element is 8-aligned.
        return .{ .r = .{ .buf = self.r.buf, .pos = start }, .limit = self.r.pos };
    }

    fn skipValue(self: *TestDict, sig: []const u8) !void {
        if (sig.len == 0) return error.BadValue;
        switch (sig[0]) {
            's', 'o', 'g' => _ = try self.r.readString(),
            'y' => {
                const n = try self.r.readU32();
                self.r.pos += n;
            },
            'b' => _ = try self.r.readBool(),
            'u', 'i', 'x' => self.r.alignTo(4),
            'a' => {
                const n = try self.r.readU32();
                self.r.pos += n;
            },
            else => return error.BadValue,
        }
    }
};

const TestFilterList = struct {
    r: dbus.Reader,
    /// One past the array's last byte, in BODY coordinates.
    limit: usize = 0,

    /// A filter's name. The (s, a(...)) element is a STRUCT, so 8.
    fn readFilterName(self: *TestFilterList) ![]const u8 {
        self.r.alignTo(8);
        return self.r.readString();
    }

    /// How many rules the filter at the cursor holds, without consuming them.
    fn rules(self: *TestFilterList) !usize {
        const save = self.r.pos;
        const len = try self.r.readU32();
        const end = self.r.pos + len;
        self.r.pos = save;
        var n: usize = 0;
        var probe = dbus.Reader{ .buf = self.r.buf, .pos = self.r.pos };
        _ = try probe.readU32(); // the length word
        probe.alignTo(8); // the (s, s) elements
        while (probe.pos < end) {
            _ = try probe.readString(); // label
            _ = try probe.readString(); // pattern
            n += 1;
        }
        return n;
    }

    /// Move past the filter's rule-array length word, to its first element.
    fn enterRules(self: *TestFilterList) !void {
        _ = try self.r.readU32();
    }

    /// A rule's label. The (s, s) element is a STRUCT: 8-aligned.
    fn readRuleLabel(self: *TestFilterList) ![]const u8 {
        self.r.alignTo(8);
        return self.r.readString();
    }

    fn readRulePattern(self: *TestFilterList) ![]const u8 {
        return self.r.readString();
    }
};

fn scanDict(body: []const u8) !TestReader {
    return TestReader.init(body);
}
