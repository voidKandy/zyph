const std = @import("std");
const zyph = @import("core");

pub const std_options = std.Options{
    .log_level = .warn,
};

const Route =
    struct {
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
    };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .thread_safe = true,
    }){};
    defer if (gpa.detectLeaks()) std.log.err("LEAKS DETECTED IN MAIN ALLOCATOR\n", .{});

    const allocator = gpa.allocator();

    var server = zyph.Server.init(allocator, null);

    try server.middlewares.put(
        "logger",
        zyph.Middleware.init(.pre, &.{}, &struct {
            fn middleware(_: *@TypeOf(.{}), a: std.mem.Allocator, r: *std.http.Server.Request, w: *std.Io.Writer) anyerror!void {
                _ = w;
                _ = a;
                std.log.scoped(.inside_logger_middleware).warn("Request from middleware: {any}", .{r});
            }
        }.middleware),
    );

    var hydration_context = try zyph.hydration_middleware.Context.init(allocator, try std.fs.cwd().openFile("test_pages/index.html", .{}));
    defer hydration_context.deinit(allocator);
    try server.middlewares.put(
        zyph.hydration_middleware.NAME,
        zyph.Middleware.init(.post, &hydration_context, &zyph.hydration_middleware.handler),
    );

    defer server.deinit();

    const home_route = try server.registerHypermediaEndpoint("/", &.{}, &Route.handler);
    try home_route.addMiddlewares(.pre, &.{"logger"});
    try home_route.addMiddlewares(.post, &.{zyph.hydration_middleware.NAME});

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
