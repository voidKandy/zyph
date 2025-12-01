const std = @import("std");
const log = std.log.scoped(.cache);

pub fn CachedDirectory(comptime ItemType: type, dir_path: []const u8) type {
    comptime {
        if (!@hasDecl(ItemType, "fromFile"))
            @compileError("Expected ItemType to have a PUBLIC fromFile function");
        if (!@hasDecl(ItemType, "preImage"))
            @compileError("Expected ItemType to have a PUBLIC preImage function");

        const from_file_func = @typeInfo(@TypeOf(&ItemType.fromFile));
        const pre_image_func = @typeInfo(@TypeOf(&ItemType.preImage));

        const from_file = blk: {
            const inner = @typeInfo(from_file_func.pointer.child);
            if (inner == .@"fn") {
                break :blk inner.@"fn";
            } else {
                @compileError("fromFile is a declaration but is not a function, it is " ++ @typeName(@TypeOf(from_file_func)));
            }
        };

        if (from_file.params.len != 3)
            @compileError("Expected 3 function arguments, got " ++ from_file.params.len);

        {
            const arg_1_type = from_file.params[0].type.?;
            if (arg_1_type != std.fs.Dir)
                @compileError("Expected func's first argument to be of type Dir. Found " ++
                    @typeName(arg_1_type));

            const arg_2_type = from_file.params[1].type.?;
            if (arg_2_type != []const u8)
                @compileError("Expected func's first argument to be of type []const u8. Found " ++
                    @typeName(arg_2_type));

            const arg_3_type = from_file.params[2].type.?;
            if (arg_3_type != std.mem.Allocator)
                @compileError("Expected func's first argument to be of type Allocator. Found " ++
                    @typeName(arg_3_type));
        }

        const pre_image = blk: {
            const inner = @typeInfo(pre_image_func.pointer.child);
            if (inner == .@"fn") {
                break :blk inner.@"fn";
            } else {
                @compileError("fromFile is a declaration but is not a function, it is " ++ @typeName(@TypeOf(pre_image_func)));
            }
        };

        if (pre_image.params.len != 1)
            @compileError("Expected 1 function arguments, got " ++ pre_image.params.len);

        if (pre_image.params[0].type.? != ItemType) {
            @compileError("Expected func's only argument to be of type ItemType. Found " ++
                @typeName(pre_image.params[0].type.?));
        }

        if (pre_image.return_type != []const u8) {
            @compileError("Expected preImage's return type to be []const u8 Found " ++
                @typeName(pre_image.return_type.?));
        }

        if (!ret: {
            const ff_ret = @typeInfo(from_file.return_type orelse break :ret false);
            const set = ff_ret.error_union.error_set;
            const payload = ff_ret.error_union.payload;
            break :ret (payload == ItemType and set == anyerror);
        }) {
            @compileError("Expected fromFile's return type to be anyerror!ItemType. Found " ++
                @typeName(from_file.return_type.?));
        }
    }

    return struct {
        allocator: std.mem.Allocator,
        map: std.AutoHashMap(u64, ItemType),
        mrc: std.atomic.Value(u64),
        should_update: std.atomic.Value(bool),

        var singleton: ?@This() = null;
        var default_required_keys: std.AutoHashMap(u64, void) = undefined;

        pub fn init(a: std.mem.Allocator) void {
            if (singleton == null) {
                singleton = .{
                    .allocator = a,
                    .map = readFiles(a, dir_path) catch @panic("failed to init singleton"),
                    .mrc = std.atomic.Value(u64).init(computeMRC(dir_path) catch @panic("failed to get mrc")),
                    .should_update = std.atomic.Value(bool).init(false),
                };

                const thread = std.Thread.spawn(.{}, backgroundWatcher, .{
                    &singleton.?.mrc,
                    &singleton.?.should_update,
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
            // a.free(singleton.?.array);
        }

        /// Background thread function
        fn backgroundWatcher(mrc_ptr: *std.atomic.Value(u64), update_ptr: *std.atomic.Value(bool)) void {
            while (true) {
                std.Thread.sleep(5_000_000_000); // sleep 5 seconds (nano)
                const new_mrc = computeMRC(dir_path) catch continue;
                if (new_mrc > mrc_ptr.load(.seq_cst)) {
                    mrc_ptr.store(new_mrc, .seq_cst);
                    update_ptr.store(true, .seq_cst);
                }
            }
        }

        pub fn get() @This() {
            return singleton orelse @panic("Tried to access unitialized ComponentsDirectory");
        }

        pub fn tryUpdate() !void {
            if (singleton.?.should_update.swap(false, .seq_cst)) {
                singleton.?.map = readFiles(singleton.?.allocator, dir_path) catch return error.UpdateFailed;
            }
        }

        fn computeMRC(parent_path: []const u8) !u64 {
            const cwd = std.fs.cwd();
            var dir = try cwd.openDir(parent_path, .{ .iterate = true });

            var latest: u64 = 0;
            var it = dir.iterate();
            while (try it.next()) |entry| {
                if (entry.kind != .file) continue;
                const stat = try dir.statFile(entry.name);
                const modified = @as(u64, @intCast(stat.mtime));
                if (modified > latest) latest = modified;
            }
            return latest;
        }

        fn readFiles(a: std.mem.Allocator, parent_path: []const u8) !std.AutoHashMap(u64, ItemType) {
            log.info("reading cached files\n", .{});
            const cwd = std.fs.cwd();
            var dir = try cwd.openDir(parent_path, .{ .iterate = true });
            var iter = dir.iterate();
            var map = std.AutoHashMap(u64, ItemType).init(a);

            var i: usize = 0;
            while (try iter.next()) |f| : (i += 1) {
                if (f.kind != .file) continue;
                if (f.name[0] == '.') continue;

                const this = try ItemType.fromFile(dir, f.name, a);
                const hash = std.hash_map.hashString(this.preImage());

                try map.put(hash, this);
            }

            return map;
        }
    };
}
