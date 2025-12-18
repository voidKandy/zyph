const std = @import("std");
const tls = @import("tls");
const zemplate = @import("zemplate");
const log = std.log.scoped(.ConnectionContext);
const Server = @import("Server.zig");
const FileServer = @import("FileServer.zig");
const RouteMap = @import("RouteMap.zig");
const Request = std.http.Server.Request;
const Connection = std.net.Server.Connection;
const getHeader = @import("root.zig").getHeader;
const parseRequestParts = @import("root.zig").parseRequestParts;
const ComponentsDirectory = @import("components.zig").ComponentsDirectory;

/// A single connection context is created per client connection
allocator: std.mem.Allocator,
recv_buf: []u8,
send_buf: []u8,
connection: ConnectionType,
server_ptr: *const Server,
const Self = @This();

const ConnectionType = union(enum) {
    http: std.net.Server.Connection,
    https: *tls.Connection,
};

const FullPageRefreshTemplate = zemplate.Template(struct { route_content: []const u8 });

const RECV_BUF_SIZE = 16 * 1024;
const SEND_BUF_SIZE = 16 * 1024;

pub fn init(allocator: std.mem.Allocator, server: *const Server, conn: std.net.Server.Connection) std.mem.Allocator.Error!Self {
    return .{
        .allocator = allocator,
        .connection = .{ .http = conn },
        .server_ptr = server,
        .recv_buf = try allocator.alloc(u8, RECV_BUF_SIZE),
        .send_buf = try allocator.alloc(u8, SEND_BUF_SIZE),
    };
}

pub fn deinit(self: *Self) void {
    switch (self.connection) {
        .http => |c| c.stream.close(),
        .https => |c| {
            c.close() catch |e| {
                log.err(
                    \\ Failed to close TLS connection: {any}
                , .{e});
            };
            self.allocator.destroy(c);
        },
    }

    self.allocator.free(self.recv_buf);
    self.allocator.free(self.send_buf);
}

pub fn dispatchRequest(self: *Self, request: *Request) anyerror!void {
    const parts = parseRequestParts(&request.*);
    // BAD?
    // _ = request.iterateHeaders();

    var writer = std.Io.Writer.Allocating.init(self.allocator);
    defer writer.deinit();
    const route_opt = self.server_ptr.*.routes.map.get(parts.path);

    log.debug(
        \\ Got Route Data: {any}
    , .{route_opt});
    var not_found = route_opt == null;

    var current_post_mw: ?*std.SinglyLinkedList.Node = null;
    if (route_opt) |route| {
        var current_pre_mw = route.middlewares.pre.first;
        current_post_mw = route.middlewares.post.first;

        while (current_pre_mw) |item| : (current_pre_mw = item.next) {
            const parent: *RouteMap.MiddlewareItem = @fieldParentPtr("node", item);
            if (self.server_ptr.*.middlewares.get(parent.name)) |m| {
                if (m.kind == .post) {
                    log.err(
                        \\ Middleware of .post type has been registered as a .pre type middleware!
                    , .{});
                    return error.MiddlewareInvalid;
                }
                m.call(self.allocator, request, &writer.writer) catch |e| {
                    log.err(
                        \\ Error in {any} middleware: {any}
                    , .{ parent.name, e });
                    return e;
                };
            }
        }

        route.func.call(self.allocator, request, &writer.writer) catch |e| {
            log.err(
                \\ Error in route function: {any}
            , .{e});
            switch (e) {
                error.NotFound => not_found = true,
                error.Redirect => return,
                else => return e,
            }
        };

        if (route.func == .data and !not_found) return;
    }

    if (not_found) {
        try self.server_ptr.*.routes.notFound(request.*, &writer.writer);
    }

    while (current_post_mw) |item| : (current_post_mw = item.next) {
        const parent: *RouteMap.MiddlewareItem = @fieldParentPtr("node", item);
        if (self.server_ptr.*.middlewares.get(parent.name)) |m| {
            if (m.kind == .pre) {
                log.err(
                    \\ Middleware of .pre type has been registered as a .post type middleware!
                , .{});
                return error.MiddlewareInvalid;
            }
            m.call(self.allocator, request, &writer.writer) catch |e| {
                log.err(
                    \\ Error in {any} middleware: {any}
                , .{ parent.name, e });
                return e;
            };
        }
    }

    try request.respond(try writer.toOwnedSlice(), .{
        .keep_alive = true,
        .status = if (not_found) .not_found else .ok,
    });
}

