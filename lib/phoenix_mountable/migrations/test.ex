if Code.ensure_loaded?(Ecto.Migration) do
  defmodule PhoenixMountable.Migrations.Test do
    @moduledoc """
    Checks for a library's migrations, run against a real database in the
    library's own test suite.

        test "migrations", %{repo: repo} do
          PhoenixMountable.Migrations.Test.run_suite(repo, MyLib.Migrations, prefix: "my_lib_test")
        end

    `run_suite/3` runs:

      * `assert_round_trip/3` — every version goes up, down and up again, and
        down gives back exactly the previous schema;
      * `assert_baseline_matches/3` — when the library has a baseline, a fresh
        install through it gives the same schema as running every version;
      * `assert_upgrades/3` — an install at each released version upgrades to
        the latest and ends with the same schema as a fresh install;
      * `assert_preserves_host_changes/3` — the "hostile host": after each
        version, a column and an index are added to every library table, as a
        host might, and they must survive every later version.

    and, with `idempotent: true` (recommended for MySQL, whose DDL is not
    transactional), `assert_rerunnable/3`: each version can run again after
    failing halfway.

    Each check starts from an empty schema: a Postgres schema or MySQL database
    named by `:prefix` (dropped and recreated), or an emptied SQLite database.
    Use a database and prefix reserved for these tests.

    ## Options

      * `:prefix` — the prefix to use. Defaults to `"phoenix_mountable_test"`
        (ignored on SQLite).
      * `:install` — install options for `up/1`, such as `primary_key: :binary_id`.
      * `:seed` — `fn version, ctx -> ... end`, run by `assert_upgrades/3` after
        installing at `version`, to insert data.
      * `:verify` — `fn version, ctx -> ... end`, run by `assert_upgrades/3`
        after upgrading from `version`, to check that data.
    """

    import ExUnit.Assertions

    alias PhoenixMountable.Migrations
    alias PhoenixMountable.Migrations.{Context, SQL}

    @default_prefix "phoenix_mountable_test"
    @host_column "phoenix_mountable_host_note"

    @doc "Runs every check. See the module documentation."
    def run_suite(repo, migrations, opts \\ []) do
      assert_round_trip(repo, migrations, opts)

      if migrations.__phoenix_mountable_migrations__(:baseline),
        do: assert_baseline_matches(repo, migrations, opts)

      assert_upgrades(repo, migrations, opts)
      assert_preserves_host_changes(repo, migrations, opts)
      if opts[:idempotent], do: assert_rerunnable(repo, migrations, opts)
      :ok
    end

    @doc "Every version goes up, down and up again, with matching schemas."
    def assert_round_trip(repo, migrations, opts \\ []) do
      reset!(repo, opts)
      empty = schema(repo, opts)
      latest = migrations.latest_version()

      _ =
        Enum.reduce(1..latest//1, empty, fn version, previous ->
          up(repo, migrations, Keyword.merge(opts, version: version, baseline: false))
          current = schema(repo, opts)
          assert migrations.migrated_version(repo: repo, prefix: prefix(repo, opts)) == version

          down(repo, migrations, Keyword.merge(opts, to: version - 1))

          assert schema(repo, opts) == previous,
                 "#{inspect(migrations)}: rolling back version #{version} does not restore the schema of " <>
                   "version #{version - 1}"

          up(repo, migrations, Keyword.merge(opts, version: version, baseline: false))

          assert schema(repo, opts) == current,
                 "#{inspect(migrations)}: version #{version} is not repeatable"

          current
        end)

      :ok
    end

    @doc "A fresh install through the baseline matches running every version."
    def assert_baseline_matches(repo, migrations, opts \\ []) do
      latest = migrations.latest_version()

      reset!(repo, opts)
      up(repo, migrations, Keyword.merge(opts, version: latest, baseline: false))
      incremental = schema(repo, opts)

      reset!(repo, opts)
      up(repo, migrations, Keyword.merge(opts, version: latest))
      baseline = schema(repo, opts)

      assert baseline == incremental,
             "#{inspect(migrations)}: the baseline does not match versions 1 to #{latest}.\n\n" <>
               "Baseline only: #{inspect(diff(baseline, incremental))}\n" <>
               "Versions only: #{inspect(diff(incremental, baseline))}"

      :ok
    end

    @doc "An install at each version upgrades to the latest schema."
    def assert_upgrades(repo, migrations, opts \\ []) do
      latest = migrations.latest_version()

      reset!(repo, opts)
      up(repo, migrations, Keyword.merge(opts, version: latest, baseline: false))
      expected = schema(repo, opts)

      for version <- 0..(latest - 1)//1 do
        reset!(repo, opts)

        if version > 0,
          do: up(repo, migrations, Keyword.merge(opts, version: version, baseline: false))

        if seed = opts[:seed], do: seed.(version, context(repo, migrations, opts))

        up(repo, migrations, Keyword.merge(opts, version: latest))

        assert schema(repo, opts) == expected,
               "#{inspect(migrations)}: upgrading from version #{version} gives a different schema than a " <>
                 "fresh install"

        if verify = opts[:verify], do: verify.(version, context(repo, migrations, opts))
      end

      :ok
    end

    @doc """
    After each version, a host adds a column and an index to every library
    table; they must survive every later version.
    """
    def assert_preserves_host_changes(repo, migrations, opts \\ []) do
      latest = migrations.latest_version()
      adapter = SQL.adapter(repo)
      prefix = prefix(repo, opts)

      for version <- 1..(latest - 1)//1 do
        reset!(repo, opts)
        up(repo, migrations, Keyword.merge(opts, version: version, baseline: false))
        tables = Map.keys(schema(repo, opts))

        for table <- tables do
          SQL.query!(
            repo,
            "ALTER TABLE #{SQL.table(adapter, prefix, table)} ADD COLUMN #{@host_column} VARCHAR(50)"
          )

          SQL.query!(
            repo,
            "CREATE INDEX #{SQL.quote_name(adapter, index_name(table))} ON #{SQL.table(adapter, prefix, table)} " <>
              "(#{@host_column})"
          )
        end

        up(repo, migrations, Keyword.merge(opts, version: latest))
        after_upgrade = schema(repo, opts)

        for table <- tables, Map.has_key?(after_upgrade, table) do
          %{columns: columns, indexes: indexes} = after_upgrade[table]

          assert Enum.any?(columns, &(&1.name == @host_column)),
                 "#{inspect(migrations)}: upgrading from version #{version} drops the column a host added to #{table}"

          assert Enum.any?(indexes, &(&1.columns == [@host_column])),
                 "#{inspect(migrations)}: upgrading from version #{version} drops the index a host added to #{table}"
        end
      end

      :ok
    end

    defp index_name(table), do: "#{table}_host_note_index" |> String.slice(0, 60)

    @doc """
    Each version runs again after failing halfway: its tracking is reset to the
    previous version and it runs a second time.
    """
    def assert_rerunnable(repo, migrations, opts \\ []) do
      adapter = SQL.adapter(repo)
      prefix = prefix(repo, opts)
      library = migrations.__phoenix_mountable_migrations__(:library)

      for version <- 1..migrations.latest_version()//1 do
        reset!(repo, opts)
        up(repo, migrations, Keyword.merge(opts, version: version, baseline: false))
        {:ok, _, install_options} = SQL.fetch_row(repo, adapter, prefix, library)

        if version > 1,
          do: SQL.put_row!(repo, adapter, prefix, library, version - 1, install_options)

        if version == 1, do: SQL.delete_row!(repo, adapter, prefix, library)

        try do
          up(repo, migrations, Keyword.merge(opts, version: version, baseline: false))
        rescue
          error ->
            flunk(
              "#{inspect(migrations)}: version #{version} fails when run again after a partial failure: " <>
                Exception.message(error) <> "\nUse the *_if_not_exists / *_if_exists functions."
            )
        end
      end

      :ok
    end

    @doc """
    Writes the schema of a fresh install at the latest version to the
    library's `priv/phoenix_mountable`, for `verify/1` at runtime.
    """
    def write_snapshot!(repo, migrations, opts \\ []) do
      reset!(repo, opts)
      up(repo, migrations, Keyword.merge(opts, version: migrations.latest_version()))
      library = migrations.__phoenix_mountable_migrations__(:library)
      adapter = SQL.adapter(repo)
      path = Path.join(["priv", "phoenix_mountable", "#{library}.#{adapter}.schema"])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, :erlang.term_to_binary(schema(repo, opts)))
      path
    end

    ## Running

    @doc """
    Runs `migrations.up(opts)` inside a real Ecto migration, outside a
    transaction when the versions need it.
    """
    def up(repo, migrations, opts \\ []) do
      prefix = prefix(repo, opts)
      adapter = SQL.adapter(repo)

      from =
        if SQL.table_exists?(repo, adapter, prefix, SQL.tracking_table()),
          do: migrations.migrated_version(repo: repo, prefix: prefix),
          else: 0

      to = Keyword.get(opts, :version, migrations.latest_version())

      no_transaction? =
        Migrations.no_transaction?(migrations, adapter, min(from, to), max(from, to))

      args =
        opts
        |> Keyword.take([:version, :backfills, :baseline])
        |> Keyword.merge(Keyword.get(opts, :install, []))

      run(repo, fn -> migrations.up(args) end, prefix: prefix, no_transaction: no_transaction?)
    end

    @doc "Runs `migrations.down(opts)` inside a real Ecto migration."
    def down(repo, migrations, opts \\ []) do
      prefix = prefix(repo, opts)
      adapter = SQL.adapter(repo)
      from = migrations.migrated_version(repo: repo, prefix: prefix)
      to = Keyword.get(opts, :to, 0)

      no_transaction? =
        Migrations.no_transaction?(migrations, adapter, min(from, to), max(from, to))

      run(repo, fn -> migrations.down(to: to) end,
        prefix: prefix,
        no_transaction: no_transaction?
      )
    end

    @doc """
    Runs `fun` as the `up/0` of a one-off Ecto migration.
    """
    def run(repo, fun, opts \\ []) do
      id = System.unique_integer([:positive, :monotonic])
      key = {__MODULE__, id}
      module = Module.concat([__MODULE__, Step, "S#{id}"])
      no_transaction? = Keyword.get(opts, :no_transaction, false)

      :persistent_term.put(key, fun)

      Code.compiler_options(ignore_module_conflict: true)

      Module.create(
        module,
        quote do
          use Ecto.Migration
          @disable_ddl_transaction unquote(no_transaction?)
          @disable_migration_lock unquote(no_transaction?)
          def up, do: :persistent_term.get(unquote(Macro.escape(key))).()
          def down, do: :ok
        end,
        Macro.Env.location(__ENV__)
      )

      try do
        case Ecto.Migrator.up(repo, 10_000_000_000_000 + id, module,
               log: false,
               prefix: opts[:prefix]
             ) do
          :ok -> :ok
          :already_up -> :ok
        end
      after
        :persistent_term.erase(key)
        :code.purge(module)
        :code.delete(module)
      end
    end

    @doc "Empties the prefix (or the SQLite database)."
    def reset!(repo, opts \\ []) do
      adapter = SQL.adapter(repo)
      prefix = prefix(repo, opts)

      case adapter do
        :postgres ->
          SQL.query!(repo, "DROP SCHEMA IF EXISTS #{SQL.quote_name(adapter, prefix)} CASCADE")
          SQL.query!(repo, "CREATE SCHEMA #{SQL.quote_name(adapter, prefix)}")

        :mysql ->
          SQL.query!(repo, "DROP DATABASE IF EXISTS #{SQL.quote_name(adapter, prefix)}")
          SQL.query!(repo, "CREATE DATABASE #{SQL.quote_name(adapter, prefix)}")

        :sqlite ->
          SQL.query!(repo, "PRAGMA foreign_keys = OFF")

          for table <- SQL.tables(repo, :sqlite, nil) do
            SQL.query!(repo, "DROP TABLE IF EXISTS #{SQL.quote_name(:sqlite, table)}")
          end

          SQL.query!(repo, "PRAGMA foreign_keys = ON")
      end

      :ok
    end

    @doc "The comparable schema of the prefix, without tracking tables."
    def schema(repo, opts \\ []) do
      SQL.schema(repo, SQL.adapter(repo), prefix(repo, opts))
    end

    @doc false
    def prefix(repo, opts) do
      case SQL.adapter(repo) do
        :sqlite -> nil
        _ -> Keyword.get(opts, :prefix, @default_prefix)
      end
    end

    defp context(repo, migrations, opts) do
      adapter = SQL.adapter(repo)
      prefix = prefix(repo, opts)
      library = migrations.__phoenix_mountable_migrations__(:library)

      install_options =
        case SQL.fetch_row(repo, adapter, prefix, library) do
          {:ok, _, options} -> options
          :error -> %{}
        end

      %Context{
        repo: repo,
        adapter: adapter,
        prefix: prefix,
        library: library,
        migrations: migrations,
        install_options: install_options
      }
    end

    defp diff(a, b) do
      for {table, definition} <- a,
          Map.get(b, table) != definition,
          into: %{},
          do: {table, definition}
    end
  end
end
