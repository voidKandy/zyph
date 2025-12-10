const std = @import("std");
const root = @import("root.zig");
const tls = @import("tls");
const log = std.log.scoped(.Server);
const RouteMap = @import("RouteMap.zig");
const FileServer = @import("FileServer.zig");
const hydration_middleware = @import("hydration_middleware.zig");
const Middleware = @import("Middleware.zig");
const ConnectionContext = @import("ConnectionContext.zig");

/// This is the main struct that handles connections
/// Only a single one of these should exist.
/// It will spawn new `ConnectionContext` objects for each new connection to a client
///
middlewares: std.StringHashMap(Middleware),
routes: RouteMap,
files: ?FileServer,
allocator: std.mem.Allocator,
tls_auth: ?*tls.config.CertKeyPair = null,
server: std.net.Server = undefined,

const Self = @This();

pub fn init(
    a: std.mem.Allocator,
    file_server_dir: ?std.fs.Dir,
) Self {
    return .{
        .routes = RouteMap.init(),
        .files = if (file_server_dir) |d| FileServer.init(.{
            .allocator = a,
            .root_dir = d,
        }) catch @panic("failed to init file server") else null,
        .allocator = a,
        .middlewares = std.StringHashMap(Middleware).init(a),
    };
}

pub fn deinit(self: *Self) void {
    self.routes.deinit(self.allocator);
    if (self.tls_auth) |a| {
        a.deinit(self.allocator);
        self.allocator.destroy(a);
    }
    defer self.server.deinit();
}

pub fn withTls(self: *Self, dir: std.fs.Dir, cert_path: []const u8, key_path: []const u8) !void {
    const auth = self.allocator.create(tls.config.CertKeyPair) catch @panic("out of memory");
    auth.* = try tls.config.CertKeyPair.fromFilePath(self.allocator, dir, cert_path, key_path);
    self.tls_auth = auth;
}

pub fn startServer(self: *Self, addr: std.net.Address, opts: std.net.Address.ListenOptions) !void {
    self.server = try std.net.Address.listen(addr, opts);
}

pub fn listen(self: *Self) !void {
    log.info(
        \\ Listening on {f}
    , .{self.server.listen_address});
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .thread_safe = true,
    }){};
    const allocator = gpa.allocator();

    while (true) {
        var conn = self.server.accept() catch |err| {
            log.err(
                \\ Failed to accept connection: {s}
            , .{@errorName(err)});
            continue;
        };
        errdefer conn.stream.close();

        log.warn(
            \\ Connected to client at address: {f}
            \\
        , .{conn.address});

        const ctx = allocator.create(ConnectionContext) catch @panic("out of memory");
        ctx.* = try ConnectionContext.init(
            allocator,
            &self.*,
            conn,
        );

        const thread = std.Thread.spawn(.{}, ConnectionContext.handleConnection, .{
            ctx,
        }) catch |err| {
            log.err("unable to spawn connection thread: {s}", .{@errorName(err)});
            ctx.deinit();
            allocator.destroy(ctx);
            continue;
        };

        thread.detach();
    }
}

pub const RouteHandler = struct {
    data: *RouteMap.RouteData,
    server_ptr: *Self,

    pub fn addMiddlewares(self: @This(), kind: Middleware.Kind, names: []const []const u8) std.mem.Allocator.Error!void {
        for (names) |name| {
            const item = try self.server_ptr.*.allocator.create(RouteMap.MiddlewareItem);
            item.* = RouteMap.MiddlewareItem{
                .name = name,
                .node = std.SinglyLinkedList.Node{},
            };
            switch (kind) {
                .pre => self.data.*.middlewares.pre.prepend(&item.node),
                .post => self.data.*.middlewares.post.prepend(&item.node),
            }
        }
    }
};

pub fn registerHypermediaEndpoint(self: *Self, path: []const u8, instance: *anyopaque, func: anytype) !RouteHandler {
    root.validateFunctionType(func, RouteMap.HypermediaRouteFunc);
    if (path.len == 0) {
        return error.EmptyPath;
    }

    if (self.routes.map.contains(path)) {
        return error.AlreadyExists;
    }

    try self.routes.map.put(self.allocator, path, .{
        .func = RouteMap.RouteFunc{ .hypermedia = .{
            .state_ptr = @intFromPtr(instance),
            .func_ptr = @intFromPtr(func),
        } },
    });

    return .{
        .data = self.routes.map.getPtr(path).?,
        .server_ptr = self,
    };
}

pub fn registerDataEndpoint(self: *Self, path: []const u8, instance: *anyopaque, func: anytype) !RouteHandler {
    root.validateFunctionType(func, RouteMap.DataRouteFunc);
    if (path.len == 0) {
        return error.EmptyPath;
    }

    if (self.routes.map.contains(path)) {
        return error.AlreadyExists;
    }

    try self.routes.map.put(self.allocator, path, .{
        .func = RouteMap.RouteFunc{ .data = .{
            .state_ptr = @intFromPtr(instance),
            .func_ptr = @intFromPtr(func),
        } },
    });

    return .{
        .data = self.routes.map.getPtr(path).?,
        .server_ptr = self,
    };
}