pub fn handleConnection(self: *Self) !void {
    var server: std.http.Server = undefined;
    defer self.deinit();
    const addr = self.connection.http.address;

    if (self.server_ptr.*.tls_auth) |auth_ptr| {
        const tls_conn = try self.allocator.create(tls.Connection);
        tls_conn.* = try tls.serverFromStream(self.connection.http.stream, .{ .auth = auth_ptr });
        self.connection = .{ .https = tls_conn };

        var r = self.connection.https.reader(self.recv_buf);
        var w = self.connection.https.writer(self.send_buf);
        server = std.http.Server.init(&r.interface, &w.interface);
        log.info(
            \\ Created HTTPS connection
        , .{});
    } else {
        var r = self.connection.http.stream.reader(self.recv_buf);
        var w = self.connection.http.stream.writer(self.send_buf);
        server = std.http.Server.init(r.interface(), &w.interface);
        log.info(
            \\ Created HTTP connection
        , .{});
    }

    while (true) {
        switch (server.reader.state) {
            .ready => {
                var req = server.receiveHead() catch |err| switch (err) {
                    error.HttpConnectionClosing => {
                        log.warn(
                            \\ Closing Connection with {f}
                        , .{addr});
                        break;
                    },
                    else => {
                        log.err("receiveHead err: {any}", .{err});
                        break;
                    },
                };

                switch (req.upgradeRequested()) {
                    .other => |other_protocol| {
                        log.err("Not supported protocol, {s}", .{other_protocol});
                        return;
                    },
                    .websocket => |key| {
                        var ws = try req.respondWebSocket(.{ .key = key orelse "" });
                        try self.serveWebSocket(&ws);
                    },
                    .none => {
                        try self.serveHTTP(&server, &req);
                    },
                }
            },
            .closing => {
                log.warn(
                    \\ Connection Closed
                , .{});
                break;
            },

            else => {},
        }
    }
}

fn serveHTTP(self: *Self, server: *std.http.Server, request: *Request) anyerror!void {
    var body: ?[]u8 = null;
    if (self.server_ptr.*.files == null) {
        log.debug(
            \\ No File Server
        , .{});
    } else if (self.server_ptr.*.files.?.serve(request)) |_| {
        log.info(
            \\ File server served: {s}
        , .{request.head.target});
        return;
    } else |e| switch (e) {
        error.FileNotFound => {
            log.warn(
                \\ File server could not find: {s}
            , .{request.head.target});
        },
        else => {
            log.err(
                \\ File server encountered an error: {any}
            , .{e});
            return e;
        },
    }

    if (request.head.content_length) |content_len| {
        log.info("reading content len: {d}\n", .{content_len});
        const buf = self.allocator.alloc(u8, content_len) catch @panic("out of memory");
        var reader = server.reader.bodyReader(buf, request.head.transfer_encoding, content_len);
        body = try reader.readAlloc(self.allocator, content_len);
        log.info("Received body: {s}", .{body.?});
    }

    try self.dispatchRequest(request);
}

fn serveWebSocket(self: *Self, ws: *std.http.Server.WebSocket) !void {
    _ = self;
    try ws.writeMessage("Hello from Zig WebSocket server", .text);
    while (true) {
        const msg = try ws.readSmallMessage();
        if (msg.opcode == .connection_close) {
            log.info("Client closed the WebSocket", .{});
            return;
        }
        try ws.writeMessage(msg.data, msg.opcode);
    }
}
