const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
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
    embedPages(b, mod) catch @panic("failed to embed pages");

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

const PAGES_DIRECTORY = "pages";
pub fn embedPages(b: *std.Build, mod: *std.Build.Module) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cwd = std.fs.cwd();
    var dir = try cwd.openDir(PAGES_DIRECTORY, .{ .iterate = true });
    var it = dir.iterate();

    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (entry.name[0] == '.') continue;
        mod.addAnonymousImport(entry.name, .{ .root_source_file = b.path(try std.fmt.allocPrint(arena, "{s}/{s}", .{ PAGES_DIRECTORY, entry.name })) });
    }
}
