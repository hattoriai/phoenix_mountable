if Code.ensure_loaded?(Ecto.Migrator) do
  defmodule Mix.Tasks.PhoenixMountable.Gen.Migration do
    @shortdoc "Generates the migration that installs or upgrades a mountable library"

    @moduledoc """
    Generates the host migration that installs or upgrades a library's tables.

        $ mix phoenix_mountable.gen.migration MyLib.Migrations

    The version the host is at is read from its existing migrations (the
    highest `MyLib.Migrations.up(version: n)`), so it works before the
    database is migrated. The new migration pins the latest version:

        def up, do: MyLib.Migrations.up(version: 4)
        def down, do: MyLib.Migrations.down(to: 2)

    It adds `@disable_ddl_transaction` and `@disable_migration_lock` when a
    version needs them, and notes contract changes, irreversible versions and
    backfills as comments. The file is created by `mix ecto.gen.migration`,
    so it follows the host's Ecto conventions.

    Libraries usually wrap it in a task of their own:

        defmodule Mix.Tasks.MyLib.Gen.Migration do
          use Mix.Task
          @shortdoc "Generates the migration for MyLib"
          def run(args), do: Mix.Task.run("phoenix_mountable.gen.migration", ["MyLib.Migrations" | args])
        end

    ## Options

      * `-r`, `--repo` — the repo (defaults to the app's `:ecto_repos`)
      * `--to` — the version to migrate to. Defaults to the latest.
      * `--from` — the version the host is at, when it cannot be read from its
        migrations (an existing `up()` without a version). Without it, the
        database is asked.
      * `--migrations-path` — where to write the migration
    """

    use Mix.Task

    alias PhoenixMountable.Migrations.Generator

    @switches [repo: [:string, :keep], to: :integer, from: :integer, migrations_path: :string]

    @impl true
    def run(args) do
      {opts, positional} = OptionParser.parse!(args, strict: @switches, aliases: [r: :repo])

      migrations =
        case positional do
          [name] ->
            Module.concat([name])

          _ ->
            Mix.raise(
              "expected the migrations module, for example: mix phoenix_mountable.gen.migration MyLib.Migrations"
            )
        end

      Mix.Task.run("compile")

      if not (Code.ensure_loaded?(migrations) and
                function_exported?(migrations, :__phoenix_mountable_migrations__, 1)) do
        Mix.raise("#{inspect(migrations)} is not a PhoenixMountable.Migrations module")
      end

      for repo <- Mix.Ecto.parse_repo(args) do
        Mix.Ecto.ensure_repo(repo, args)

        # The source directory, as `mix ecto.gen.migration` uses, not the
        # build directory of Ecto.Migrator.migrations_path/1.
        dir =
          opts[:migrations_path] || Path.join(Mix.EctoSQL.source_repo_priv(repo), "migrations")

        to = opts[:to] || migrations.latest_version()
        from = opts[:from] || from_version(migrations, repo, dir)

        if from >= to do
          Mix.shell().info(
            "#{inspect(repo)} is already at version #{from} of #{inspect(migrations)}"
          )
        else
          path_args =
            if opts[:migrations_path], do: ["--migrations-path", opts[:migrations_path]], else: []

          Generator.write!(migrations, repo, from, to, path_args)
          adapter = PhoenixMountable.Migrations.SQL.adapter(repo)

          notes =
            Generator.notes(migrations, Generator.infos(migrations, adapter, from, to), adapter)

          Enum.each(notes, fn note -> Mix.shell().info(note) end)
        end
      end
    end

    defp from_version(migrations, repo, dir) do
      case Generator.pinned_version(migrations, dir) do
        {:ok, version} ->
          version

        {:unpinned, files} ->
          Mix.shell().info(
            "#{Enum.join(files, ", ")} call #{inspect(migrations)}.up without a version; " <>
              "reading the version from the database"
          )

          {:ok, version, _} =
            Ecto.Migrator.with_repo(repo, &migrations.migrated_version(repo: &1))

          version
      end
    end
  end
end
