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

allocator: std.mem.Allocator,
recv_buf: []u8,
send_buf: []u8,
connection: ConnectionType,
auth: *const ?*tls.config.CertKeyPair,
file_server: *const ?FileServer,
map_ptr: *const RouteMap,
index_file_content: []u8,
const Self = @This();

const ConnectionType = union(enum) {
    http: std.net.Server.Connection,
    https: *tls.Connection,
};

const FullPageRefreshTemplate = zemplate.Template(struct { route_content: []const u8 });

const RECV_BUF_SIZE = 16 * 1024;
const SEND_BUF_SIZE = 16 * 1024;

pub fn init(allocator: std.mem.Allocator, server: *const *Server, conn: std.net.Server.Connection) std.mem.Allocator.Error!Self {
    return .{
        .allocator = allocator,
        .connection = .{ .http = conn },
        .file_server = &server.*.files,
        .auth = &server.*.tls_auth,
        .recv_buf = try allocator.alloc(u8, RECV_BUF_SIZE),
        .send_buf = try allocator.alloc(u8, SEND_BUF_SIZE),
        .map_ptr = &server.*.routes,
        .index_file_content = try allocator.dupe(u8, server.*.index_file_content),
        // .pages_directory = &server.*.pages_directory,
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

    self.auth = undefined;
    self.allocator.free(self.recv_buf);
    self.allocator.free(self.send_buf);
}

pub fn dispatchRequest(self: *Self, request: *Request) !void {
    const is_htmx_request = getHeader(request.*, "hx-request") != null;
    const hydrated_info = getHeader(request.*, "x-hydrated");
    const parts = parseRequestParts(&request.*);

    log.debug(
        \\ is htmx: {any}
        \\ info: {s}
    , .{ is_htmx_request, hydrated_info orelse "None" });

    const oob_swap = if (hydrated_info == null) "innerHTML" else "beforeend";

    var writer = std.Io.Writer.Allocating.init(self.allocator);
    defer writer.deinit();
    const func_opt = self.map_ptr.*.map.get(parts.path);

    log.debug(
        \\ Got Function Pointer: {any}
    , .{func_opt});
    var not_found = func_opt == null;

    if (func_opt) |func| {
        func.call(self.allocator, request, &writer.writer) catch |e| {
            log.err(
                \\ Error in route function: {any}
            , .{e});
            not_found = e == error.NotFound;
        };
        switch (func) {
            .data => if (!not_found) return,
            else => {},
        }
    }

    if (not_found) {
        try self.map_ptr.*.notFound(request.*, &writer.writer);
    }

    if (!is_htmx_request) {
        log.debug(
            \\ requires full page refresh
        , .{});

        // I really hate this
        // because it forces users to have an index.html within their pages directory
        // const tmplt_str = try self.pages_directory.*.readFileAlloc(self.allocator, "index.html", 1024 * 64);
        const content =
            try writer.toOwnedSlice();
        log.warn(
            \\ WRITER: {s}
            \\ RENDERING TO: {s}
        , .{
            // writer.written(),
            content,
            self.index_file_content,
        });
        var tmpl = FullPageRefreshTemplate.init(.{ .route_content = content });
        const render = try tmpl.render(self.allocator, self.index_file_content, .{});

        try writer.writer.writeAll(render);
    }

    const hydration_html = blk: {
        var component_buffer = std.ArrayList(u8).initCapacity(self.allocator, 1024) catch @panic("out of memory");
        component_buffer.appendSlice(self.allocator, std.fmt.allocPrint(self.allocator,
            \\  <section id="components-cache" hx-swap-oob="{s}">
        , .{oob_swap}) catch @panic("out of memory")) catch @panic("out of memory");
        ComponentsDirectory.tryUpdate() catch |e| log.err("Failed to update components directory: {any}\n", .{e});
        var map = try ComponentsDirectory.get().map.clone();

        if (hydrated_info) |header| {
            var header_elems = std.mem.splitScalar(u8, std.mem.trim(u8, header, "\n []"), ',');
            while (header_elems.next()) |elem_name| {
                const sanitized = std.mem.trim(u8, elem_name, "\n \"");
                if (sanitized.len == 0) continue;
                const hash = std.hash_map.hashString(sanitized);
                log.debug("removing {s} : {d}\n", .{ sanitized, hash });
                const removed = map.remove(std.hash_map.hashString(sanitized));
                if (!removed)
                    log.warn("failed to remove {s}\n", .{sanitized});
            }
        }

        var needed_iter = map.valueIterator();
        var included_counter: usize = 0;
        while (needed_iter.next()) |comp| {
            const needle =
                try std.fmt.allocPrint(self.allocator, "<{s}", .{comp.name});
            if (std.mem.indexOf(u8, writer.written(), needle) != null) {
                log.debug("including {s}\n", .{comp.name});
                try component_buffer.appendSlice(self.allocator, comp.content);
                included_counter += 1;
            }
        }

        if (included_counter == 0) {
            component_buffer.deinit(self.allocator);
            break :blk "";
        }
        component_buffer.appendSlice(self.allocator,
            \\  </section>
        ) catch @panic("out of memory");
        break :blk try component_buffer.toOwnedSlice(self.allocator);
    };
    try writer.writer.writeAll(hydration_html);

    try request.respond(try writer.toOwnedSlice(), .{
        .keep_alive = true,
        .status = if (not_found) .not_found else .ok,
    });
}

pub fn handleConnection(self: *Self) !void {
    var server: std.http.Server = undefined;
    defer self.deinit();
    const addr = self.connection.http.address;

    if (self.auth.*) |auth_ptr| {
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

fn serveHTTP(self: *Self, server: *std.http.Server, request: *Request) !void {
    var body: ?[]u8 = null;
    if (self.file_server.* == null) {
        log.debug(
            \\ No File Server
        , .{});
    } else {
        if (self.file_server.*.?.serve(request)) |_| {
            log.info(
                \\ File server served: {s}
            , .{request.head.target});
            return;
        } else |e| switch (e) {
            error.FileNotFound => {
                log.info(
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
