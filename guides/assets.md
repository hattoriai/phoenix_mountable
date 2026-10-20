# Assets

A mountable library picks how its CSS and JavaScript reach the browser
with the `:assets` option. Each strategy describes *entries* (a name, a
URL and a kind) that `PhoenixMountable.Layout.assets/1` renders with the
request's CSP nonces and `phx-track-static`.

## Embedded

```elixir
assets:
  {PhoenixMountable.Assets.Embedded,
   css: "priv/static/app.css",
   js: "priv/static/app.js",
   prepend: [:phoenix, :phoenix_html, :phoenix_live_view, :phoenix_mountable]}
```

The approach of LiveDashboard, Oban Web and Lotus Web. The files are read,
concatenated and gzipped when the library compiles, and served from
memory at `<mount>/css-<md5>` and `<mount>/js-<md5>`. The host needs no
Node.js and no `Plug.Static` entry.

* Responses are cached for a year as immutable; a hash this build did
  not produce answers 404 with `no-store`.
* `:prepend` puts Phoenix's, LiveView's and PhoenixMountable's browser
  scripts before the library's bundle, so it can use the `Phoenix`,
  `LiveView` and `PhoenixMountable` globals.
* The JavaScript response opts out of the CSRF check for cross-origin
  scripts, since the bundle is public.

Build the files before publishing the package, and list them in the
package's `files`.

## Static

```elixir
assets:
  {PhoenixMountable.Assets.Static,
   from: "priv/static/my_lib",
   manifest: ".vite/manifest.json",
   entries: [app: {"src/main.tsx", :module}]}
```

A directory of files built by Vite, esbuild or another bundler, served
under `<mount>/assets` with `Plug.Static` (gzip and brotli variants
included). With a Vite manifest, entries are its keys and their CSS
files become entries too (`:app_css`); without one, entries are file
names and their URLs carry `?vsn=<md5>`.

This is how a library brings a React or Vue frontend: a controller (or
a LiveView) renders the shell with `PhoenixMountable.Layout.assets/1`,
and the library's API is a `forward` of its routes.

## Host

```elixir
layout: :host,
assets: {PhoenixMountable.Assets.Host, []}
```

The library's templates are styled by the host's Tailwind, and render
inside the host's layout. The host tells Tailwind to scan the library:

* Tailwind v4 (Phoenix 1.8), in `assets/css/app.css`:

  ```css
  @source "../../deps/my_lib";
  ```

* Tailwind v3 (Phoenix 1.7), in `assets/tailwind.config.js`:

  ```js
  content: ["../deps/my_lib/**/*.*ex", ...]
  ```

`PhoenixMountable.Igniter.add_tailwind_source/2` adds the right line.

## Layouts

```elixir
<head>
  <PhoenixMountable.Layout.meta mount={@mount} />
  <PhoenixMountable.Layout.assets mount={@mount} />
</head>
```

`meta/1` renders the CSRF token, the LiveView socket path and transport,
and the mount path. The browser helper reads them:

```js
// with the embedded bundle and `prepend: [..., :phoenix_mountable]`
const liveSocket = PhoenixMountable.connect({hooks: MyHooks})

// with a bundler: import {connect} from "phoenix_mountable"
connect({Phoenix: {Socket, LongPoll}, LiveView: {LiveSocket}, hooks})

PhoenixMountable.path("/items/1") //=> "/admin/my_lib/items/1"
```

## Deploys

A tab left open across a deploy reconnects to the new server with the
old bundle. Phoenix's `static_changed?/1` only knows the host's
manifest, so PhoenixMountable checks the library's own entries when a
library LiveView connects, and reloads the page when they belong to a
previous build. `reload_on_stale: false` turns it off.

## CDNs

A host serves a library's assets from a CDN with `asset_host:`:

```elixir
my_lib "/my_lib", asset_host: "https://cdn.example.com"
```
