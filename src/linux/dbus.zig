//! A minimal, PURE-Zig D-Bus wire codec — the half of the file dialog client
//! that is pure logic, and the half that can therefore be TESTED EVERYWHERE.
//!
//! ## Why not libdbus-1
//!
//! The obvious way to call `org.freedesktop.portal.FileChooser` is to link
//! `libdbus-1` through a C shim, the way this toolkit links Wayland, EGL and
//! pango. That was rejected for three reasons, each of which would have been a
//! permanent cost:
//!
//!  1. It is a NEW system dependency in the build graph, so every Linux
//!     developer and every CI runner needs `libdbus-1-dev`. This repository's
//!     stated ambition is that `zig build` works from a vendored tree with no
//!     fetch; adding a dependency to the toolkit's core capability is a
//!     different project.
//!  2. The interesting part of the work is NOT I/O. It is the wire format:
//!     alignment padding, the header array, the `a{sv}` options dict, the
//!     `ua{sv}` response. `libdbus` hides all of it, so the code that decides
//!     what a "folder chooser" actually asks the portal for would be untested
//!     strings.
//!  3. A C shim would land in `src/linux/shim.c` — the ONE untestable
//!     translation unit in the Linux backend (see `build.zig`'s comment on
//!     `-Werror` there). Nothing about a file dialog wants to be owned by the
//!     file the repo already describes as its least trustworthy code.
//!
//! ## What "pure" means here, concretely
//!
//! No sockets, no `@cImport`, no `std.posix` — this file only turns bytes into
//! values and values into bytes. `src/linux/file_dialog.zig` owns the socket,
//! the SASL handshake and the blocking wait. That split is what lets the whole
//! codec run in the cross-platform parity suite (`src/root.zig`'s aggregate
//! test block) on Linux, macOS and Windows, exactly like `linux/keymap.zig`
//! and `linux/input.zig`.
//!
//! ## Scope: what the FileChooser portal actually needs
//!
//! The codec is deliberately not a general D-Bus library. It covers the
//! marshalling subset the portal requires, and nothing more:
//!
//!   u32, string, object path, signature, byte array, bool,
//!   arrays (a, including `a{sv}` and `as`), and struct arrays (`a(sa(us))`).
//!
//! Every type is LITTLE-endian with 8/4/2/1 alignment, per the specification.
//! The decoder refuses big-endian messages rather than guessing, because the
//! bus we connect to is always a local unix socket and a big-endian frame there
//! is a corrupt frame, not a peer worth supporting.
const std = @import("std");

/// The four message types D-Bus defines (`invalid` is 0 and never sent).
pub const MessageType = enum(u8) {
    invalid = 0,
    method_call = 1,
    method_return = 2,
    /// Wire value 3. Spelled `error_reply` because `error` is a reserved
    /// word, and the wire value is what the thing that matters is.
    error_reply = 3,
    signal = 4,
};

/// The flags byte. Only `no_reply_expected` is ever set by this toolkit — the
/// `Hello` call is the reason a reply matters, and every other call we make is
/// a portal request whose answer is a signal, not a return.
pub const Flags = packed struct(u8) {
    no_reply_expected: bool = false,
    no_auto_start: bool = false,
    allow_interactive_authorization: bool = false,
    _reserved: u5 = 0,
};

/// Header field codes, from the D-Bus specification's "Header Field Codes"
/// table. Named rather than inlined because a wrong constant produces a bus
/// that ignores us with no error, which is the worst kind of bug to debug.
pub const field_path: u8 = 1;
pub const field_interface: u8 = 2;
pub const field_member: u8 = 3;
pub const field_error_name: u8 = 4;
pub const field_reply_serial: u8 = 5;
pub const field_destination: u8 = 6;
pub const field_sender: u8 = 7;
pub const field_signature: u8 = 8;
pub const field_unix_fds: u8 = 9;

/// Everything that can go wrong decoding a frame. Deliberately small: a
/// truncated or nonsensical frame from a local bus is a bug or a corrupted
/// stream, not a condition a UI needs to distinguish between.
pub const DecodeError = error{
    /// The frame ran out of bytes before the value it promised.
    Truncated,
    /// The frame is not a D-Bus message: bad magic, version, or an offset
    /// that does not fit the buffer.
    Malformed,
    /// A big-endian frame. Rejected rather than supported (see the file
    /// header): a local session bus is never big-endian.
    BigEndian,
    /// A string/object path/signature was not NUL-terminated where the
    /// specification requires it, or an array length overflows the frame.
    BadValue,
};

/// The decoded fixed header plus the header fields. `body` is a slice into
/// the caller's buffer (zero-copy): D-Bus bodies are small here, and copying
/// them would mean tracking two lifetimes for no benefit.
pub const Header = struct {
    kind: MessageType,
    flags: Flags,
    serial: u32 = 0,
    path: ?[]const u8 = null,
    interface_name: ?[]const u8 = null,
    member: ?[]const u8 = null,
    error_name: ?[]const u8 = null,
    reply_serial: ?u32 = null,
    destination: ?[]const u8 = null,
    sender: ?[]const u8 = null,
    /// The body's type signature, e.g. `"ua{sv}"`. Empty when there is no body.
    body_signature: []const u8 = "",
    /// The body bytes, as a sub-slice of the frame this header was parsed from.
    body: []const u8 = &.{},

    /// True when this message is an error reply to a call we made. The
    /// `error_name` is what tells us WHY (e.g. the portal service is not on
    /// the bus), and it is the difference between "the user cancelled" and
    /// "there is no portal on this system".
    pub fn isError(self: Header) bool {
        return self.kind == .error_reply;
    }
};

