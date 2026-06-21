const std = @import("std");
const zyph = @import("core");

pub const std_options = std.Options{
    .log_level = .debug,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var server = zyph.Server.init(allocator, init.io, null);
    defer server.deinit();

    _ = try server.registerHypermediaEndpoint("/", &.{}, &struct {
        fn handler(
            _: *@TypeOf(.{}),
            _: std.mem.Allocator,
            _: std.http.Server.Request,
            w: *std.Io.Writer,
        ) anyerror!void {
            try w.writeAll(
                \\ <div>Hello World!</div>
            );
        }
    }.handler);
    const port_str = init.environ_map.get("PORT") orelse "3000";
    const port = try std.fmt.parseInt(u16, port_str, 10);
    const addr = try std.Io.net.IpAddress.parse("0.0.0.0", port);
    try server.startServer(&addr, .{ .reuse_address = true });

    server.listen() catch @panic("failed listen");

    // std.Thread.sleep(60_000);
    return;
}
