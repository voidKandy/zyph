const std = @import("std");
const log = std.log.scoped(.FileServer);
const root = @import("root.zig");
const mime = @import("mime");

pub const FileServerDirectory = root.cache.CachedDirectory(
    &struct {
        pub fn hash(fi: root.cache.FileItem) u64 {
            return std.hash_map.hashString(fi.relative_path);
        }
    }.hash,
);

const Self = @This();
aliases: std.StringHashMap(u64),

pub fn init(a: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error!Self {
    FileServerDirectory.init(a, path);
    var aliases = std.StringHashMap(u64).init(a);
    try aliases.put("/", std.hash_map.hashString("/index.html"));
    try aliases.put("404", std.hash_map.hashString("/404.html"));
    return .{
        .aliases = aliases,
    };
}

pub fn deinit(self: *Self) void {
    FileServerDirectory.deinit();
    self.aliases.deinit();
}

pub const ServeError = error{FileNotFound} || std.http.Server.Request.ExpectContinueError;

pub fn serve(self: Self, request: *std.http.Server.Request) ServeError!void {
    FileServerDirectory.tryUpdate() catch |e| log.err("Failed to update file server directory: {any}\n", .{e});
    const path = request.head.target;
    const file, const status: std.http.Status = b: {
        const key = if (self.aliases.get(path)) |alias_key|
            alias_key
        else
            std.hash_map.hashString(path);

        // this might be good to make configurable as well
        const key_404 = std.hash_map.hashString("/404.html");

        break :b .{
            FileServerDirectory.get().map.get(key) orelse {
                log.warn(
                    \\ File not found: '{s}'
                , .{path});
                break :b .{
                    FileServerDirectory.get().map.get(key_404) orelse
                        return error.FileNotFound,
                    .not_found,
                };
            },
            .ok,
        };
    };
    const content = file.content[0..file.content.len];

    return request.respond(content, .{
        .status = status,
        // .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "content-type", .value = @tagName(file.mime_type) },
        },
    });
}
