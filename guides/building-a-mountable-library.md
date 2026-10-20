# Building a mountable library

A mountable library is a package a Phoenix app mounts with one line in
its router. This guide builds one from the definition module up.

## Vocabulary

| Term | Meaning |
| --- | --- |
| host app | the Phoenix app that mounts the library |
| mountable library | a library built with PhoenixMountable |
| definition module | the library module that calls `use PhoenixMountable` |
| mount macro | the router macro generated for hosts, such as `my_lib/2` |
| mount path | the path given to the mount macro, such as `"/my_lib"` |
| mount | one mounted instance: a path and its options |

## The definition module

```elixir
defmodule MyLib.Router do
  use PhoenixMountable,
    otp_app: :my_lib,
    macro: :my_lib,
    layout: {MyLib.Layouts, :root}

  options resolver: [type: :atom, default: MyLib.Resolver, verify: {:behaviour, MyLib.Resolver}]

  routes do
    live "/", MyLib.HomeLive, :index
  end
end
```

Naming it `MyLib.Router` lets hosts write `import MyLib.Router` and
`my_lib "/my_lib"`, like `import Phoenix.LiveDashboard.Router` and
`live_dashboard "/dashboard"`.

The `use` options are documented in `PhoenixMountable`. The ones that
shape the library:

* `:layout`: `{module, function}` for a document of the library's own
  (its own CSS and JavaScript, like LiveDashboard), or `:host` to render
  inside the host's root layout (the host's Tailwind and JavaScript).
  `{PhoenixMountable.Layout, :root}` is a ready-made document.
* `:assets`: how the library's files reach the browser. See the
  [Assets guide](assets.md).
* `:on_mount`: hooks run in every live session of the library, after the
  host's hooks.
* `:schema`: the library's migrations, checked on first use. See the
  [Migrations guide](migrations.md).

## Options

`options/1` takes a [NimbleOptions](https://hexdocs.pm/nimble_options)
schema. A host's options are validated when its router compiles, and
the schema documents the mount macro (`h MyLib.Router.my_lib`).

```elixir
options resolver: [
          type: :atom,
          default: MyLib.Resolver,
          verify: {:behaviour, MyLib.Resolver},
          doc: "Resolves the current user."
        ],
        theme: [type: {:in, [:light, :dark]}],
        themes: [type: {:list, :atom}, default: [:light, :dark]]
```

`:verify` checks a module option after the host router compiles: it
exists (`:module`), and implements a behaviour (`{:behaviour, mod}`).
Checking it while the router compiles would deadlock when the module
uses the host's `~p`.

`normalize_options/1` derives and cross-checks options:

```elixir
@impl PhoenixMountable
def normalize_options(opts) do
  opts = Keyword.put_new(opts, :theme, hd(opts[:themes]))

  if opts[:theme] not in opts[:themes] do
    raise ArgumentError, "theme #{inspect(opts[:theme])} is not one of #{inspect(opts[:themes])}"
  end

  opts
end
```

Every mount macro also takes the built-in options: `:as`, `:on_mount`,
`:socket_path`, `:transport`, `:csp_nonce_assign_key`, `:asset_host`
and `:pubsub`.

## Routes

`routes/1` uses the macros of `PhoenixMountable.Routes`, which mirror
Phoenix's, with paths relative to the mount:

```elixir
pipeline :api do
  plug :accepts, ["json"]
end

routes do
  get "/export", MyLib.ExportController, :csv, as: :export
  forward "/webhooks", MyLib.Webhooks

  scope "/api" do
    pipe_through :api
    get "/items", MyLib.API.ItemController, :index
  end

  live_session :public, host_on_mount: false do
    live "/share/:token", MyLib.ShareLive, :show
  end

  live_session :default, on_mount: [MyLib.Auth] do
    live "/", MyLib.HomeLive, :index
    live "/items/:id", MyLib.ItemLive, :show
  end
end
```

The mount macro expands them into the host router, inside the host's
scope and pipelines. The routes are named after the mount: the host's
live sessions are `:my_lib` and `:my_lib_public`, and route helpers
`my_lib_path` and `my_lib_export_path`. A host mounting the library
twice passes `as:` to one of the mounts.

`host_on_mount: false` keeps the host's hooks out of a session, for
pages that must stay public when the host's hooks require a signed-in
user.

## The mount

In LiveViews and their templates, the mount is `@mount`; in controllers
and plugs of the library's routes, `conn.assigns.mount`; anywhere in the
process, `PhoenixMountable.Mount.current/0`.

```elixir
def mount(_params, _session, socket) do
  resolver = socket.assigns.mount.options.resolver
  ...
end
```

The session callback runs on the HTTP request, with the host's conn,
for values that need it, such as the current user:

```elixir
@impl PhoenixMountable
def session(conn, mount, _session_name) do
  %{"user" => mount.options.resolver.resolve_user(conn)}
end
```

## Paths

`~m` builds paths relative to the mount, and warns at compile time when
a path matches none of the library's routes:

```elixir
use PhoenixMountable.Path, mountable: MyLib.Router

push_navigate(socket, to: ~m"/items/#{item}")
~H|<.link navigate={~m"/items?#{[page: 2]}"}>Next</.link>|
```

## Without LiveView

A library without live routes needs only Phoenix. Its controllers
render in the library's root layout (or the host's, with
`layout: :host`), and `PhoenixMountable.HTML` renders the meta and asset
tags in EEx templates. A JSON API is a `forward` to a `Plug.Router` or
`Phoenix.Router` of the library's, and a single page app a controller
that renders its shell with the `PhoenixMountable.Assets.Static`
strategy.

## A core and a web package

A library whose functionality is useful without its pages (Oban and
Oban Web, Lotus and Lotus Web) splits in two packages. Both can depend on
PhoenixMountable: the core uses `PhoenixMountable.Migrations` and the
processes, which need no Phoenix, and the web package the definition
module. The web package's `:schema` option names the core's migrations
module.