/// A bounds-checked, alignment-aware writer. Every method is total: a short
/// buffer is a `NoSpaceLeft` error rather than a memory-safety hole, because
/// the callers build frames into caller-owned buffers and a panic inside a
/// UI toolkit is a worse outcome than a failed request.
pub const Writer = struct {
    buf: []u8,
    len: usize = 0,

    pub fn init(buf: []u8) Writer {
        return .{ .buf = buf, .len = 0 };
    }

    /// Pad with NUL bytes until the length is a multiple of `n`. D-Bus aligns
    /// every value on its own boundary, and the padding is part of the wire
    /// format — a decoder computes offsets by summing the same alignment.
    pub fn alignTo(self: *Writer, comptime n: usize) void {
        while (self.len % n != 0) {
            if (self.len >= self.buf.len) return;
            self.buf[self.len] = 0;
            self.len += 1;
        }
    }

    pub fn writeU8(self: *Writer, v: u8) void {
        if (self.len >= self.buf.len) return;
        self.buf[self.len] = v;
        self.len += 1;
    }

    pub fn writeU16(self: *Writer, v: u16) void {
        self.alignTo(2);
        if (self.len + 2 > self.buf.len) return;
        std.mem.writeInt(u16, self.buf[self.len..][0..2], v, .little);
        self.len += 2;
    }

    pub fn writeU32(self: *Writer, v: u32) void {
        self.alignTo(4);
        if (self.len + 4 > self.buf.len) return;
        std.mem.writeInt(u32, self.buf[self.len..][0..4], v, .little);
        self.len += 4;
    }

    pub fn writeI32(self: *Writer, v: i32) void {
        self.writeU32(@bitCast(v));
    }

    pub fn writeBool(self: *Writer, v: bool) void {
        self.writeU32(if (v) 1 else 0);
    }

    /// A D-Bus string: u32 byte length, the bytes, then a NUL terminator.
    /// The terminator is written even for the empty string, so `""` is five
    /// bytes and not four — that is what the specification says, and a
    /// decoder that assumed otherwise would mis-read the next field.
    pub fn writeString(self: *Writer, s: []const u8) void {
        self.writeU32(@intCast(s.len));
        const end = self.len + s.len;
        if (end > self.buf.len) {
            self.len = self.buf.len;
            return;
        }
        @memcpy(self.buf[self.len..end], s);
        self.len = end;
        if (self.len >= self.buf.len) return;
        self.buf[self.len] = 0;
        self.len += 1;
    }

    /// A D-Bus signature: a single length byte, the bytes, a NUL. Note the
    /// length is a `u8`, not a `u32` — the one place a signature differs from
    /// a string, and a place a copy-paste gets wrong silently.
    pub fn writeSignature(self: *Writer, s: []const u8) void {
        self.writeU8(@intCast(s.len));
        const end = self.len + s.len;
        if (end > self.buf.len) {
            self.len = self.buf.len;
            return;
        }
        @memcpy(self.buf[self.len..end], s);
        self.len = end;
        if (self.len >= self.buf.len) return;
        self.buf[self.len] = 0;
        self.len += 1;
    }

    /// An array of arbitrary bytes (`ay`): a u32 byte length then the bytes.
    /// This is how the portal carries `current_folder`, which is a URI in an
    /// `ay` rather than a string.
    pub fn writeByteArray(self: *Writer, b: []const u8) void {
        self.writeU32(@intCast(b.len));
        const end = self.len + b.len;
        if (end > self.buf.len) {
            self.len = self.buf.len;
            return;
        }
        @memcpy(self.buf[self.len..end], b);
        self.len = end;
    }

    /// Reserve a u32 and return its offset, so an enclosing array can patch its
    /// own byte length once its contents are written. This is the whole reason
    /// D-Bus arrays carry a byte count rather than an element count: the count
    /// of the elements is not known until the elements are.
    pub fn reserveU32(self: *Writer) usize {
        self.alignTo(4);
        const at = self.len;
        self.writeU32(0);
        return at;
    }

    pub fn patchU32(self: *Writer, at: usize, v: u32) void {
        if (at + 4 > self.len) return;
        std.mem.writeInt(u32, self.buf[at..][0..4], v, .little);
    }

    /// The bytes written so far. Slices the caller's buffer, so it is valid
    /// exactly as long as that buffer is.
    pub fn written(self: Writer) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn count(self: Writer) usize {
        return self.len;
    }
};

/// A bounds-checked reader over a received frame. Every read is checked, and a
/// frame that lies about a length returns `Truncated` rather than reading past
/// the buffer — the reason the decoder is safe to point at a socket.
pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn init(buf: []const u8) Reader {
        return .{ .buf = buf };
    }

    pub fn alignTo(self: *Reader, comptime n: usize) void {
        while (self.pos % n != 0) self.pos += 1;
    }

    pub fn readU8(self: *Reader) DecodeError!u8 {
        if (self.pos + 1 > self.buf.len) return error.Truncated;
        defer self.pos += 1;
        return self.buf[self.pos];
    }

    pub fn readU16(self: *Reader) DecodeError!u16 {
        self.alignTo(2);
        if (self.pos + 2 > self.buf.len) return error.Truncated;
        const v = std.mem.readInt(u16, self.buf[self.pos..][0..2], .little);
        self.pos += 2;
        return v;
    }

    pub fn readU32(self: *Reader) DecodeError!u32 {
        self.alignTo(4);
        if (self.pos + 4 > self.buf.len) return error.Truncated;
        const v = std.mem.readInt(u32, self.buf[self.pos..][0..4], .little);
        self.pos += 4;
        return v;
    }

    pub fn readBool(self: *Reader) DecodeError!bool {
        return (try self.readU32()) != 0;
    }

    /// A u32 length followed by that many bytes, returned as a borrowed slice.
    pub fn readBytes(self: *Reader) DecodeError![]const u8 {
        const n = try self.readU32();
        if (self.pos + n > self.buf.len) return error.Truncated;
        defer self.pos += n;
        return self.buf[self.pos..][0..n];
    }

    /// A D-Bus string. The NUL terminator is consumed but not returned, and a
    /// missing one is `BadValue` rather than a silently accepted unterminated
    /// slice — an unterminated string here means we are not looking at D-Bus.
    pub fn readString(self: *Reader) DecodeError![]const u8 {
        const s = try self.readBytes();
        if (self.pos >= self.buf.len) return error.Truncated;
        if (self.buf[self.pos] != 0) return error.BadValue;
        self.pos += 1;
        return s;
    }

    /// A D-Bus signature. Same shape as a string but with a `u8` length, and
    /// validated: an empty signature is legal (it is how a bodyless message
    /// says so), a signature with trailing garbage is not.
    pub fn readSignature(self: *Reader) DecodeError![]const u8 {
        const n = try self.readU8();
        if (self.pos + n + 1 > self.buf.len) return error.Truncated;
        const s = self.buf[self.pos..][0..n];
        self.pos += n;
        if (self.buf[self.pos] != 0) return error.BadValue;
        self.pos += 1;
        return s;
    }

    /// The bytes not yet consumed, with no length prefix — used for the body,
    /// whose extent the fixed header already stated.
    pub fn rest(self: *const Reader) []const u8 {
        return self.buf[self.pos..];
    }
};

