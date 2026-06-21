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
/// keeping nullable for eventual userland configurability of presence of file server
/// as well as configurability of file server directory
files: ?FileServer,
allocator: std.mem.Allocator,
tls_auth: ?*tls.config.CertKeyPair = null,
server: std.Io.net.Server = undefined,
io: std.Io,

const Self = @This();

pub fn init(
    a: std.mem.Allocator,
    io: std.Io,
    file_server_dir: ?[]const u8,
) Self {
    return .{
        .routes = RouteMap.init(),
        .files = if (file_server_dir) |dir| FileServer.init(a, io, dir) catch @panic("OOM") else null,
        .allocator = a,
        .io = io,
        .middlewares = std.StringHashMap(Middleware).init(a),
    };
}

pub fn deinit(self: *Self) void {
    self.routes.deinit(self.allocator);
    if (self.tls_auth) |a| {
        a.deinit(self.allocator);
        self.allocator.destroy(a);
    }
    defer self.server.deinit(self.io);
}

pub fn withTls(self: *Self, dir: std.fs.Dir, cert_path: []const u8, key_path: []const u8) !void {
    const auth = self.allocator.create(tls.config.CertKeyPair) catch @panic("out of memory");
    auth.* = try tls.config.CertKeyPair.fromFilePath(self.allocator, dir, cert_path, key_path);
    self.tls_auth = auth;
}

pub fn startServer(self: *Self, addr: *const std.Io.net.IpAddress, opts: std.Io.net.IpAddress.ListenOptions) !void {
    self.server = try std.Io.net.IpAddress.listen(addr, self.io, opts);
}

pub fn listen(self: *Self) !void {
    log.info(
        \\ Listening on {f}
    , .{self.server.socket.address});

    while (true) {
        var conn = self.server.accept(self.io) catch |err| {
            log.err(
                \\ Failed to accept connection: {s}
            , .{@errorName(err)});
            continue;
        };
        errdefer conn.close(self.io);

        log.warn(
            \\ Connected to client at address: {f}
            \\
        , .{conn.socket.address});

        const ctx = self.allocator.create(ConnectionContext) catch @panic("out of memory");
        ctx.* = try ConnectionContext.init(
            self.allocator,
            &self.*,
            conn,
        );

        const thread = std.Thread.spawn(.{}, ConnectionContext.handleConnection, .{
            ctx,
        }) catch |err| {
            log.err("unable to spawn connection thread: {s}", .{@errorName(err)});
            ctx.deinit();
            self.allocator.destroy(ctx);
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
