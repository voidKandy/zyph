const std = @import("std");
const zyph = @import("zyph");

test "main" {
    // requires `components` & `pages` directories and `pages/index.html`
    // This is a dumb test anyway and should be reworked ASAP
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .thread_safe = true,
    }){};
    defer if (gpa.detectLeaks()) std.log.err("LEAKS DETECTED IN MAIN ALLOCATOR\n", .{});

    const allocator = gpa.allocator();
    var server = zyph.Server.init(allocator, try std.fs.cwd().openDir("test_pages", .{}), null);
    defer server.deinit();

    try server.routes.registerHypermediaEndpoint("/", &.{}, &struct {
        fn handler(
            _: *@TypeOf(.{}),
            _: std.mem.Allocator,
            _: std.http.Server.Request,
            w: *std.Io.Writer,
        ) anyerror!void {
            try w.writeAll(
                \\ <div>Hello</div>
            );
        }
    }.handler);

    // try router.withTls(std.fs.cwd(), "local_ssl/localhost.crt", "local_ssl/localhost.key");
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    const port_str = env_map.get("PORT") orelse "3000";
    const port = try std.fmt.parseInt(u16, port_str, 10);
    const addr = try std.net.Address.parseIp("0.0.0.0", port);
    try server.startServer(addr, .{ .reuse_address = true });

    try server.listen();
}
