//! The file dialog for hosts that have none wired up yet — every platform but
//! Linux.
//!
//! ## What this is for
//!
//! `glinlandui.file_dialog` is a single name that means the same thing on every
//! host, and this module is what it resolves to when the host cannot actually
//! open a file dialog. It returns `error.Unsupported` from all three entry
//! points, and that is the WHOLE implementation, on purpose:
//!
//!  - macOS has `NSOpenPanel`, Windows has `IFileDialog`, and a browser has
//!    `<input type="file">`. Each is a small file in its own platform folder,
//!    written against that platform's own idioms — which is exactly what
//!    `linux/file_dialog.zig` is for the XDG portal.
//!  - Returning an error rather than a no-op result is the honest answer. A
//!    caller that asked for a file and got an empty `Selection` back would have
//!    to guess whether the user cancelled or the platform cannot; an error says
//!    so, and `contract.Error.Unsupported` is a case a UI is meant to handle by
//!    HIDING THE BUTTON rather than by showing a dialog that cannot open.
//!
//! It is also what a TEST build selects (see `platform.zig`), which is why the
//! parity suite can assert the contract's types on every OS without a window,
//! a compositor, or a session bus anywhere in sight.
const std = @import("std");
const contract = @import("file_dialog_contract.zig");

/// Re-exported so `glinlandui.file_dialog.Options` is this platform's module
/// and not a Linux one.
pub const Kind = contract.Kind;
pub const Rule = contract.Rule;
pub const Filter = contract.Filter;
pub const Options = contract.Options;
pub const Status = contract.Status;
pub const Selection = contract.Selection;
pub const Error = contract.Error;

/// Always `error.Unsupported`. See the file header.
pub fn openFile(_: std.mem.Allocator, _: Options) Error!Selection {
    return error.Unsupported;
}

/// Always `error.Unsupported`.
pub fn openFolder(_: std.mem.Allocator, _: Options) Error!Selection {
    return error.Unsupported;
}

/// Always `error.Unsupported`.
pub fn saveFile(_: std.mem.Allocator, _: Options) Error!Selection {
    return error.Unsupported;
}

/// True when this host can open a dialog at all, so a UI can hide its button
/// before the user clicks it rather than after.
pub fn available() bool {
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "every entry point says Unsupported, and says it the same way" {
    const alloc = std.testing.allocator;
    // The point of a stub that is a stub: all three agree, and none of them
    // invent a "cancelled" Selection that a caller would have to guess about.
    try std.testing.expectError(error.Unsupported, openFile(alloc, .{}));
    try std.testing.expectError(error.Unsupported, openFolder(alloc, .{ .kind = .open_folder }));
    try std.testing.expectError(error.Unsupported, saveFile(alloc, .{ .kind = .save_file }));
    try std.testing.expect(!available());
}
