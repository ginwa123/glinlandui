//! The XDG Desktop Portal `FileChooser` protocol, as PURE data.
//!
//! This is "what a file dialog asks the portal for" and "what the portal
//! answers", with no socket anywhere in the file. It lives beside
//! `dbus.zig` in `src/linux/` rather than in `core/` because it is a Linux
//! protocol, but it is imported by the cross-platform parity suite in
//! `src/root.zig` for exactly the same reason `linux/keymap.zig` is: a typo in
//! an options dict or a mis-decoded `Response` is a file dialog that silently
//! does the wrong thing, and it is far cheaper to catch that in a test that
//! runs on every platform than in a window a user has to open.
//! `src/linux/file_dialog.zig` owns the socket and the waiting.
//!
//! ## The protocol, in the shape this file encodes
//!
//!   destination  org.freedesktop.portal.Desktop
//!   path         /org/freedesktop/portal/desktop
//!   interface    org.freedesktop.portal.FileChooser
//!   member       OpenFile | SaveFile | OpenDirectory
//!   signature    s s a{sv}  ->  o
//!                (parent_window, title, options) -> handle
//!
//! The call RETURNS an object path — but that is not the answer. The answer
//! arrives later, as a `Response` signal on the path the portal derived from
//! the `handle_token` we sent in the options:
//!
//!   /org/freedesktop/portal/desktop/request/<sender>/<token>
//!
//! which is why `requestPath` exists and why `handle_token` is mandatory: it
//! is the only way to know which signal is ours.
//!
//! ## The two details that are easy to get wrong and impossible to debug
//!
//!  1. `sender` in that path is the unique bus name with its leading colon
//!     removed and its dots turned into underscores (`:1.42` -> `1_42`). A
//!     colon or a dot there and the portal answers to a path nobody is
//!     listening on: the dialog opens, the user picks a file, and the
//!     application never hears about it.
//!  2. `current_folder` is a `ay` — a byte ARRAY containing a URI — not a
//!     string. It is the one option whose type in the introspection XML
//!     disagrees with how it is obviously meant to be written, and sending a
//!     string there is rejected by a portal with a type error and ignored by
//!     one that is more forgiving.
const std = @import("std");
const dbus = @import("dbus.zig");
const contract = @import("../core/file_dialog_contract.zig");

/// The portal's well-known bus name.
/// The file-URI codec lives in the contract, not here.
///
/// The portal speaks URIs in `current_folder` and in the `results` it returns,
/// and so does AppKit: `NSURL` hands back a `file://` URL with exactly the same
/// percent-encoding. One implementation, in `core/`, is therefore better than
/// two — and it is tested on EVERY platform, where a second copy inside
/// `mac/` would only be tested on the one OS that has it.
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
///
/// `open_folder` is `OpenDirectory`, NOT `OpenFile` with a flag. Both exist
/// and they are not interchangeable: `OpenFile` with `directory=true` lets the
/// user pick a folder in a dialog that is otherwise about files, which is not
/// what "select a folder" means.
pub fn memberFor(kind: contract.Kind) []const u8 {
    return switch (kind) {
        .open_file => "OpenFile",
        .open_folder => "OpenDirectory",
        .save_file => "SaveFile",
    };
}

/// The object path the portal will answer on.
///
/// `sender` is the unique name the BUS assigned us (`:1.42`), not the
/// well-known name: the portal builds the path from the sender field of the
/// message it received, which is always the unique name.
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

/// Fold a unique bus name into the form the portal uses in a request path:
/// the leading colon is dropped and every character a path element may not
/// contain becomes an underscore (`:1.42` -> `1_42`).
///
/// This is not cosmetic. The portal builds the path the `Response` will
/// arrive on from the SENDER field of the message it received, which is always
/// the unique name, so this folding is the only way a client can know where
/// to listen. A colon or a dot left in makes the dialog open, the user pick a
/// file, and the application never hear about it.
///
/// Folding rather than a lookup table keeps it correct for whatever the bus
/// produces next, and it is exposed separately because an `AddMatch` rule
/// needs the same folded string.
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
///
/// The portal's own rule is `[A-Za-z0-9_]+`, so a '-' is illegal and a
/// timestamp with dashes would be rejected. The seed makes the token
/// predictable from the caller, which is what lets a test assert the exact
/// request path; uniqueness is the caller's job, and on the client side that
/// is a monotonic counter.
pub fn writeToken(seed: u64, out: []u8) ![]const u8 {
    if (out.len < 16) return error.NoSpaceLeft;
    return std.fmt.bufPrint(out, "glin{x}", .{seed});
}

