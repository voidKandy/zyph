# zyph
`zyph` is a library for building SSR, vanilla first, hypermedia-oriented web applications. `zyph` is highly opinionated, if you need more flexibility, I would recommend [zap](https://github.com/zigzap/zap). 

### Why use zyph?
+ The needs of your website are fairly simple and can be easily modeled with hypermedia
+ You want to write zig
+ You want a small, fast server

### Why not use zyph?
+ Your website is highly reactive and cannot be easily modeled with hypermedia (for example, a spreadsheet application)

### Features:
+ File server
+ Hot reloading components
+ Opt-in TLS support
+ Opt-in web-components management system
+ Middleware
+ Differientiation of Data and Hypermedia [Apis](https://htmx.org/essays/hypermedia-apis-vs-data-apis/)

### In the works
- [ ] Hot reloading pages
- [x] Hot reloading File Server
- [ ] Utilizing caching for optimization


### Running Examples
All binaries in the `examples` file can be run with the command `zig build <name-of-example-file>` for example, `examples/hello_world.zig` can be run with `zig build hello_world`.


## Usage
`zyph` is best used with [HTMX](https://htmx.org/).

##### **Server Creation**
Initializing a server requires an allocator and the directory you want to serve static files out of. Note that `.iterate` must be set to `true`. If you do not wish to serve static files, it is fine to pass `null` as the second argument.
```zig
var server = zyph.Server.init(allocator, try cwd.openDir("serve", .{ .iterate = true }));
defer server.deinit();
```
##### **Registering Routes**
`Server` has two methods for registering routes:
+ `registerHypermediaEndpoint`
+ `registerDataEndpoint`

Each are handled slightly differently on the server.
The context types of the following examples can be any arbtrary type, as long as it's type matches the first argument in the function passed.
```zig
const hypermedia_route_ctx: @TypeOf(.{}) = .{};
var route_handle = try server.registerHypermediaEndpoint("/", &hypermedia_route_ctx, &struct {
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
}.handler);
```
```zig
const data_route_ctx: @TypeOf(.{}) = .{};
var route_handle = try server.registerDataEndpoint("/", &data_route_ctx, &struct {
    fn handler(
        _: *@TypeOf(.{}),
        r: *std.http.Server.Request,
    ) anyerror!void {
        try r.respond("{'data': 'somedata'}", .{});
    }
}.handler);
```
##### **Middleware**
There are two kinds of middleware:
+ `pre` handler - called before the handler function is called
+ `post` handler - called after the handler function is called

An example of a `pre` middleware would be some _auth_ middleware; you want it before the handler in case you need to return `Unauthorized`. 

An example of a `post` middleware would be the hydration middleware `zyph` provides. It needs to be called _after_ the handler because it needs to introspect into what the handler wrote to the writer.

Before it can be associated with a route, middleware must be initialized and registered in the `Server`, it's very similar to how routes are created:
```zig
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
```
Once middleware has been registered on the server, adding middleware to a route is simple, given that `route_handle` was returned by the `register` function:
```zig
try route_handle.addMiddlwares(.pre, &.{"some_pre_middleware", "another_pre_middleware"});
try route_handle.addMiddlwares(.post, &.{"some_post_middleware", "another_post_middleware"});
```
Middlewares will be executed in the order they are passed in this function.

## zyph's hydration middleware
`zyph` provides a hydration middleware that hydrates the client with whichever web components they need. Wherever you create your server and register your routes, call:
```zig
var hydration_context = try zyph.hydration_middleware.Context.init(allocator, try std.fs.cwd().openFile("path/to/index.html", .{}));
defer hydration_context.deinit(allocator);
try server.middlewares.put(
    zyph.hydration_middleware.NAME,
    zyph.Middleware.init(.post, &hydration_context, &zyph.hydration_middleware.handler),
);

// call on each route you need hydrated
route.addMiddlwares(.post, &.{zyph.hydration_middleware.NAME});
```

In order for hydration to work, your `index.html` file *must* have this script **in** the `body` tag:
```html
<script>
  document.body.addEventListener("htmx:beforeRequest", (event) => {
    const children = document.querySelector("#components-cache").children;
    const set = new Set();
    for (const el of children) {
      if (el instanceof HTMLScriptElement) {
        continue;
      }
      const cleanName = el.id.replace(/-template$/, "");
      if (cleanName.trim().length > 0) {
        set.add(cleanName);
      }
    }
    event.detail.xhr.setRequestHeader("x-hydrated", JSON.stringify([...set]))
  });
</script>
```
Now you should be able to define components in your `components` directory and *just use them* in your clientside code. The server will know which ones to send to the client per request.
