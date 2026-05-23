const std = @import("std");
const log = std.log.scoped(.components);
const root = @import("root.zig");

pub const ComponentsDirectory = root.cache.CachedDirectory(
    &struct {
        pub fn hash(fi: root.cache.FileItem) u64 {
            var buf: [1024]u8 = undefined;
            const name = componentName(fi.full_path, &buf) catch @panic("failed to create component name");
            return std.hash_map.hashString(name);
        }
    }.hash,
);

const Request = std.http.Server.Request;

pub fn componentName(full_path: []const u8, buf: []u8) anyerror![]u8 {
    const ext = std.fs.path.extension(full_path);
    if (!std.mem.eql(u8, ext, ".html")) return error.NotHTML;

    var split = std.mem.splitBackwardsScalar(u8, full_path, '.');
    _ = split.first();
    const filename = split.next() orelse return error.InvalidFilename;

    var i: usize = 0;
    for (filename) |ch| {
        if (i >= buf.len) return error.BufferTooSmall;
        if (std.ascii.isUpper(ch)) {
            buf[i] = '-';
            i += 1;
            if (i >= buf.len) return error.BufferTooSmall;
            buf[i] = std.ascii.toLower(ch);
        } else {
            buf[i] = ch;
        }
        i += 1;
    }
    return buf[0..i];
}
pub const ComponentInfo = struct {
    name: []u8,

    fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }

    pub fn fromFile(file: root.cache.FileItem, allocator: std.mem.Allocator) anyerror!@This() {
        const ext = std.fs.path.extension(file.full_path);

        if (!std.mem.eql(u8, ext, "html")) {
            return error.NotHTML;
        }

        var split = std.mem.splitBackwardsScalar(u8, file.full_path, '.');
        _ = split.first();
        const filename = split.next() orelse return error.InvalidFilename;

        var uppercase_idcs: []usize = try allocator.alloc(usize, filename.len);
        var len: usize = 0;
        for (filename, 0..) |ch, i| {
            if (std.ascii.isUpper(ch)) {
                uppercase_idcs[len] = i;
                len += 1;
            }
        }
        const component_name: []u8 = try allocator.alloc(u8, filename.len + len);

        var i: usize = 0;
        for (filename) |ch| {
            if (std.ascii.isUpper(ch)) {
                component_name[i] = '-';
                i += 1;
                component_name[i] = std.ascii.toLower(ch);
            } else {
                component_name[i] = ch;
            }
            i += 1;
        }

        return @This(){
            .name = component_name,
        };
    }
};
