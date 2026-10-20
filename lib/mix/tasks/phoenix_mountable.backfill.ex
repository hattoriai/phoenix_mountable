if Code.ensure_loaded?(Ecto.Migrator) do
  defmodule Mix.Tasks.PhoenixMountable.Backfill do
    @shortdoc "Runs a mountable library's pending backfills"

    @moduledoc """
    Runs a library's deferred backfills to completion.

        $ mix phoenix_mountable.backfill MyLib.Migrations

    Progress is recorded after every batch, so it can be stopped and run again.
    In production, `PhoenixMountable.Backfill.Runner` does the same in the
    running app.

    ## Options

      * `-r`, `--repo` — the repo (defaults to the app's `:ecto_repos`)
      * `--prefix` — the prefix
      * `--throttle` — milliseconds to wait between batches
    """

    use Mix.Task

    @switches [repo: [:string, :keep], prefix: :string, throttle: :integer]

    @impl true
    def run(args) do
      {opts, positional} = OptionParser.parse!(args, strict: @switches, aliases: [r: :repo])

      migrations =
        case positional do
          [name] ->
            Module.concat([name])

          _ ->
            Mix.raise(
              "expected the migrations module, for example: mix phoenix_mountable.backfill MyLib.Migrations"
            )
        end

      Mix.Task.run("app.config")

      for repo <- Mix.Ecto.parse_repo(args) do
        {:ok, result, _} =
          Ecto.Migrator.with_repo(repo, fn repo ->
            migrations.run_backfills(repo: repo, prefix: opts[:prefix], throttle: opts[:throttle])
          end)

        case result do
          :ok ->
            Mix.shell().info("#{inspect(migrations)}: backfills done")

          {:error, failed} ->
            Mix.raise("#{inspect(migrations)}: backfills failed: #{inspect(failed)}")
        end
      end
    end
  end
end