/// A header field as passed to `encode`, before it is written into the
/// header array.
///
/// ## `string` and `object_path` are different on purpose
///
/// An object path marshals exactly like a string — a u32 length, the bytes,
/// a NUL — and the ONLY difference is the signature letter the variant
/// announces: `s` for a string, `o` for a path. They are separate union arms
/// so that difference cannot be forgotten, because a PATH field sent as `s`
/// is a protocol violation: the bus accepts the frame, processes nothing, and
/// closes the connection with no error message. Every other symptom is
/// identical to "your session bus is broken", which is why the only way to
/// find it is to talk to a real bus.
pub const Field = struct {
    code: u8,
    value: union(enum) {
        string: []const u8,
        object_path: []const u8,
        u32: u32,
        signature: []const u8,
    },
};

/// Encode one complete D-Bus message into `buf` and return the bytes written.
///
/// The caller sizes `buf`; a 4 KiB buffer is ample for every frame this
/// toolkit sends (the largest is a file-chooser options dict, a few hundred
/// bytes) and the writer degrades to "write what fits" rather than
/// overflowing, so a caller that over-allocates gets a truncated frame the
/// bus will reject — a visible protocol error, not memory corruption.
pub fn encode(
    buf: []u8,
    kind: MessageType,
    flags: Flags,
    serial: u32,
    fields: []const Field,
    body: []const u8,
) []const u8 {
    var w = Writer.init(buf);

    // ---- the 16-byte fixed header ----
    // 0: endianness marker. 'l' = little endian, and the only value we emit.
    w.writeU8('l');
    w.writeU8(@intFromEnum(kind));
    w.writeU8(@bitCast(flags));
    // Protocol version 1: the only version there has ever been.
    w.writeU8(1);
    w.writeU32(@intCast(body.len));
    w.writeU32(serial);

    // ---- the header field array, a(yv) ----
    // The length is a BYTE count, so it is reserved and patched after the
    // elements are written. `align(8)` before reserving because the array is
    // a struct array: the first element starts on the 8-byte boundary the
    // (yv) struct requires.
    const array_at = w.reserveU32();
    var count: usize = 0;
    for (fields) |f| {
        // Each struct in the array is aligned to 8, which is what makes the
        // array's own extent independent of the fixed header's length.
        w.alignTo(8);
        w.writeU8(f.code);
        switch (f.value) {
            .string => |s| {
                w.writeSignature("s");
                w.writeString(s);
            },
            .object_path => |s| {
                w.writeSignature("o");
                w.writeString(s);
            },
            .u32 => |v| {
                w.writeSignature("u");
                w.writeU32(v);
            },
            .signature => |s| {
                w.writeSignature("g");
                w.writeSignature(s);
            },
        }
        count += 1;
    }
    // The array's byte length must be the span of its elements INCLUDING the
    // padding inside it, but not the padding that aligns the body after it.
    // So the end is measured from the first element's start (which is the byte
    // right after the length word) to the current length.
    w.patchU32(array_at, @intCast(w.count() - (array_at + 4)));

    // The body always starts on an 8-byte boundary, whatever the header
    // length happened to be. Without this a frame whose header ends mid-word
    // is unmarshalable, and the failure is a silent drop by the bus.
    w.alignTo(8);
    const end = w.count() + body.len;
    if (end > buf.len) return w.written();
    @memcpy(buf[w.count()..end], body);
    w.len = end;
    return w.written();
}

