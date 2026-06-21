const std = @import("std");
const zyph = @import("core");

pub const std_options = std.Options{
    .log_level = .debug,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var server = zyph.Server.init(allocator, init.io, "serve");
    defer server.deinit();

    const port_str = init.environ_map.get("PORT") orelse "3000";
    const port = try std.fmt.parseInt(u16, port_str, 10);
    const addr = try std.Io.net.IpAddress.parse("0.0.0.0", port);
    try server.startServer(&addr, .{ .reuse_address = true });

    server.listen() catch @panic("failed listen");

    return;
}
