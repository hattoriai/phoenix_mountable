if Code.ensure_loaded?(Ecto.Adapters.SQL) do
  defmodule PhoenixMountable.Migrations.Check do
    @moduledoc false
    # Status of a library's schema in a database, and what to tell the host.

    alias PhoenixMountable.Migrations.SQL

    @doc false
    def status(migrations, opts) do
      repo = Keyword.fetch!(opts, :repo)
      adapter = SQL.adapter(repo)

      prefix =
        if adapter == :sqlite,
          do: nil,
          else: Keyword.get(opts, :prefix) || SQL.default_prefix(adapter)

      library = migrations.__phoenix_mountable_migrations__(:library)
      latest = migrations.__phoenix_mountable_migrations__(:latest)

      {current, installed?} =
        case SQL.fetch_row(repo, adapter, prefix, library) do
          {:ok, version, _} -> {version, true}
          :error -> {legacy(migrations, repo, adapter, prefix, library) || 0, false}
        end

      backfills = SQL.backfill_rows(repo, adapter, prefix, library)

      %{
        library: library,
        repo: repo,
        prefix: prefix,
        current: current,
        latest: latest,
        compatible_with: migrations.__phoenix_mountable_migrations__(:compatible_with),
        tracked?: installed?,
        backfills: backfills,
        pending_backfills: Enum.reject(backfills, &(&1.status == "done"))
      }
    end

    defp legacy(migrations, repo, adapter, prefix, library) do
      case migrations.__phoenix_mountable_migrations__(:legacy) do
        nil ->
          nil

        legacy ->
          legacy.detect(%PhoenixMountable.Migrations.Context{
            repo: repo,
            adapter: adapter,
            prefix: prefix,
            library: library,
            migrations: migrations
          })
      end
    end

    @doc false
    def check(migrations, opts) do
      status = status(migrations, opts)
      task = migrations.__phoenix_mountable_migrations__(:gen_task)

      fix =
        "Generate the migration with `mix #{task}`, then run `mix ecto.migrate`" <>
          if(status.prefix in [nil, "public"],
            do: ".",
            else: " (prefix #{inspect(status.prefix)})."
          )

      cond do
        status.current == 0 and status.latest > 0 ->
          {:outdated,
           "#{status.library} is not installed in #{inspect(status.repo)}: its tables do not exist. " <>
             fix}

        status.current < status.compatible_with ->
          {:outdated,
           "#{status.library}'s schema in #{inspect(status.repo)} is at version #{status.current}, but this " <>
             "version of #{status.library} needs at least version #{status.compatible_with} " <>
             "(latest: #{status.latest}). " <> fix}

        status.current < status.latest ->
          {:pending,
           "#{status.library}'s schema in #{inspect(status.repo)} is at version #{status.current}; " <>
             "version #{status.latest} is available. It still works, but upgrade soon. " <> fix}

        status.current > status.latest ->
          {:pending,
           "#{status.library}'s schema in #{inspect(status.repo)} is at version #{status.current}, newer " <>
             "than this version of #{status.library} knows (#{status.latest}). Was the dependency downgraded?"}

        true ->
          :ok
      end
    end

    @doc false
    # Compares the tables with the library's expected schema: a snapshot
    # written by PhoenixMountable.Migrations.Test.write_snapshot!/3. Extra
    # columns, indexes and tables of the host are fine; missing or changed ones
    # are reported.
    def verify(migrations, opts) do
      repo = Keyword.fetch!(opts, :repo)
      adapter = SQL.adapter(repo)

      prefix =
        if adapter == :sqlite,
          do: nil,
          else: Keyword.get(opts, :prefix) || SQL.default_prefix(adapter)

      expected =
        Keyword.get_lazy(opts, :snapshot, fn -> read_snapshot(migrations, adapter) end) ||
          raise ArgumentError,
                "#{inspect(migrations)} has no schema snapshot for #{adapter}; pass :snapshot or write one " <>
                  "with PhoenixMountable.Migrations.Test.write_snapshot!/3"

      actual = SQL.schema(repo, adapter, prefix)

      problems =
        Enum.flat_map(expected, fn {table, %{columns: columns, indexes: indexes}} ->
          case Map.fetch(actual, table) do
            :error ->
              [{:missing_table, table}]

            {:ok, actual_table} ->
              column_problems(table, columns, actual_table.columns) ++
                index_problems(table, indexes, actual_table.indexes)
          end
        end)

      if problems == [], do: :ok, else: {:error, problems}
    end

    defp column_problems(table, expected, actual) do
      actual = Map.new(actual, &{&1.name, &1})

      Enum.flat_map(expected, fn column ->
        case Map.fetch(actual, column.name) do
          :error ->
            [{:missing_column, table, column.name}]

          {:ok, %{type: type}} when type != column.type ->
            [{:column_type, table, column.name, column.type, type}]

          {:ok, _} ->
            []
        end
      end)
    end

    defp index_problems(table, expected, actual) do
      actual_columns = MapSet.new(actual, &{&1.columns, &1.unique})

      Enum.flat_map(expected, fn index ->
        if MapSet.member?(actual_columns, {index.columns, index.unique}),
          do: [],
          else: [{:missing_index, table, index.name}]
      end)
    end

    @doc false
    def snapshot_path(migrations, adapter) do
      otp_app = migrations.__phoenix_mountable_migrations__(:otp_app)
      library = migrations.__phoenix_mountable_migrations__(:library)

      Path.join([
        Application.app_dir(otp_app, "priv"),
        "phoenix_mountable",
        "#{library}.#{adapter}.schema"
      ])
    end

    defp read_snapshot(migrations, adapter) do
      case File.read(snapshot_path(migrations, adapter)) do
        {:ok, binary} -> :erlang.binary_to_term(binary, [:safe])
        {:error, _} -> nil
      end
    end
  end
end
