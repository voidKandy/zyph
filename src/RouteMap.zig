const std = @import("std");
const log = std.log.scoped(.RouteMap);
const root = @import("root.zig");
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

pub const NotFoundFunc = *const fn (
    Request,
    *std.Io.Writer,
) anyerror!void;

pub const RouteFunc = union(enum) {
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

const RouteMiddlewareInfo = struct {
    pre: ?[]const []const u8 = null,
    post: ?[]const []const u8 = null,
};
const NewRouteMiddlewareInfo = struct {
    pre: std.SinglyLinkedList = std.SinglyLinkedList{},
    post: std.SinglyLinkedList = std.SinglyLinkedList{},
};

pub const MiddlewareItem = struct {
    node: std.SinglyLinkedList.Node,
    name: []const u8,
};

pub const RouteData = struct {
    middlewares: NewRouteMiddlewareInfo = .{},
    func: RouteFunc,
};

const Map = std.StringHashMapUnmanaged(RouteData);

map: Map,
notFound: NotFoundFunc = struct {
    fn handler(_: Request, w: *std.Io.Writer) anyerror!void {
        try w.writeAll(
            \\<div> 404 Not Found </div>
        );
    }
}.handler,

const Self = @This();
pub fn init() Self {
    return .{
        .map = Map{},
    };
}

/// Must be deinitialized with the allocator that created middlewares
pub fn deinit(self: *Self, a: std.mem.Allocator) void {
    self.map.deinit(a);
}
