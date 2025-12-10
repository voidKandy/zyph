const std = @import("std");
pub const Server = @import("Server.zig");
pub const Middleware = @import("Middleware.zig");
pub const cache = @import("cache.zig");
pub const hydration_middleware = @import("hydration_middleware.zig");

pub fn getHeader(r: std.http.Server.Request, key: []const u8) ?[]const u8 {
    if (r.server.reader.state != .received_head)
        std.debug.panic("Server reader in unexpected state {any}", .{r.server.reader.state});
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

/// skips validation of first function argument
/// Assumes that first argument is `*anyopaque`
pub inline fn validateFunctionType(func: anytype, TargetType: type) void {
    comptime {
        const func_info = @typeInfo(@TypeOf(func));
        const expected_info = @typeInfo(TargetType);

        const f = blk: {
            if (func_info == .pointer) {
                const inner = @typeInfo(func_info.pointer.child);
                if (inner == .@"fn") {
                    break :blk inner.@"fn";
                }
            }
            @compileError("Expected func to be a function pointer. Found " ++
                @typeName(@TypeOf(func)));
        };
        const ef = @typeInfo(expected_info.pointer.child).@"fn";

        if (f.params.len != ef.params.len) {
            @compileError("Expected func to have " ++ ef.params.len ++ " parameters");
        }

        // skipping anyopaque
        for (f.params[1..], ef.params[1..], 2..) |p, ep, i| {
            if (p.type != ep.type)
                @compileError("Expected func's " ++ i ++ " argument to be of type " ++ @typeName(ep.type.?) ++
                    " Found " ++
                    @typeName(p.type.?));
        }

        if (!ret: {
            const ret_info = @typeInfo(f.return_type orelse break :ret false);
            const eret_info = @typeInfo(ef.return_type orelse break :ret false);

            break :ret (std.meta.eql(eret_info, ret_info));
        }) {
            @compileError("Expected func's return type to be " ++ @typeName(ef.return_type.?) ++
                " Found " ++
                @typeName(f.return_type.?));
        }
    }
}
