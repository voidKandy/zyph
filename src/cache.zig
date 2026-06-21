const std = @import("std");
const log = std.log.scoped(.cache);
const root = @import("root.zig");
const mime = @import("mime");

inline fn functionsMatch(comptime name: []const u8, comptime func: std.builtin.Type.Fn, comptime other: std.builtin.Type.Fn) void {
    const params = other.params;
    const expected_params = func.params;
    std.debug.assert(params.len == expected_params.len);
    inline for (0..params.len) |i| {
        if (expected_params[i].type.? == *anyopaque) continue;
        if (params[i].type.? != expected_params[i].type.?) @compileError(
            "function '" ++ name ++ "' has invalid parameter type: " ++ @typeName(params[i].type.?) ++ " expected: " ++ @typeName(expected_params[i].type.?),
        );
    }

    const i = @typeInfo(func.return_type orelse return false);
    switch (i) {
        .error_union => |u| {
            const f_set = u.error_set;
            const f_payload = u.payload;
            const o_union = @typeInfo(other.return_type orelse return false).error_union;
            const o_set = o_union.error_set;
            const o_payload = o_union.payload;
            if (f_set != o_set or (f_payload != o_payload and f_payload != *anyopaque))
                @compileError("Expected " ++ name ++ "'s return type to be " ++ @typeName(@TypeOf(i)) ++ " Found " ++
                    @typeName(other.return_type.?));
        },
        else => {
            const o_ret = @typeInfo(other.return_type orelse return false);
            if (@TypeOf(o_ret) != @TypeOf(i))
                @compileError("Expected " ++ name ++ "'s return type to be " ++ @typeName(@TypeOf(i)) ++ " Found " ++
                    @typeName(@TypeOf(o_ret)));
        },
    }
}

pub const FileItem = struct {
    last_modified: i96,
    full_path: []u8,
    relative_path: []u8,
    content: []u8,
    mime_type: mime.Type,
};

pub fn CachedDirectory(
    hashFunc: *const fn (FileItem) u64,
) type {
    return struct {
        allocator: std.mem.Allocator,
        map: std.AutoHashMap(u64, FileItem),
        mrc: std.atomic.Value(u64),
        should_update: std.atomic.Value(bool),
        path: []const u8,

        var singleton: ?@This() = null;
        var default_required_keys: std.AutoHashMap(u64, void) = undefined;

        pub fn init(a: std.mem.Allocator, io: std.Io, path: []const u8) void {
            if (singleton == null) {
                singleton = .{
                    .allocator = a,
                    .map = readFiles(a, io, path) catch @panic("failed to init singleton"),
                    .mrc = std.atomic.Value(u64).init(root.computeFolderMRC(io, path) catch @panic("failed to get mrc")),
                    .should_update = std.atomic.Value(bool).init(false),
                    .path = path,
                };

                const thread = std.Thread.spawn(.{}, backgroundWatcher, .{
                    io,
                    &singleton.?.mrc,
                    &singleton.?.should_update,
                    singleton.?.path,
                }) catch @panic("failed to spawn watcher thread");
                thread.detach();
            } else {
                log.warn(
                    \\ Tried to initialize {s} more than once!
                , .{@typeName(@This())});
            }
        }

        pub fn deinit() void {
            singleton.?.map.deinit();
        }

        /// Background thread function
        fn backgroundWatcher(io: std.Io, mrc_ptr: *std.atomic.Value(u64), update_ptr: *std.atomic.Value(bool), path: []const u8) void {
            while (true) {
                io.sleep(.fromSeconds(5), .real) catch @panic("Panicked while trying to sleep");
                // std.Thread.sleep(5_000_000_000); // sleep 5 seconds (nano)
                const new_mrc = root.computeFolderMRC(io, path) catch continue;
                if (new_mrc > mrc_ptr.load(.seq_cst)) {
                    mrc_ptr.store(new_mrc, .seq_cst);
                    update_ptr.store(true, .seq_cst);
                }
            }
        }

        pub fn get() @This() {
            return singleton orelse @panic("Tried to access unitialized ComponentsDirectory");
        }

        pub fn tryUpdate(io: std.Io) !void {
            if (singleton.?.should_update.swap(false, .seq_cst)) {
                singleton.?.map = readFiles(singleton.?.allocator, io, singleton.?.path) catch return error.UpdateFailed;
            }
        }

        fn readFilesIntoMap(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, map: *std.AutoHashMap(u64, FileItem), parent_relative: []const u8) !void {
            var iter = dir.iterate();
            while (try iter.next(io)) |e| {
                if (e.name[0] == '.') continue;
                switch (e.kind) {
                    .directory => {
                        var subdir = try dir.openDir(io, e.name, .{ .iterate = true });
                        defer subdir.close(io);
                        const subdir_relative = try std.fmt.allocPrint(a, "{s}/{s}", .{ parent_relative, e.name });
                        defer a.free(subdir_relative);
                        try readFilesIntoMap(a, io, subdir, map, subdir_relative);
                    },
                    .file => {
                        log.debug(
                            \\ hashing '{s}'
                        , .{e.name});
                        const file = try dir.openFile(io, e.name, .{});
                        defer file.close(io);
                        const fullpath = try dir.realPathFileAlloc(io, e.name, a);
                        // const fullpath = try dir.realpathAlloc(a, e.name);
                        const stat = try file.stat(io);
                        var file_reader = file.reader(io, &.{});
                        const content = try file_reader.interface.allocRemaining(a, .unlimited);

                        const ext = std.fs.path.extension(e.name);
                        const relative_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ parent_relative, e.name });
                        const file_item = FileItem{
                            .mime_type = mime.extension_map.get(ext) orelse .@"application/octet-stream",
                            .content = content,
                            .full_path = fullpath,
                            .last_modified = stat.mtime.nanoseconds,
                            .relative_path = relative_path,
                        };
                        const hash = hashFunc(file_item);
                        try map.put(hash, file_item);
                    },
                    else => continue,
                }
            }
        }

        fn readFiles(a: std.mem.Allocator, io: std.Io, parent_path: []const u8) !std.AutoHashMap(u64, FileItem) {
            const cwd = std.Io.Dir.cwd();
            var dir = try cwd.openDir(io, parent_path, .{ .iterate = true });
            defer dir.close(io);
            var map = std.AutoHashMap(u64, FileItem).init(a);
            try readFilesIntoMap(a, io, dir, &map, "");
            return map;
        }
    };
}
