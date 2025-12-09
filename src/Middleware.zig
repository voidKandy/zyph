const std = @import("std");
const root = @import("root.zig");
const log = std.log.scoped(.middleware);
const Request = std.http.Server.Request;
const Allocator = std.mem.Allocator;

const MiddlewareFunc = *fn (*anyopaque, Allocator, *Request, *std.Io.Writer) anyerror!void;
pub const Kind = enum { pre, post };

kind: Kind,
state_ptr: usize,
func_ptr: usize,

const Self = @This();

pub fn call(self: @This(), a: std.mem.Allocator, request: *Request, writer: *std.Io.Writer) anyerror!void {
    try @call(.auto, @as(
        MiddlewareFunc,
        @ptrFromInt(self.func_ptr),
    ), .{
        @as(*anyopaque, @ptrFromInt(self.state_ptr)),
        a,
        request,
        writer,
    });
}

pub fn init(kind: Kind, instance: *anyopaque, func: anytype) Self {
    root.validateFunctionType(func, MiddlewareFunc);
    return .{
        .kind = kind,
        .state_ptr = @intFromPtr(instance),
        .func_ptr = @intFromPtr(func),
    };
}
