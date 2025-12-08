const std = @import("std");
const tls = @import("tls");
const log = std.log.scoped(.Server);
const RouteMap = @import("RouteMap.zig");
const FileServer = @import("FileServer.zig");
const ConnectionContext = @import("ConnectionContext.zig");

/// This is the main struct that handles connections
/// Only a single one of these should exist.
/// It will spawn new `ConnectionContext` objects for each new connection to a client
routes: RouteMap,
files: ?FileServer,
allocator: std.mem.Allocator,
tls_auth: ?*tls.config.CertKeyPair = null,
server: std.net.Server = undefined,

/// Additional Options
///
/// The entrypoint of the Hypermedia App
index_file_content: []u8,

const Self = @This();

pub fn init(
    a: std.mem.Allocator,
    index_file: std.fs.File,
    // pages_dir: std.fs.Dir,
    file_server_dir: ?std.fs.Dir,
) Self {
    @import("components.zig").ComponentsDirectory.init(a);
    var reader_buffer: [1024 * 64]u8 = undefined;
    var reader = index_file.reader(&reader_buffer);
    var dest_buffer: [1024 * 64]u8 = undefined;
    var amt_read: usize = 0;
    while (true) {
        const amt = reader.readPositional(&dest_buffer) catch |e| if (e == error.EndOfStream) break else @panic("failed to read index file");
        amt_read += amt;
        if (amt <= 0) break;
    }
    const index_file_content = a.dupe(u8, dest_buffer[0..amt_read]) catch @panic("out of memory");
    return .{
        .routes = RouteMap.init(a),
        .index_file_content = index_file_content,
        .files = if (file_server_dir) |d| FileServer.init(.{
            .allocator = a,
            .root_dir = d,
        }) catch @panic("failed to init file server") else null,
        .allocator = a,
    };
}

pub fn withTls(self: *Self, dir: std.fs.Dir, cert_path: []const u8, key_path: []const u8) !void {
    const auth = self.allocator.create(tls.config.CertKeyPair) catch @panic("out of memory");
    auth.* = try tls.config.CertKeyPair.fromFilePath(self.allocator, dir, cert_path, key_path);
    self.tls_auth = auth;
}

pub fn deinit(self: *Self) void {
    @import("components.zig").ComponentsDirectory.deinit();
    self.routes.deinit();
    if (self.tls_auth) |a| {
        a.deinit(self.allocator);
        self.allocator.destroy(a);
    }
    self.allocator.free(self.index_file_content);
    self.server.deinit();
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
            &self,
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
