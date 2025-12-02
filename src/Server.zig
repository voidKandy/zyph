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
/// where the library will expect to find pages
/// Currently this is only necessary because of the way
/// full page refreshes are handled;
/// They require a template, which requires the index.html file
/// Currently, I dont love this and would prefer this wasnt coupled and
/// users use whatever they wanted in place of a templaet. But at the same time,
/// this server architecture requires accessing a home template because of its
/// Hypermedia Oriented design
/// Another huge downside of this is that it leaks all the way down to ConnectionContext
pages_directory: std.fs.Dir,

const Self = @This();

pub fn init(
    a: std.mem.Allocator,
    pages_dir: std.fs.Dir,
    file_server_dir: ?std.fs.Dir,
) Self {
    @import("components.zig").ComponentsDirectory.init(a);
    return .{
        .routes = RouteMap.init(a),
        .pages_directory = pages_dir,
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
    self.server.deinit();
}

pub fn startServer(self: *Self, addr: std.net.Address, opts: std.net.Address.ListenOptions) !void {
    log.info(
        \\ Listening on {f}
    , .{addr});
    self.server = try std.net.Address.listen(addr, opts);
}

pub fn listen(self: *Self) !void {
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
