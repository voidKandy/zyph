const root = @import("root.zig");
const std = @import("std");
const zemplate = @import("zemplate");
const ComponentsDirectory = @import("components.zig").ComponentsDirectory;

const log = std.log.scoped(.hydration_middleware);

const FullPageRefresh = struct { route_content: []const u8 };

pub const NAME = "hydration";
pub const Context = struct {
    index_file_content: []u8,

    pub fn init(a: std.mem.Allocator, components_dir_path: []const u8, index_file: std.fs.File) std.mem.Allocator.Error!@This() {
        ComponentsDirectory.init(a, components_dir_path);

        var reader_buffer: [1024 * 64]u8 = undefined;
        var reader = index_file.reader(&reader_buffer);
        var dest_buffer: [1024 * 64]u8 = undefined;
        var amt_read: usize = 0;
        while (true) {
            const amt = reader.readPositional(&dest_buffer) catch |e| if (e == error.EndOfStream) break else @panic("failed to read index file");
            amt_read += amt;
            if (amt <= 0) break;
        }
        const index_file_content = a.dupe(u8, dest_buffer[0..amt_read]) catch @panic("out of memory");

        return .{
            .index_file_content = index_file_content,
        };
    }
    pub fn deinit(self: *@This(), a: std.mem.Allocator) void {
        ComponentsDirectory.deinit();
        a.free(self.index_file_content);
    }
};

pub fn handler(ctx: *Context, a: std.mem.Allocator, r: *std.http.Server.Request, writer: *std.Io.Writer) anyerror!void {
    const is_htmx_request = root.getHeader(r.*, "hx-request") != null;
    const hydrated_info = root.getHeader(r.*, "x-hydrated");

    log.debug(
        \\ is htmx: {any}
        \\ info: {s}
    , .{ is_htmx_request, hydrated_info orelse "None" });
    const oob_swap = if (hydrated_info == null) "innerHTML" else "beforeend";
    if (!is_htmx_request) {
        log.debug(
            \\ requires full page refresh
        , .{});

        var tmpl = try zemplate.Template(FullPageRefresh).init(
            a,
            .{ .route_content = writer.buffer[0..writer.end] },
        );
        defer tmpl.deinit();
        const render = try tmpl.render(
            ctx.index_file_content,
            .{},
        );

        _ = writer.consumeAll();
        try writer.writeAll(render);
    }

    const hydration_html = blk: {
        var component_buffer = std.ArrayList(u8).initCapacity(a, 1024) catch @panic("out of memory");
        component_buffer.appendSlice(a, std.fmt.allocPrint(a,
            \\  <section id="components-cache" hx-swap-oob="{s}">
        , .{oob_swap}) catch @panic("out of memory")) catch @panic("out of memory");

        ComponentsDirectory.tryUpdate() catch |e| log.err("Failed to update components directory: {any}\n", .{e});
        // BAD? Map is cloned, Is this necessary?
        var map = try ComponentsDirectory.get().map.clone();

        if (hydrated_info) |header| {
            var header_elems = std.mem.splitScalar(u8, std.mem.trim(u8, header, "\n []"), ',');
            while (header_elems.next()) |elem_name| {
                const sanitized = std.mem.trim(u8, elem_name, "\n \"");
                if (sanitized.len == 0) continue;
                const hash = std.hash_map.hashString(sanitized);
                log.debug("removing {s} : {d}\n", .{ sanitized, hash });
                const removed = map.remove(std.hash_map.hashString(sanitized));
                if (!removed)
                    log.warn("failed to remove {s}\n", .{sanitized});
            }
        }

        var needed_iter = map.valueIterator();
        var included_counter: usize = 0;
        while (needed_iter.next()) |comp| {
            var buf: [1024]u8 = undefined;
            const name = @import("components.zig").componentName(comp.relative_path, &buf) catch @panic("failed to create component name");
            const needle = try std.fmt.allocPrint(a, "<{s}", .{name});
            if (std.mem.indexOf(u8, writer.buffer, needle) != null) {
                log.debug("including {s}\n", .{name});
                try component_buffer.appendSlice(a, comp.content);
                included_counter += 1;
            }
        }

        if (included_counter == 0) {
            component_buffer.deinit(a);
            break :blk "";
        }
        component_buffer.appendSlice(a,
            \\  </section>
        ) catch @panic("out of memory");
        break :blk try component_buffer.toOwnedSlice(a);
    };

    try writer.writeAll(hydration_html);
}
