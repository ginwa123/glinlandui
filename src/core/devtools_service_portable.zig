// No devtool service on this host yet: the app compiles and runs, and serving says so instead of pretending.
const std = @import("std");
const service_mod = @import("devtools/service.zig");

pub const Handle = struct {
    // A host with no wake pipe: the window has nothing to poll, so it cannot be woken while idle.
    pub fn wakeFd(self: Handle) ?i32 {
        _ = self;
        return null;
    }
};

pub fn open(alloc: std.mem.Allocator, io: std.Io, name: []const u8, service: *service_mod.Service) ?Handle {
    _ = alloc;
    _ = io;
    _ = name;
    _ = service;
    return null;
}

pub fn request(io: std.Io, name: []const u8, line: []const u8, out: *std.Io.Writer) !void {
    _ = io;
    _ = name;
    _ = line;
    _ = out;
    return error.ServiceUnavailable;
}
