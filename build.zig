const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    var threaded: std.Io.Threaded = .init(b.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const mime = b.dependency("mime", .{});
    const tls = b.dependency("tls", .{});
    const zemplate = b.dependency("zemplate", .{});

    const mod = b.addModule("zyph", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    mod.addImport("mime", mime.module("mime"));
    mod.addImport("tls", tls.module("tls"));
    mod.addImport("zemplate", zemplate.module("zemplate"));

    buildExamples(b, io, target, optimize, mod) catch |e| {
        std.log.err("Failed to build examples: {any}", .{e});
    };

    const lib_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/all.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    lib_unit_tests.root_module.addImport("zyph", mod);

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    // test_step.dependOn(&zemplate.step);
    test_step.dependOn(&run_lib_unit_tests.step);
}

fn buildExamples(b: *std.Build, io: std.Io, target: std.Build.ResolvedTarget, opt: std.builtin.OptimizeMode, core_lib: *std.Build.Module) anyerror!void {
    const examples_dir = "examples";
    const dir = std.Io.Dir.cwd().openDir(io, examples_dir, .{}) catch |e| {
        std.log.err("Failed to get examples: {s}\nError: {any}", .{ examples_dir, e });
        return e;
    };
    var buffer: [256]u8 = undefined;
    @memset(&buffer, 0);
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var iter = dir.iterate();
    while (iter.next(io) catch |e| {
        std.log.err("Dir iterator failure: {}\n", .{e});
        return e;
    }) |f| {
        const name = name: {
            var split = std.mem.splitBackwardsScalar(u8, f.name, '.');
            _ = split.first();
            break :name split.next() orelse @panic("malformed bin file name");
        };

        const fullpath = std.fmt.allocPrint(fba.allocator(), "{s}/{s}", .{ examples_dir, f.name }) catch |e| std.debug.panic("Failed to get full path: {}\n", .{e});
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(fullpath),
                .target = target,
                .optimize = opt,
            }),
        });

        exe.root_module.addImport("core", core_lib);

        // b.installArtifact(exe);
        const run = b.addRunArtifact(exe);
        const step = b.step(name, f.name);
        step.dependOn(&run.step);

        if (b.args) |args| {
            run.addArgs(args);
        }
    }
}
