const std = @import("std");
const zyph = @import("core");

pub const std_options = std.Options{
    .log_level = .debug,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .thread_safe = true,
    }){};
    defer if (gpa.detectLeaks()) std.log.err("LEAKS DETECTED IN MAIN ALLOCATOR\n", .{});

    const allocator = gpa.allocator();
    var server = zyph.Server.init(allocator, try std.fs.cwd().openFile("test_pages/index.html", .{}), null);
    defer server.deinit();

    try server.routes.registerHypermediaEndpoint("/", null, &.{}, &struct {
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

    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    const port_str = env_map.get("PORT") orelse "3000";
    const port = try std.fmt.parseInt(u16, port_str, 10);
    const addr = try std.net.Address.parseIp("0.0.0.0", port);
    try server.startServer(addr, .{ .reuse_address = true });

    server.listen() catch @panic("failed listen");

    // std.Thread.sleep(60_000);
    return;
}
