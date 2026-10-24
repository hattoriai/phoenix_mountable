# Installers

A host installs a mountable library with one command:

```sh
mix igniter.install my_lib
```

[Igniter](https://hexdocs.pm/igniter) adds the dependency, then runs the
library's installer, which edits the host's code safely and shows each
change as a diff before it writes. Every step is idempotent: running the
installer again changes nothing.

## In one `use`

`PhoenixMountable.Install` declares the installer:

```elixir
defmodule Mix.Tasks.MyLib.Install do
  use PhoenixMountable.Install,
    otp_app: :my_lib,
    mounts: [
      {MyLib.Router, "/my_lib", scope: "/admin", options: "resolver: {web}.MyLibResolver"}
    ],
    migrations: MyLib.Migrations,
    hook: {"MyLib", "my_lib"},
    css: ["my_lib.css", {"my_lib-dark.css", :comment}],
    manual: "See https://hexdocs.pm/my_lib/installation.html"
end
```

The steps run in this order, each when its option is given:

| Option | Step |
| --- | --- |
| `:mounts` | mounts each definition in the router: in a scope (`:scope`, `"/"` by default) with pipelines (`:pipelines`, `[:browser]`), with options (`{web}` is the host's web module) |
| `:migrations` | writes the migration that installs or upgrades the library's tables |
| `:hook` | adds `import { MyLib } from "my_lib"` and the hook to the `LiveSocket` of `assets/js/app.js` |
| `:css` | imports the library's style sheets in `assets/css/app.css`, a theme as a comment |
| `:tailwind` | adds the library to the host's Tailwind sources |
| `:supervisor` | starts the mounts' processes at boot |
| `:raw_body` | gives the endpoint's `Plug.Parsers` the reader that keeps a body as it was sent, for the library's signed webhooks (`PhoenixMountable.RawBody`); a host with a reader of its own is left as it is, with a warning |

Then the library's own steps:

```elixir
@impl PhoenixMountable.Install
def install(igniter) do
  igniter
  |> Igniter.Project.Application.add_new_child({MyLib, repo: MyApp.Repo})
  |> Igniter.Project.Module.create_module(MyAppWeb.MyLibResolver, "...")
end
```

Igniter stays an optional dependency of the library. In a host without
it, `mix my_lib.install` says how to get it, and shows `:manual`.

## The building blocks

`PhoenixMountable.Igniter` has each step as a function, for an
installer written by hand:

```elixir
defmodule Mix.Tasks.MyLib.Install do
  use Igniter.Mix.Task

  @impl Igniter.Mix.Task
  def info(_argv, _parent), do: %Igniter.Mix.Task.Info{group: :my_lib}

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    igniter
    |> PhoenixMountable.Igniter.mount(MyLib.Router, "/my_lib")
    |> PhoenixMountable.Igniter.gen_migration(MyLib.Migrations)
    |> PhoenixMountable.Igniter.add_tailwind_source(:my_lib)
  end
end
```

* `mount/4` adds the import and the mount call to the router's scope
  with the given path and pipelines, and the library to the host's
  `.formatter.exs`. A library whose several definitions are re-exported
  by one module passes `import: MyLib.Router`.
* `gen_migration/3` writes the migration from the version the host's
  migrations pin to the latest, or nothing when the host is up to date,
  with Igniter's own migration generator. Call it from the library's
  upgrader too.
* `add_hook/4` and `add_css_imports/4` edit `app.js` and `app.css`, for a
  library whose components render in the host's own pages (a button in
  its header, a palette). The edits are `PhoenixMountable.Igniter.HostAssets`;
  where `app.js` cannot be edited safely, the host gets the lines to add.
* `add_supervisor/2` starts the mounts' processes at boot.
* `add_tailwind_source/2` adds the `@source` (Tailwind v4) or `content`
  (Tailwind v3) line for libraries styled by the host.

## Mix tasks

* `mix phoenix_mountable.gen.migration MyLib.Migrations` writes the
  install or upgrade migration. A library wraps it in its own task.
* `mix phoenix_mountable.check` checks every library's schema, for CI.
* `mix phoenix_mountable.backfill MyLib.Migrations` runs deferred
  backfills.

## Formatting

Export the mount macro in the library's `.formatter.exs`, so that a host
that imports the library's formatting (`mount/4` adds it) writes
`my_lib "/my_lib"` without parentheses:

```elixir
[
  import_deps: [:phoenix_mountable],
  export: [locals_without_parens: [my_lib: 1, my_lib: 2]]
]
```

`import_deps: [:phoenix_mountable]` formats the definition's DSL
(`routes`, `live`, `options`).

## Testing an installer

`Igniter.Test.test_project/1` with the files the installer edits (a
router, `assets/js/app.js`, `assets/css/app.css`) runs it without a real
app, and without the `phx_new` archive that `phx_test_project/1` needs:

```elixir
igniter =
  Igniter.Test.test_project(files: %{"lib/test_web/router.ex" => router, "assets/js/app.js" => app_js})
  |> Igniter.compose_task(Mix.Tasks.MyLib.Install, [])
```