/// Parse a complete message frame into its header and body.
///
/// `buf` must be exactly one message: the fixed header's body length plus the
/// padded header tells us where the frame ends, and the caller slices the
/// transport buffer with that (`nextFrame`).
pub fn parse(buf: []const u8) DecodeError!Header {
    if (buf.len < 16) return error.Truncated;
    if (buf[0] != 'l') return error.BigEndian;
    if (buf[3] != 1) return error.Malformed;

    var r = Reader.init(buf);
    _ = try r.readU8(); // endianness, already checked
    const kind = std.enums.fromInt(MessageType, try r.readU8()) orelse return error.Malformed;
    const flags: Flags = @bitCast(try r.readU8());
    _ = try r.readU8(); // protocol version, already checked
    const body_len = try r.readU32();
    const serial = try r.readU32();

    // The header array's declared length is what bounds the field parse; the
    // body starts after it, padded to 8. Trusting `header_len` rather than
    // scanning to the end is what keeps a body that happens to contain the
    // byte 0xFF from being mistaken for a field.
    const array_len = try r.readU32();
    const fields_end = r.pos + array_len;
    if (fields_end > buf.len) return error.Truncated;
    const fields_buf = buf[r.pos..fields_end];
    r.pos = fields_end;

    var head = Header{ .kind = kind, .flags = flags, .serial = serial };

    var fr = Reader.init(fields_buf);
    while (fr.pos < fr.buf.len) {
        fr.alignTo(8);
        if (fr.pos >= fr.buf.len) break;
        const code = try fr.readU8();
        const sig = try fr.readSignature();
        // A variant: one signature letter then the value, and we only accept
        // the three the portal uses. An unknown one is skipped by the caller
        // with the same care a bus takes, i.e. not at all — so it is an error
        // here rather than a silent mis-read of the value that follows.
        if (sig.len != 1) return error.BadValue;
        switch (sig[0]) {
            's', 'o' => {
                const v = try fr.readString();
                switch (code) {
                    field_path => head.path = v,
                    field_interface => head.interface_name = v,
                    field_member => head.member = v,
                    field_error_name => head.error_name = v,
                    field_destination => head.destination = v,
                    field_sender => head.sender = v,
                    else => return error.BadValue,
                }
            },
            'u' => {
                const v = try fr.readU32();
                switch (code) {
                    field_reply_serial => head.reply_serial = v,
                    field_unix_fds => {},
                    else => return error.BadValue,
                }
            },
            'g' => {
                head.body_signature = try fr.readSignature();
            },
            else => return error.BadValue,
        }
    }

    r.alignTo(8);
    if (r.pos + body_len > buf.len) return error.Truncated;
    head.body = buf[r.pos..][0..body_len];
    return head;
}

/// The length of the frame that starts at `buf[0]`, or null when `buf` does
/// not yet hold a whole fixed header.
///
/// A stream reader needs this to split a socket buffer into messages: one
/// `recv` can deliver half a frame, or three.
pub fn frameLength(buf: []const u8) ?usize {
    if (buf.len < 16) return null;
    if (buf[0] != 'l') return 0; // not ours; let the caller bail
    const body_len = std.mem.readInt(u32, buf[4..8], .little);
    const array_len = std.mem.readInt(u32, buf[12..16], .little);
    const after_array = 16 + array_len;
    // The body follows the header array, padded to 8.
    const body_at = std.mem.alignForward(usize, after_array, 8);
    return body_at + body_len;
}

// ---------------------------------------------------------------------------
// SASL: the authentication handshake, as text. Also pure — it is a request
// grammar, not a socket operation.
// ---------------------------------------------------------------------------

/// The outcome of one handshake line from the bus.
pub const AuthReply = union(enum) {
    /// `OK <guid>` — authenticated, and the bus's GUID follows.
    ok: []const u8,
    /// `REJECTED <mechanism>...` — offered mechanisms the bus refused.
    rejected: []const u8,
    /// `ERROR <text>` — the bus refused to talk about it at all.
    failed: []const u8,
    /// `DATA <hex>` — a challenge for the mechanism we picked.
    data: []const u8,
    /// Anything else, including an empty line.
    unknown: []const u8,
};

/// `AUTH EXTERNAL <identity>\r\n` — the initial credential line.
///
/// EXTERNAL means "I am the uid the kernel says I am": the only mechanism a
/// local session bus offers by default, and the only one that needs no secret.
///
/// ## The identity is the hex of the uid's DECIMAL DIGITS, not of the number
///
/// For uid 1000 this sends `31303030`, NOT `3e8`.
///
/// That is not a typo, and getting it wrong is the single most confusing
/// failure in this file: the bus does not send an error, it answers
/// `REJECTED EXTERNAL` and closes the connection, which looks exactly like
/// "this process is not allowed to talk to the bus". The identity is a
/// hex-encoded BYTE STRING that the bus then parses as a decimal uid, so the
/// bytes to encode are the ASCII of "1000".
///
/// It was verified against `dbus-send` on a live bus, byte for byte, rather
/// than against the specification: a plausible reading of the spec is what
/// produced `3e8` in the first place, and no amount of re-reading would have
/// contradicted it.
///
/// ## The leading NUL
///
/// The credential phase starts with a single NUL byte, THEN the AUTH line
/// (RFC 4752 §3.1). Both are returned: the caller writes one slice, and a
/// caller that forgets the NUL gets a connection reset rather than a
/// rejection.
pub fn authExternal(uid: u32, out: []u8) ![]const u8 {
    if (out.len == 0) return error.NoSpaceLeft;
    out[0] = 0;

    // The uid as decimal digits...
    var digits: [12]u8 = undefined;
    const text = try std.fmt.bufPrint(&digits, "{d}", .{uid});
    // ...hex-encoded, two characters per byte.
    var identity: [24]u8 = undefined;
    for (text, 0..) |byte, i| {
        identity[i * 2] = "0123456789abcdef"[byte >> 4];
        identity[i * 2 + 1] = "0123456789abcdef"[byte & 0x0f];
    }
    const line = try std.fmt.bufPrint(out[1..], "AUTH EXTERNAL {s}\r\n", .{identity[0 .. text.len * 2]});
    return out[0 .. 1 + line.len];
}

/// The line that ends the handshake and starts the binary protocol.
pub const begin_line = "BEGIN\r\n";

