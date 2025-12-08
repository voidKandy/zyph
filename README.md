# zyph
`zyph` is a library for building SSR, vanilla first, hypermedia-oriented web applications. `zyph` is highly opinionated, if you need more flexibility, I would recommend [zap](https://github.com/zigzap/zap). 

### Why use zyph?
+ The needs of your website are fairly simple and can be easily modeled with hypermedia
+ You want to write zig
+ You want to try out a new way of thinking about how to model a server
+ You want a small, fast server

### Why not use zyph?
+ Your website is highly reactive and cannot be easily modeled with hypermedia (for example, a spreadsheet application)

### Features:
+ File server
+ Opt-in TLS support
+ Bespoke web-components management system
+ Differientiation of Data and Hypermedia [Apis](https://htmx.org/essays/hypermedia-apis-vs-data-apis/)

### In the works
- [ ] Middleware
- [ ] Utilizing caching for optimization


### Running Examples
All binaries in the `examples` file can be run with the command `zig build <name-of-example-file>` for example, `examples/hello_world.zig` can be run with `zig build hello_world`.
