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
+ Bespoke web-components management system
+ Differientiation of Data and Hypermedia [Apis](https://htmx.org/essays/hypermedia-apis-vs-data-apis/)

### In the works
- [ ] Hot reloading pages
- [ ] Hot reloading File Server
- [ ] Middleware
- [ ] Utilizing caching for optimization


### Running Examples
All binaries in the `examples` file can be run with the command `zig build <name-of-example-file>` for example, `examples/hello_world.zig` can be run with `zig build hello_world`.


## Usage
`zyph` is best used with [HTMX](https://htmx.org/).
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