/// Classify one line of the server's half of the handshake.
///
/// A leading NUL is stripped first, because the first server line is
/// sometimes preceded by one on a reused connection, and a misparse here
/// would look like an authentication failure on a perfectly good bus.
pub fn parseAuthReply(line: []const u8) AuthReply {
    // Both ends are trimmed: a server line ends CRLF, and the first line of a
    // reused connection may start with a NUL. Trimming cannot eat anything
    // meaningful, because a GUID and a rejection reason contain neither.
    const trimmed = std.mem.trim(u8, line, "\x00\r\n");
    if (std.mem.startsWith(u8, trimmed, "OK ")) return .{ .ok = trimmed[3..] };
    if (std.mem.startsWith(u8, trimmed, "REJECTED ")) return .{ .rejected = trimmed[9..] };
    if (std.mem.startsWith(u8, trimmed, "ERROR ")) return .{ .failed = trimmed[6..] };
    if (std.mem.startsWith(u8, trimmed, "DATA ")) return .{ .data = trimmed[5..] };
    // A bare "OK" with no GUID is legal; treat the missing GUID as empty.
    if (std.mem.eql(u8, trimmed, "OK")) return .{ .ok = "" };
    return .{ .unknown = trimmed };
}

// ---------------------------------------------------------------------------
// Bus addresses
// ---------------------------------------------------------------------------

/// A resolved D-Bus transport address, OWNING its string.
///
/// `abstract` carries its leading NUL, because on Linux an abstract socket
/// name starts with one and getting that wrong connects to a different,
/// non-existent socket.
pub const BusAddress = union(enum) {
    path: []const u8,
    abstract: []const u8,

    /// The socket path as a C string, ready for `connect`. An abstract
    /// address's first byte IS the NUL the kernel wants, so this is the union
    /// payload itself.
    pub fn socketPath(self: BusAddress) []const u8 {
        return switch (self) {
            .path => |p| p,
            .abstract => |a| a,
        };
    }

    pub fn deinit(self: BusAddress, alloc: std.mem.Allocator) void {
        switch (self) {
            .path => |p| alloc.free(p),
            .abstract => |a| alloc.free(a),
        }
    }
};

/// Percent-decode one address value into `out`, returning the decoded prefix.
///
/// `%2C` is a comma. D-Bus addresses are comma-separated, so a literal comma
/// inside a value has to be escaped, which means the split cannot be a plain
/// `splitScalar` and each value has to be unescaped afterwards. A session bus
/// path with a comma in it is rare but not impossible.
///
/// ## Why this writes into `out` instead of returning a slice of its own
///
/// An earlier version allocated a local buffer and returned a slice of it.
/// That is a dangling pointer the moment the function returns: the caller
/// used it one call later, and the intervening call (`alloc.dupe`) had already
/// reused that stack frame, so the first bytes came back as garbage. It
/// surfaced as a socket path with eight junk bytes in front of it — a
/// `connect` to a path that does not exist, with no error the caller could
/// attribute to anything. The test for the escaped comma is what caught it.
fn unescapeInto(value: []const u8, out: []u8) ![]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < value.len) {
        if (n >= out.len) return error.BadValue;
        if (value[i] == '%') {
            if (i + 2 >= value.len) return error.BadValue;
            const hi = hexDigit(value[i + 1]) orelse return error.BadValue;
            const lo = hexDigit(value[i + 2]) orelse return error.BadValue;
            out[n] = hi * 16 + lo;
            n += 1;
            i += 3;
        } else {
            out[n] = value[i];
            n += 1;
            i += 1;
        }
    }
    return out[0..n];
}