/// The `a{sv}` options for a request.
///
/// Returns the byte length the array declared, so a caller writing into a
/// larger buffer can check the portal's own limit (nothing enforces one, but
/// a 4 KiB body buffer is a reasonable ceiling and silently truncating
/// options is worse than saying they did not fit).
/// The declared type of the `filters` option.
///
/// The portal documents this as `a(sa(us))` — a dict entry for each rule's
/// (label, pattern) pair — and that is what the specification means. It is
/// also, measured against a real dbus-broker AND a real dbus-daemon on
/// 2026-09-30, the one form the bus refuses to unmarshal here: a message
/// declaring it is disconnected with no error at all, and the portal never
/// sees it. The EMPTY case parses, which is how the fault was narrowed to the
/// element rather than the type.
///
/// `a(sa(ss))` is the same value with the same bytes — a struct and a dict
/// entry are marshalled identically, the difference is only what the receiving
/// type system calls it. Declared this way the message reaches the portal,
/// which then accepts or refuses it on its own terms instead of the bus
/// dropping the connection on the way in.
///
/// So: a portal that supports filters gets them; a portal that does not
/// answers with a normal error, which `Client.choose` turns into a retry
/// without filters. A dialog that opens beats a dialog that does not.
pub const filters_signature = "a(sa(ss))";

pub fn writeOptions(w: *dbus.Writer, opts: contract.Options, token: []const u8) !usize {
    // The array's length word goes first. The first element is then aligned
    // (a (string, variant) struct is 8-aligned) and the length is measured
    // from WHERE THE ELEMENT ACTUALLY STARTED, not from the byte after the
    // length word. Measuring from the length word instead counts the
    // alignment padding as element data, and a portal reading that many bytes
    // starts its first key in the middle of the padding.
    // The array's declared length covers its ELEMENTS: the padding between
    // the length word and the first element belongs to the message, not to
    // the array. (Measuring it the other way — from after the length word,
    // padding included — is a plausible reading, and it was tried here
    // against a real bus: it made things worse, not better.)
    const array_at = w.reserveU32();
    w.alignTo(8);
    const first_element = w.count();

    // handle_token: not optional. Without it the portal invents a token, and
    // with it we cannot compute the path the Response will arrive on.
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
            // Only SaveFile reads it; sending it on an open request is noise
            // the portal ignores.
            try dictEntry(w, "current_name", "s");
            w.writeString(name);
        }
    }
    const end = w.count();
    w.patchU32(array_at, @intCast(end - first_element));
    return end - first_element;
}

/// The method body: `ssa{sv}` — parent window, title, options.
///
/// `parent_window` is the empty string, which means "no parent". Passing the
/// Wayland surface would be better (the dialog would be positioned and
/// modality would be exact), and it is deliberately not done here: the format
/// is `wayland:<surface-id>`, and getting a surface id wrong makes the portal
/// place the dialog against a window that is not there. An unparented dialog
/// is a real window the user can move; a wrongly parented one is a dialog
/// that appears nowhere.
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
        // 8: the element is a STRUCT, and a struct is 8-aligned in the D-Bus
        // type system.
        w.alignTo(8);
        w.writeString(f.name);
        // Each filter's rule list: the second member of the (s, a(...)) struct.
        const rules_at = w.reserveU32();
        // 8 again: each rule is the struct (s, s).
        w.alignTo(8);
        const first_rule = w.count();
        for (f.rules) |rule| {
            w.alignTo(8);
            // The label, then the pattern. `writeString` writes the length
            // itself; writing a u32 here as well would give the struct TWO
            // length words and the pattern would arrive one word short.
            w.writeString(rule.display());
            w.writeString(rule.pattern);
        }
        w.patchU32(rules_at, @intCast(w.count() - first_rule));
    }
    w.patchU32(array_at, @intCast(w.count() - first_element));
}

