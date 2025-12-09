const std = @import("std");
pub const Server = @import("Server.zig");
pub const Middleware = @import("Middleware.zig");
pub const cache = @import("cache.zig");
pub const hydration_middleware = @import("hydration_middleware.zig");

pub fn getHeader(r: std.http.Server.Request, key: []const u8) ?[]const u8 {
    var iter = r.iterateHeaders();

    while (iter.next()) |h| {
        if (std.ascii.eqlIgnoreCase(key, h.name)) {
            return h.value;
        }
    }

    return null;
}

pub fn parseRequestParts(r: *const std.http.Server.Request) struct { path: []const u8, query: ?[]const u8 } {
    const target = r.head.target;
    if (std.mem.indexOfScalar(u8, target, '?')) |i| {
        return .{
            .path = target[0..i],
            .query = target[i + 1 ..],
        };
    } else {
        return .{
            .path = target,
            .query = null,
        };
    }
}