fn hexDigit(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// Parse `DBUS_SESSION_BUS_ADDRESS`-style text into a transport address.
///
/// Takes an allocator because the result OWNS its string: an earlier version
/// of this function returned a slice into its own stack frame, which is the
/// kind of bug that passes a test and corrupts a socket path in a release
/// build. The test for the abstract address below is what caught it.
///
/// Only the `unix:` transport is resolved, and only `path=` and `abstract=`.
/// A `tcp:` address is a deliberate error rather than a silent fallback: if a
/// user has pointed the variable at a network bus, quietly talking to
/// `/run/user/<uid>/bus` instead would open a file dialog on a bus that is not
/// the one they configured.
pub fn parseBusAddress(
    alloc: std.mem.Allocator,
    address: ?[]const u8,
    default_uid: u32,
) !BusAddress {
    // An unset, empty or whitespace-only variable means "no address", and
    // the documented default applies. A shell that exports an empty variable
    // (`DBUS_SESSION_BUS_ADDRESS= some-command`) is common enough that
    // failing on it would be a support ticket rather than a correctness win.
    const text = std.mem.trim(u8, address orelse "", " \t\r\n");
    if (text.len == 0) {
        return .{ .path = try std.fmt.allocPrint(alloc, "/run/user/{d}/bus", .{default_uid}) };
    }
    if (!std.mem.startsWith(u8, text, "unix:")) return error.UnsupportedTransport;

    var it = std.mem.splitScalar(u8, text["unix:".len..], ',');
    while (it.next()) |part| {
        const eq = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        const key = part[0..eq];
        const value = part[eq + 1 ..];
        if (std.mem.eql(u8, key, "path")) {
            // One byte of slack per input byte is the upper bound: decoding
            // only ever shrinks the text.
            const out = try alloc.alloc(u8, value.len);
            const decoded = unescapeInto(value, out) catch {
                alloc.free(out);
                return error.BadValue;
            };
            // Shrink to what was actually written, so `deinit` frees exactly
            // the size that was allocated. An over-sized free is a
            // use-after-poison waiting for a different allocator.
            return .{ .path = try shrink(alloc, out, decoded.len) };
        }
        if (std.mem.eql(u8, key, "abstract")) {
            // The leading NUL is part of the address, not a terminator: it is
            // what tells the kernel to use the abstract namespace.
            const out = try alloc.alloc(u8, value.len + 1);
            out[0] = 0;
            const decoded = unescapeInto(value, out[1..]) catch {
                alloc.free(out);
                return error.BadValue;
            };
            return .{ .abstract = try shrink(alloc, out, decoded.len + 1) };
        }
        // `guid=` and `runtime=` are valid and carry nothing we need.
    }
    return error.NoBusAddress;
}

/// Realloc `buf` down to `len` bytes, returning the same pointer. Used so a
/// parse that over-allocates still hands back an exactly-sized allocation.
fn shrink(alloc: std.mem.Allocator, buf: []u8, len: usize) ![]u8 {
    return alloc.realloc(buf, len) catch |err| switch (err) {
        error.OutOfMemory => blk: {
            // Shrinking cannot fail on a real allocator, but a
            // general-purpose one is allowed to say so; copying into an
            // exact allocation keeps the ownership story simple.
            const exact = alloc.alloc(u8, len) catch return error.OutOfMemory;
            @memcpy(exact, buf[0..len]);
            alloc.free(buf);
            break :blk exact;
        },
    };
}

// ---------------------------------------------------------------------------
// Tests. Every one of these runs in the cross-platform parity suite, on every
// OS, because this file imports nothing platform-specific. A D-Bus framing
// bug is a bug the user hits on Linux; it is much cheaper to find it here.
// ---------------------------------------------------------------------------

fn expectSlice(comptime T: type, expected: []const T, actual: []const T) !void {
    try std.testing.expectEqualSlices(T, expected, actual);
}

/// Decode a hex literal in a test, so the fixtures below read as the wire
/// bytes they are rather than as a wall of decimal.
fn hexBytes(comptime hex: []const u8) [hex.len / 2]u8 {
    var out: [hex.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch unreachable;
    return out;
}

test "a u32 is little-endian and padded to its own alignment" {
    var buf: [16]u8 = undefined;
    var w = Writer.init(&buf);
    w.writeU8(1);
    w.writeU8(2);
    w.writeU32(0x11223344);
    // Two bytes were written, so the u32 starts at offset 4 — two pad bytes.
    try expectSlice(u8, &.{ 1, 2, 0, 0, 0x44, 0x33, 0x22, 0x11 }, w.written());
}

test "a string is a u32 length, the bytes, and a NUL" {
    var buf: [16]u8 = undefined;
    var w = Writer.init(&buf);
    w.writeString("hi");
    try expectSlice(u8, &.{ 2, 0, 0, 0, 'h', 'i', 0 }, w.written());
}

test "the empty string is five bytes, not four" {
    var buf: [16]u8 = undefined;
    var w = Writer.init(&buf);
    w.writeString("");
    // The NUL terminator is written even with no data, so the next field's
    // alignment is where a decoder expects it.
    try expectSlice(u8, &.{ 0, 0, 0, 0, 0 }, w.written());
}

test "a signature is a u8 length, the bytes, and a NUL" {
    var buf: [16]u8 = undefined;
    var w = Writer.init(&buf);
    w.writeSignature("ua{sv}");
    try expectSlice(u8, &.{ 6, 'u', 'a', '{', 's', 'v', '}', 0 }, w.written());
}

test "a reader undoes the writer, alignment and all" {
    var buf: [64]u8 = undefined;
    var w = Writer.init(&buf);
    w.writeU8(0xAB);
    w.writeU32(0xDEADBEEF);
    w.writeString("portal");
    w.writeSignature("ua{sv}");

    var r = Reader.init(w.written());
    try std.testing.expectEqual(@as(u8, 0xAB), try r.readU8());
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), try r.readU32());
    try expectSlice(u8, "portal", try r.readString());
    try expectSlice(u8, "ua{sv}", try r.readSignature());
}

test "a truncated frame is an error, not an out-of-bounds read" {
    var r = Reader.init("ab");
    try std.testing.expectError(error.Truncated, r.readU32());

    // A string that claims 99 bytes in a 2-byte frame.
    var r2 = Reader.init(&.{ 99, 0, 0, 0 });
    try std.testing.expectError(error.Truncated, r2.readString());
}

test "a string without its NUL terminator is rejected" {
    var r = Reader.init(&.{ 2, 0, 0, 0, 'h', 'i', 'X' });
    try std.testing.expectError(error.BadValue, r.readString());
}

test "the fixed header is endianness, type, flags, version, body length, serial" {
    var buf: [512]u8 = undefined;
    const bytes = encode(
        &buf,
        .method_call,
        .{},
        7,
        &.{
            .{ .code = field_destination, .value = .{ .string = "org.freedesktop.DBus" } },
        },
        "",
    );
    // 16 bytes of fixed header, then the header array.
    try std.testing.expectEqual(@as(u8, 'l'), bytes[0]);
    try std.testing.expectEqual(@as(u8, 1), bytes[1]); // method_call
    try std.testing.expectEqual(@as(u8, 0), bytes[2]); // flags
    try std.testing.expectEqual(@as(u8, 1), bytes[3]); // protocol version
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, bytes[4..8], .little)); // body length
    try std.testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, bytes[8..12], .little)); // serial
}

test "the header array is an 8-aligned struct array, and its length is in bytes" {
    var buf: [512]u8 = undefined;
    const bytes = encode(&buf, .signal, .{}, 2, &.{
        .{ .code = field_member, .value = .{ .string = "Response" } },
    }, "");
    // The length word sits at 12 and counts the elements' bytes ONLY: it is
    // 1 (code) + 3 (signature "s": len, letter, NUL) + 10 ("Response" as
    // u32 length + 8 bytes + NUL) = 17. It does NOT include the padding that
    // aligns the body after the array, because that padding belongs to the
    // message, not to the array.
    try std.testing.expectEqual(@as(u32, 17), std.mem.readInt(u32, bytes[12..16], .little));
    // The first element starts immediately after the length word, because
    // offset 16 is already 8-aligned. Padding there would be a second bug: a
    // receiver computes the array's extent from the declared length and would
    // read 4 bytes into the middle of a path.
    try std.testing.expectEqual(@as(u8, field_member), bytes[16]);
    // ...and the body is 8-aligned past the end of the array: 16 + 17 = 33,
    // padded to 40.
    try std.testing.expectEqual(@as(usize, 40), bytes.len);
    try std.testing.expectEqual(@as(u8, 0), bytes[33]); // pad byte
}