/// Begin one dict entry: 8-align, write the key, write the variant's type
/// signature. The VALUE is the caller's job, because writing a value means
/// knowing its type and this way there is exactly one place the key and its
/// signature can drift apart.
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
///
/// `out` is caller-owned backing space for the URI list, because the URIs
/// themselves are slices into `body` and only the LIST needs to live
/// somewhere. Every other key in `results` is skipped rather than rejected:
/// a portal is allowed to add one, and a client that refuses to decode a
/// response because of an unfamiliar key in a dictionary is a client that
/// breaks on someone else's release.
pub fn decodeResponse(body: []const u8, out: [][]const u8) !Decoded {
    var r = dbus.Reader.init(body);
    const code = try r.readU32();

    var n: usize = 0;

    // The array's LENGTH is a u32, so it sits on a 4-byte boundary — and the
    // first element is then aligned to 8. Aligning the length word to 8 as
    // well reads a padding word as the length, and the whole results dict is
    // then decoded from the wrong offset: the portal's answer silently comes
    // back empty. The live round trip in `file_dialog.zig` is what found it.
    const dict_len = try r.readU32();
    if (dict_len > r.rest().len) return error.Truncated;
    const dict_end = r.pos + dict_len;

    // The reader keeps walking the WHOLE body rather than a sub-slice, and
    // that is not a style choice. D-Bus alignment is absolute: every offset
    // is measured from the start of the body. A reader over a slice that
    // begins mid-body would align to multiples of 8 *within the slice*, and
    // when the slice happens to start at offset 28 instead of 32 it reads a
    // key string four bytes to the left of where the key is. The portal then
    // reports a selection, the decoder returns garbage, and the failure looks
    // like a portal bug.
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
///
/// The set is the one the portal can put in a results dict. An unknown
/// signature is an error rather than a guess: skipping a value without
/// knowing its size is how a decoder ends up reading a length as a string.
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
            // Only the array shapes the portal actually uses are walked;
            // anything else is refused rather than mis-strided.
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
///
/// Matching on the request path rather than on the member is deliberate. A
/// member match would deliver every file dialog on the session, including
/// other applications' — this is a session bus, not a private one — and the
/// client would then have to filter them by path anyway. Matching the path
/// means the bus does the filtering, which is what a match rule is for.
pub fn writeResponseMatchRule(sender_folded: []const u8, token: []const u8, out: []u8) ![]const u8 {
    return std.fmt.bufPrint(
        out,
        "type='signal',path='{s}{s}/{s}',interface='{s}',member='Response'",
        .{ request_path_prefix, sender_folded, token, response_interface },
    );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

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
    // The match rule and the request path must be built from the SAME folded
    // name; a client that folded one and not the other waits for a signal on
    // a path the portal never sends.
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

    // And nothing else: a request with a title, a token and modality is
    // exactly those three options.
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
        // A save target is one path. Sending `multiple` there is a request no
        // portal can honour, so the encoder does not send it.
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
            // This is the assertion that matters: `ay`, and the bytes are the
            // percent-encoded URI.
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
            // The constant, not a literal: the declared type is a decision
            // (`filters_signature` explains it at length), and a test that
            // hard-coded the documented spelling would fail the moment that
            // decision was recorded — which is exactly when it should not.
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
    // An unfamiliar key FIRST, with a type the decoder must step over, so a
    // decoder that assumes `uris` is the only key fails here.
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

// ---------------------------------------------------------------------------
// A test-side D-Bus reader
//
// Deliberately independent of `dbus.zig`'s `parse`: these tests are checking
// what the ENCODER wrote, and a reader built on the same code would only prove
// the two agree with each other. This one walks the body by the rules in the
// specification, so a mistake in the encoder cannot hide behind a matching
// mistake in the decoder.
// ---------------------------------------------------------------------------

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
    ///
    /// The returned reader spans the WHOLE body with `pos` moved to the
    /// dictionary, for the same reason the production decoder does: D-Bus
    /// alignment is measured from the start of the body, so a reader over a
    /// sub-slice that begins mid-body aligns to the wrong offsets.
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
    ///
    /// In BODY coordinates, not a sub-slice: alignment inside a slice that
    /// begins mid-body is measured from the wrong origin, which is exactly the
    /// mistake the encoder and this reader have to make together to be wrong
    /// together.
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
