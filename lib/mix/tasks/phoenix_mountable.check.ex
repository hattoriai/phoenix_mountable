if Code.ensure_loaded?(Ecto.Migrator) do
  defmodule Mix.Tasks.PhoenixMountable.Check do
    @shortdoc "Checks that the database has every mountable library's latest schema"

    @moduledoc """
    Checks every library using `PhoenixMountable.Migrations` against the
    database, for CI.

        $ mix phoenix_mountable.check

    Exits with status 1 when a library is not installed or its schema is older
    than the library needs. With `--strict`, a pending upgrade (older than the
    latest, but still compatible) fails too.

    ## Options

      * `-r`, `--repo` — the repo (defaults to the app's `:ecto_repos`)
      * `--prefix` — the prefix to check
      * `--strict` — fail on pending upgrades
      * `--only` — check only this migrations module (can repeat)
    """

    use Mix.Task

    @switches [repo: [:string, :keep], prefix: :string, strict: :boolean, only: [:string, :keep]]

    @impl true
    def run(args) do
      {opts, _} = OptionParser.parse!(args, strict: @switches, aliases: [r: :repo])
      Mix.Task.run("app.config")

      modules =
        case Keyword.get_values(opts, :only) do
          [] -> discover()
          names -> Enum.map(names, &Module.concat([&1]))
        end

      results =
        for repo <- Mix.Ecto.parse_repo(args), migrations <- modules do
          {:ok, result, _} =
            Ecto.Migrator.with_repo(repo, &migrations.check(repo: &1, prefix: opts[:prefix]))

          report(repo, migrations, result)
          result
        end

      failed? =
        Enum.any?(results, fn
          {:outdated, _} -> true
          {:pending, _} -> opts[:strict] == true
          _ -> false
        end)

      if failed?, do: exit({:shutdown, 1})
    end

    @doc false
    def discover do
      for {app, _, _} <- Application.loaded_applications(),
          {:ok, modules} = :application.get_key(app, :modules),
          module <- modules,
          Code.ensure_loaded?(module),
          function_exported?(module, :__phoenix_mountable_migrations__, 1),
          do: module
    end

    defp report(repo, migrations, :ok),
      do: Mix.shell().info("#{inspect(repo)} #{inspect(migrations)}: up to date")

    defp report(_repo, _migrations, {:pending, message}),
      do: Mix.shell().info([:yellow, message, :reset])

    defp report(_repo, _migrations, {:outdated, message}), do: Mix.shell().error(message)
  end
end