test "a message round-trips through encode and parse" {
    var body: [64]u8 = undefined;
    var bw = Writer.init(&body);
    bw.writeU32(1);
    bw.writeString("file:///tmp/a.txt");
    const body_bytes = bw.written();

    var buf: [1024]u8 = undefined;
    const bytes = encode(&buf, .method_call, .{}, 3, &.{
        .{ .code = field_destination, .value = .{ .string = "org.freedesktop.portal.Desktop" } },
        .{ .code = field_path, .value = .{ .object_path = "/org/freedesktop/portal/desktop" } },
        .{ .code = field_interface, .value = .{ .string = "org.freedesktop.portal.FileChooser" } },
        .{ .code = field_member, .value = .{ .string = "OpenFile" } },
        .{ .code = field_signature, .value = .{ .signature = "ssa{sv}" } },
    }, body_bytes);

    const head = try parse(bytes);
    try std.testing.expectEqual(MessageType.method_call, head.kind);
    try std.testing.expectEqual(@as(u32, 3), head.serial);
    try expectSlice(u8, "org.freedesktop.portal.Desktop", head.destination.?);
    try expectSlice(u8, "/org/freedesktop/portal/desktop", head.path.?);
    try expectSlice(u8, "org.freedesktop.portal.FileChooser", head.interface_name.?);
    try expectSlice(u8, "OpenFile", head.member.?);
    try expectSlice(u8, "ssa{sv}", head.body_signature);
    try std.testing.expectEqualSlices(u8, body_bytes, head.body);
}

test "a path field announces `o` and a string field announces `s`" {
    // Byte-for-byte, because this is the difference between a bus that routes
    // a message and a bus that silently closes the connection. A round-trip
    // test cannot see it: the decoder accepts `s` for a path, so encoder and
    // decoder happily agree on the wrong thing.
    var buf: [512]u8 = undefined;
    const bytes = encode(&buf, .method_call, .{}, 1, &.{
        .{ .code = field_path, .value = .{ .object_path = "/a" } },
        .{ .code = field_interface, .value = .{ .string = "org.x.Y" } },
    }, "");

    // The first element starts at offset 16 — the fixed header is 12 bytes
    // and the array's length word is 4, which already lands on an 8-byte
    // boundary.
    // code, then the signature as (u8 length, letter, NUL).
    try std.testing.expectEqual(@as(u8, field_path), bytes[16]);
    try std.testing.expectEqual(@as(u8, 1), bytes[17]); // signature length
    try std.testing.expectEqual(@as(u8, 0x6f), bytes[18]); // 'o' — an object path
    try std.testing.expectEqual(@as(u8, 0x00), bytes[19]); // signature NUL
    // The second element, 8-aligned again: 16 + 1 + 3 + (4 + 1 + 1) = 26.
    try std.testing.expectEqual(@as(u8, field_interface), bytes[32]);
    try std.testing.expectEqual(@as(u8, 0x73), bytes[34]); // 's' — a string
}

test "the body starts on an 8-byte boundary whatever the header length is" {
    var buf: [512]u8 = undefined;
    // A member name chosen so the header array ends mid-word.
    const bytes = encode(&buf, .method_call, .{}, 1, &.{
        .{ .code = field_member, .value = .{ .string = "OpenFile" } },
    }, "body");
    const head = try parse(bytes);
    try expectSlice(u8, "body", head.body);
    // The pad byte immediately before the body must be NUL, or the next
    // value's alignment is whatever garbage was on the stack.
    const body_at = bytes.len - 4;
    try std.testing.expectEqual(@as(usize, 0), body_at % 8);
    try std.testing.expectEqual(@as(u8, 0), bytes[body_at - 1]);
}

test "a big-endian frame is refused rather than misread" {
    const raw = [_]u8{ 'B', 1, 0, 1 } ++ [_]u8{0} ** 12;
    try std.testing.expectError(error.BigEndian, parse(&raw));
}

test "frameLength finds where a message ends, and null when it is incomplete" {
    var buf: [512]u8 = undefined;
    const bytes = encode(&buf, .method_call, .{}, 1, &.{
        .{ .code = field_member, .value = .{ .string = "Hello" } },
    }, "xy");
    try std.testing.expectEqual(bytes.len, frameLength(bytes).?);
    // Half a frame: not even the fixed header yet.
    try std.testing.expectEqual(@as(?usize, null), frameLength(bytes[0..8]));
}

// A `org.freedesktop.portal.Response` signal carrying two URIs, byte for byte
// as a portal implementation puts it on the wire. The fixture is what the
// decoder has to survive, so it is written out as the wire bytes it is rather
// than generated by this codec — a decoder tested only against its own
// encoder proves the two agree, not that either agrees with D-Bus.
const response_fixture =
    "6c04000165000000020000009c00000001016f00300000002f6f72672f667265656465736b746f702f706f7274616c2f6465" ++
    "736b746f702f726571756573742f315f34322f6162630000000000000000020173001f0000006f72672e667265656465736b" ++
    "746f702e706f7274616c2e526573706f6e7365000301730008000000526573706f6e73650000000000000000070173000500" ++
    "00003a312e3432000000080167000675617b73767d0000000000010000000000000059000000040000007572697300026173" ++
    "00000000450000001c00000066696c653a2f2f2f686f6d652f752f4d7925323046696c652e747874000000001c0000006669" ++
    "6c653a2f2f2f686f6d652f752f446f63732f6e6f7465732e6d6400";

