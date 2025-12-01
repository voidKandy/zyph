const std = @import("std");
const log = std.log.scoped(.components);
/// For now, this is not configurable but I think the user should eventually be able to declare their own components directory
pub const ComponentsDirectory = @import("cache.zig").CachedDirectory(ComponentInfo, "components");

const Request = std.http.Server.Request;

pub const ComponentInfo = struct {
    /// Filepath
    path: []u8,
    content: []u8,
    /// Actual name of the HTML component
    name: []u8,
    last_modified: i128,

    fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.content);
        allocator.free(self.path);
    }

    pub fn preImage(self: @This()) []const u8 {
        return self.name;
    }

    pub fn fromFile(dir: std.fs.Dir, path: []const u8, allocator: std.mem.Allocator) anyerror!@This() {
        var split = std.mem.splitBackwardsScalar(u8, path, '.');

        if (!std.mem.eql(u8, split.first(), "html")) {
            return error.NotHTML;
        }
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

        const file = try dir.openFile(path, .{});
        const fullpath = try dir.realpathAlloc(allocator, path);
        const last_modified = (try file.stat()).mtime;
        defer file.close();
        const content = try file.readToEndAlloc(allocator, 8092);

        return @This(){
            .path = fullpath,
            .name = component_name,
            .content = content,
            .last_modified = last_modified,
        };
    }
};
