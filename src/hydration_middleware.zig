const root = @import("root.zig");
const std = @import("std");
const zemplate = @import("zemplate");
const ComponentsDirectory = @import("components.zig").ComponentsDirectory;

const log = std.log.scoped(.hydration_middleware);

const FullPageRefreshTemplate = zemplate.Template(struct { route_content: []const u8 });

pub const Context = struct {
    index_file_content: []u8,

    pub fn init(a: std.mem.Allocator, index_file_content: []const u8) std.mem.Allocator.Error!@This() {
        ComponentsDirectory.init(a);
        return .{
            .index_file_content = try a.dupe(u8, index_file_content),
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

        var tmpl = FullPageRefreshTemplate.init(.{ .route_content = writer.buffer[0..writer.end] });
        const render = try tmpl.render(a, ctx.index_file_content, .{});
        _ = writer.consumeAll();
        try writer.writeAll(render);
    }

    const hydration_html = blk: {
        var component_buffer = std.ArrayList(u8).initCapacity(a, 1024) catch @panic("out of memory");
        component_buffer.appendSlice(a, std.fmt.allocPrint(a,
            \\  <section id="components-cache" hx-swap-oob="{s}">
        , .{oob_swap}) catch @panic("out of memory")) catch @panic("out of memory");

        ComponentsDirectory.tryUpdate() catch |e| log.err("Failed to update components directory: {any}\n", .{e});
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
            const needle =
                try std.fmt.allocPrint(a, "<{s}", .{comp.name});
            if (std.mem.indexOf(u8, writer.buffer, needle) != null) {
                log.debug("including {s}\n", .{comp.name});
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