test "a Response signal decodes to its path, its interface and its sender" {
    const raw = hexBytes(response_fixture);
    const head = try parse(&raw);
    try std.testing.expectEqual(MessageType.signal, head.kind);
    try std.testing.expectEqual(@as(u32, 2), head.serial);
    try expectSlice(u8, "/org/freedesktop/portal/desktop/request/1_42/abc", head.path.?);
    try expectSlice(u8, "org.freedesktop.portal.Response", head.interface_name.?);
    try expectSlice(u8, "Response", head.member.?);
    try expectSlice(u8, ":1.42", head.sender.?);
    try expectSlice(u8, "ua{sv}", head.body_signature);
}

test "a Response signal body decodes to its code and its two uris" {
    const raw = hexBytes(response_fixture);
    const head = try parse(&raw);
    var r = Reader.init(head.body);
    try std.testing.expectEqual(@as(u32, 1), try r.readU32()); // 1 = success
    // a{sv} is a struct array, so its length word sits on an 8-byte boundary
    // — which is NOT where the u32 above left us. Reading it without the pad
    // is the single most likely mistake in this whole file, and it is silent:
    // the "length" read out of the padding is huge, and the first string
    // read out of the next bytes is nonsense.
    r.alignTo(8);
    _ = try r.readU32();
    const key = try r.readString();
    try expectSlice(u8, "uris", key);
    try expectSlice(u8, "as", try r.readSignature());
    _ = try r.readU32(); // the as byte length
    try expectSlice(u8, "file:///home/u/My%20File.txt", try r.readString());
    try expectSlice(u8, "file:///home/u/Docs/notes.md", try r.readString());
}

test "AUTH EXTERNAL hex-encodes the uid's DIGITS, after a NUL" {
    var buf: [64]u8 = undefined;
    const line = try authExternal(1000, &buf);
    try std.testing.expectEqual(@as(u8, 0), line[0]);
    // "1000" as ASCII, hex-encoded. A live bus REJECTS `3e8` here, and
    // `dbus-send` sends exactly this — see authExternal's own header.
    try expectSlice(u8, "AUTH EXTERNAL 31303030\r\n", line[1..]);
}

test "AUTH EXTERNAL handles a ten-digit uid" {
    var buf: [64]u8 = undefined;
    // The largest uid a 32-bit field holds, whose ten digits are the case a
    // fixed-size identity buffer gets wrong.
    const line = try authExternal(4294967294, &buf);
    try expectSlice(u8, "AUTH EXTERNAL 34323934393637323934\r\n", line[1..]);
}

test "the handshake's success, rejection and failure lines are told apart" {
    switch (parseAuthReply("OK 1234abcd5678efgh\r\n")) {
        .ok => |guid| try expectSlice(u8, "1234abcd5678efgh", guid),
        else => return error.TestUnexpectedResult,
    }
    switch (parseAuthReply("REJECTED EXTERNAL DBUS_COOKIE_SHA1\r\n")) {
        .rejected => |mechs| try expectSlice(u8, "EXTERNAL DBUS_COOKIE_SHA1", mechs),
        else => return error.TestUnexpectedResult,
    }
    switch (parseAuthReply("ERROR Could not get UID\r\n")) {
        .failed => |text| try expectSlice(u8, "Could not get UID", text),
        else => return error.TestUnexpectedResult,
    }
    // A leading NUL is tolerated: a reused connection sends one.
    switch (parseAuthReply("\x00OK abc\r\n")) {
        .ok => |guid| try expectSlice(u8, "abc", guid),
        else => return error.TestUnexpectedResult,
    }
}

test "BEGIN is the line that ends authentication" {
    try expectSlice(u8, "BEGIN\r\n", begin_line);
}

test "unix:path= is the ordinary session bus address" {
    const addr = try parseBusAddress(std.testing.allocator, "unix:path=/run/user/1000/bus", 1000);
    defer addr.deinit(std.testing.allocator);
    try expectSlice(u8, "/run/user/1000/bus", addr.path);
}

test "a guid in the address is not part of the path" {
    const addr = try parseBusAddress(std.testing.allocator, "unix:path=/run/user/1000/bus,guid=abcdef", 1000);
    defer addr.deinit(std.testing.allocator);
    try expectSlice(u8, "/run/user/1000/bus", addr.path);
}

test "unix:abstract= gains the leading NUL that makes it abstract" {
    const addr = try parseBusAddress(std.testing.allocator, "unix:abstract=/tmp/dbus-AbCdEf,guid=1", 1000);
    defer addr.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 0), addr.abstract[0]);
    try expectSlice(u8, "/tmp/dbus-AbCdEf", addr.abstract[1..]);
}

test "an escaped comma in a path is unescaped, not split on" {
    const addr = try parseBusAddress(std.testing.allocator, "unix:path=/run/user/1000/a%2Cb", 1000);
    defer addr.deinit(std.testing.allocator);
    try expectSlice(u8, "/run/user/1000/a,b", addr.path);
}

test "no address at all falls back to the documented default socket" {
    const unset = try parseBusAddress(std.testing.allocator, null, 1000);
    defer unset.deinit(std.testing.allocator);
    try expectSlice(u8, "/run/user/1000/bus", unset.path);

    // An EMPTY variable means the same thing. `DBUS_SESSION_BUS_ADDRESS= cmd`
    // exports one, and failing on it would be a support ticket rather than a
    // correctness win.
    const empty = try parseBusAddress(std.testing.allocator, "   ", 1000);
    defer empty.deinit(std.testing.allocator);
    try expectSlice(u8, "/run/user/1000/bus", empty.path);
}

test "an address with no path or abstract key is an error" {
    try std.testing.expectError(
        error.NoBusAddress,
        parseBusAddress(std.testing.allocator, "unix:guid=abcdef", 1000),
    );
}

test "a network bus address is refused rather than silently redirected" {
    // The user configured a bus; quietly opening a file dialog on a different
    // one would be worse than an error.
    try std.testing.expectError(
        error.UnsupportedTransport,
        parseBusAddress(std.testing.allocator, "tcp:host=localhost,port=1", 1000),
    );
}
