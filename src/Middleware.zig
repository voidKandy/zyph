const std = @import("std");
const log = std.log.scoped(.Middleware);
const Request = std.http.Server.Request;

const MiddlewareFunc = *const fn (*const anyopaque, Request) anyerror!void;

node: std.SinglyLinkedList.Node,
instance: anyopaque,
func: MiddlewareFunc,

const Self = @This();
fn init() void {}
