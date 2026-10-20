# PhoenixMountable

![PhoenixMountable — Mountable libraries for Phoenix](https://raw.githubusercontent.com/hattoriai/phoenix_mountable/main/media/banner.png)

PhoenixMountable is for building libraries that mount into a Phoenix
app, the way Phoenix LiveDashboard, Oban Web and Lotus Web do. A host app
adds one line to its router:

```elixir
import MyLib.Router

scope "/" do
  pipe_through :browser
  my_lib "/my_lib", resolver: MyApp.MyLibResolver
end
```

and gets the library's pages, controllers, assets, processes and
tables. It gives your library:

* a mount macro, generated from a definition module, that inserts
  ordinary Phoenix routes and live sessions into the host router:
  `mix phx.routes` lists them, the host's scopes and pipelines apply,
  LiveView navigation works between them;
* options for that macro, validated when the host compiles, with checks
  that run after the host router compiles (a resolver module that does
  not exist fails the build, not the first request);
* the mount (`@mount`, `conn.assigns.mount`): the path, the options and
  the request's CSP nonces, wherever the library's code runs, so a
  library can be mounted twice with different options;
* assets that reach the browser your way: bundles embedded at compile
  time under content-hashed URLs, a directory of built files (Vite,
  esbuild, React), or the host's own Tailwind and JavaScript; pages that
  reload after a deploy instead of running old JavaScript;
* `~m"/items/#{item}"`, paths relative to the mount, checked against the
  library's routes after compilation;
* processes per mount: started on first use or at boot, isolated per
  mount, with PubSub topics of their own, a cluster singleton and
  telemetry;
* versioned migrations for the library's tables in the host's database,
  on PostgreSQL, MySQL and SQLite: one pinned line per upgrade in the
  host, install options, adoption of installs made before, safe rolling
  deploys, concurrent index builds, batched backfills, and a check that
  tells the host the command to run;
* an installer in one `use` (`PhoenixMountable.Install`, on Igniter),
  Mix tasks, and a test kit: a host app for the library's tests, and
  checks of its migrations against a real database.

LiveView is optional: a library of controllers, a JSON API or a single
page app mounts the same way. The migrations and processes work without
Phoenix at all, so a library split in two packages, like `lotus` and
`lotus_web`, uses them in its core and the mounting in its web package.

## Installation

```elixir
def deps do
  [
    {:phoenix_mountable, "~> 0.2"}
  ]
end
```

PhoenixMountable needs Elixir 1.18 or later, Phoenix 1.7 or later and,
for live routes, Phoenix LiveView 1.1 or later.

## A mountable library

The definition module declares everything a host gets:

```elixir
defmodule MyLib.Router do
  use PhoenixMountable,
    otp_app: :my_lib,
    macro: :my_lib,
    layout: {MyLib.Layouts, :root},
    on_mount: [MyLib.Locale],
    schema: MyLib.Migrations,
    assets:
      {PhoenixMountable.Assets.Embedded,
       css: "priv/static/app.css",
       js: "priv/static/app.js",
       prepend: [:phoenix, :phoenix_html, :phoenix_live_view, :phoenix_mountable]}

  options resolver: [
            type: :atom,
            default: MyLib.Resolver,
            verify: {:behaviour, MyLib.Resolver},
            doc: "Resolves the current user and what they may do."
          ],
          features: [type: {:list, :atom}, default: []]

  routes do
    get "/export", MyLib.ExportController, :csv, as: :export

    live_session :public, host_on_mount: false do
      live "/share/:token", MyLib.ShareLive, :show
    end

    live_session :default, on_mount: [MyLib.Auth] do
      live "/", MyLib.HomeLive, :index
      live "/items/:id", MyLib.ItemLive, :show
    end
  end

  @impl PhoenixMountable
  def session(conn, mount, _session) do
    %{"user" => mount.options.resolver.resolve_user(conn)}
  end

  @impl PhoenixMountable
  def children(mount) do
    [{MyLib.Cache, name: PhoenixMountable.via(mount, :cache)}]
  end

  @impl PhoenixMountable
  def repo(_mount), do: Application.fetch_env!(:my_lib, :repo)
end
```

A host mounts it with `my_lib "/my_lib"`. Every mount macro also takes
`:as` (to mount the library twice), `:on_mount`, `:socket_path`,
`:transport`, `:csp_nonce_assign_key`, `:asset_host` and `:pubsub`.

In the library's LiveViews and templates:

```elixir
use PhoenixMountable.Path, mountable: MyLib.Router

~H"""
<.link navigate={~m"/items/#{@item}"}>{@item.name}</.link>
<p>Mounted at {@mount.path}, with {inspect(@mount.options.features)}</p>
"""
```

## Guides

* [Building a mountable library](guides/building-a-mountable-library.md)
* [Assets](guides/assets.md)
* [Migrations](guides/migrations.md)
* [Processes](guides/processes.md)
* [Installers](guides/installers.md)
* [Testing](guides/testing.md)

## How it compares

| | PhoenixMountable | A router macro by hand (LiveDashboard, Oban Web) | Rails engines |
| --- | --- | --- | --- |
| Routes in the host | ordinary Phoenix routes, generated | written by hand per library | a mounted Rack app |
| Options | validated at compile time, documented from their schema | validated by hand | |
| Assets | embedded, static or the host's, with deploy reloads | embedded, by hand | the asset pipeline |
| Processes | per mount, lazy or at boot, singletons | | |
| Migrations | versioned, tracked per prefix on three databases, with backfills and checks | Oban: by hand, Postgres comments | copied into the app |

## Contributing

See [CONTRIBUTING.md](https://github.com/hattoriai/phoenix_mountable/blob/main/CONTRIBUTING.md): when a change needs an issue
first, what a pull request needs, and how to run the checks. Report a
security problem privately, as [SECURITY.md](https://github.com/hattoriai/phoenix_mountable/blob/main/SECURITY.md) says.

## License

MIT. See [LICENSE](https://github.com/hattoriai/phoenix_mountable/blob/main/LICENSE).
