const std = @import("std");
const log = std.log.scoped(.RouteMap);
const Request = std.http.Server.Request;

/// Hypermedia Route takes a writer which it writes HTML to
/// The Server ultimatey owns this writer
pub const HypermediaRouteFunc = *fn (
    *const anyopaque,
    std.mem.Allocator,
    Request,
    *std.Io.Writer,
) anyerror!void;
/// Data route takes ownership of control flow, it does not take a writer.
pub const DataRouteFunc = *fn (
    *const anyopaque,
    *Request,
) anyerror!void;
/// Not found function should be considered a hypermedia route
pub const NotFoundFunc = *const fn (
    Request,
    *std.Io.Writer,
) anyerror!void;

const RouteFunc = union(enum) {
    const Pointers = struct {
        state_ptr: usize,
        func_ptr: usize,
    };

    hypermedia: Pointers,
    data: Pointers,

    /// The allocator and writer are used only in the case of a hypermedia route
    pub fn call(self: @This(), a: std.mem.Allocator, request: *Request, writer: *std.Io.Writer) anyerror!void {
        switch (self) {
            .hypermedia => |ptrs| try @call(.auto, @as(
                HypermediaRouteFunc,
                @ptrFromInt(ptrs.func_ptr),
            ), .{
                @as(*anyopaque, @ptrFromInt(ptrs.state_ptr)),
                a,
                request.*,
                writer,
            }),
            .data => |ptrs| try @call(.auto, @as(
                DataRouteFunc,
                @ptrFromInt(ptrs.func_ptr),
            ), .{
                @as(*anyopaque, @ptrFromInt(ptrs.state_ptr)),
                request,
            }),
        }
    }
};

map: std.StringHashMap(RouteFunc),
notFound: NotFoundFunc = struct {
    fn handler(_: Request, w: *std.Io.Writer) anyerror!void {
        try w.writeAll(
            \\<div> 404 Not Found </div>
        );
    }
}.handler,

const Self = @This();
pub fn init(a: std.mem.Allocator) Self {
    return .{
        .map = std.StringHashMap(RouteFunc).init(a),
    };
}

pub fn deinit(self: *Self) void {
    self.map.deinit();
}

pub fn registerHypermediaEndpoint(self: *Self, path: []const u8, instance: *anyopaque, func: anytype) !void {
    validateHypermediaEndpointRegisterArgs(func);
    if (path.len == 0) {
        return error.EmptyPath;
    }

    if (self.map.contains(path)) {
        return error.AlreadyExists;
    }

    try self.map.put(path, RouteFunc{ .hypermedia = .{
        .state_ptr = @intFromPtr(instance),
        .func_ptr = @intFromPtr(func),
    } });
}

pub fn registerDataEndpoint(self: *Self, path: []const u8, instance: *anyopaque, func: anytype) !void {
    validateDataEndpointRegisterArgs(func);
    if (path.len == 0) {
        return error.EmptyPath;
    }

    if (self.map.contains(path)) {
        return error.AlreadyExists;
    }

    try self.map.put(path, RouteFunc{ .stateful = .{
        .state_ptr = @intFromPtr(instance),
        .func_ptr = @intFromPtr(func),
    } });
}

inline fn validateHypermediaEndpointRegisterArgs(func: anytype) void {
    comptime {
        const func_info = @typeInfo(@TypeOf(func));

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

        if (f.params.len != 4) {
            @compileError("Expected func to have three parameters");
        }

        const arg_2_type = f.params[1].type.?;
        if (arg_2_type != std.mem.Allocator) {
            @compileError("Expected func's second argument to be of type Allocator. Found " ++
                @typeName(arg_2_type));
        }

        const arg_3_type = f.params[2].type.?;
        if (arg_3_type != Request) {
            @compileError("Expected func's third argument to be of type Request. Found " ++
                @typeName(arg_2_type));
        }

        const arg_4_type = f.params[3].type.?;
        if (arg_4_type != *std.Io.Writer) {
            @compileError("Expected func's fourth argument to be of type *std.Io.Writer. Found " ++
                @typeName(arg_3_type));
        }

        if (!ret: {
            const ret_info = @typeInfo(f.return_type orelse break :ret false);
            const set = ret_info.error_union.error_set;
            const payload = ret_info.error_union.payload;

            break :ret (payload == void and set == anyerror);
        }) {
            @compileError("Expected func's return type to be anyerror!void. Found " ++
                @typeName(f.return_type.?));
        }
    }
}

inline fn validateDataEndpointRegisterArgs(func: anytype) void {
    comptime {
        const func_info = @typeInfo(@TypeOf(func));

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

        if (f.params.len != 2) {
            @compileError("Expected func to have three parameters");
        }

        const arg_2_type = f.params[1].type.?;
        if (arg_2_type != *Request) {
            @compileError("Expected func's second argument to be of type *Request. Found " ++
                @typeName(arg_2_type));
        }

        if (!ret: {
            const ret_info = @typeInfo(f.return_type orelse break :ret false);
            const set = ret_info.error_union.error_set;
            const payload = ret_info.error_union.payload;

            break :ret (payload == void and set == anyerror);
        }) {
            @compileError("Expected func's return type to be anyerror!void. Found " ++
                @typeName(f.return_type.?));
        }
    }
}
