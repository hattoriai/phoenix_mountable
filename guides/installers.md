# Installers

[Igniter](https://hexdocs.pm/igniter) installers edit the host's code
safely, so `mix igniter.install my_lib` can mount the library, write its
migration and configure Tailwind. `PhoenixMountable.Igniter` has the
building blocks:

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

* `mount/4` adds `import MyLib.Router` and the mount call to the host
  router's scope piped through `:browser`.
* `gen_migration/3` writes the migration from the version the host's
  migrations pin to the latest, or nothing when the host is up to date,
  with Igniter's own migration generator. Call it from the library's
  upgrader too.
* `add_supervisor/2` starts the mounts' processes at boot.
* `add_tailwind_source/2` adds the `@source` (Tailwind v4) or `content`
  (Tailwind v3) line for libraries styled by the host.

Every step is idempotent. Igniter stays an optional dependency: the
manual steps are the mount line, `mix phoenix_mountable.gen.migration`
and the Tailwind line.

## Mix tasks

* `mix phoenix_mountable.gen.migration MyLib.Migrations` writes the
  install or upgrade migration. A library wraps it in its own task.
* `mix phoenix_mountable.check` checks every library's schema, for CI.
* `mix phoenix_mountable.backfill MyLib.Migrations` runs deferred
  backfills.

## Formatting

PhoenixMountable exports the formatting of its DSL. In the library's
`.formatter.exs`:

```elixir
[import_deps: [:phoenix_mountable], ...]
```
