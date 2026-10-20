if Code.ensure_loaded?(Ecto.Adapters.SQL) do
  defmodule PhoenixMountable.Migrations.SQL do
    @moduledoc false
    # Adapter-specific SQL: detection, quoting, the tracking tables and
    # introspection. Kept to plain queries so it runs both inside a migration
    # (on the migration's connection and transaction) and outside of one.

    @tracking "phoenix_mountable_schema"
    @backfills "phoenix_mountable_backfills"
    @meta_library "phoenix_mountable"
    @meta_version 1

    def tracking_table, do: @tracking
    def backfills_table, do: @backfills

    @doc false
    # Whether the caller runs inside an Ecto migration. Ecto has no public
    # function for it; the runner keeps its state under this key.
    def in_migration?, do: Process.get(:ecto_migration) != nil

    @doc false
    # Executes the queued commands of the running migration, so plain queries
    # see their effect. `Ecto.Migration.flush/0` is a macro tied to the
    # migration module, so the runner is called directly. A no-op outside a
    # migration.
    def flush do
      if in_migration?(), do: Ecto.Migration.Runner.flush()
      :ok
    end

    @doc false
    def adapter(repo) do
      case repo.__adapter__() do
        Ecto.Adapters.Postgres ->
          :postgres

        Ecto.Adapters.MyXQL ->
          :mysql

        Ecto.Adapters.SQLite3 ->
          :sqlite

        other ->
          raise ArgumentError, "PhoenixMountable migrations do not support #{inspect(other)}"
      end
    end

    @doc false
    def default_prefix(:postgres), do: "public"
    def default_prefix(_adapter), do: nil

    @doc false
    def query!(repo, sql, params \\ []) do
      Ecto.Adapters.SQL.query!(repo, sql, params, log: false)
    end

    @doc false
    def quote_name(:mysql, name), do: "`#{String.replace(to_string(name), "`", "``")}`"
    def quote_name(_adapter, name), do: ~s("#{String.replace(to_string(name), "\"", "\"\"")}")

    @doc false
    def table(adapter, prefix, name) do
      case {adapter, prefix} do
        {:sqlite, _} -> quote_name(adapter, name)
        {_, nil} -> quote_name(adapter, name)
        {_, prefix} -> quote_name(adapter, prefix) <> "." <> quote_name(adapter, name)
      end
    end

    @doc false
    def params(:postgres, count), do: Enum.map(1..count, &"$#{&1}")
    def params(_adapter, count), do: List.duplicate("?", count)

    @doc false
    def table_exists?(repo, adapter, prefix, name) do
      {sql, params} =
        case adapter do
          :postgres ->
            {"SELECT 1 FROM information_schema.tables WHERE table_schema = $1 AND table_name = $2",
             [prefix || "public", name]}

          :mysql ->
            {"SELECT 1 FROM information_schema.tables WHERE table_schema = COALESCE(?, DATABASE()) AND table_name = ?",
             [prefix, name]}

          :sqlite ->
            {"SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", [name]}
        end

      query!(repo, sql, params).num_rows > 0
    end

    @doc false
    def ensure_tracking!(repo, adapter, prefix) do
      if not table_exists?(repo, adapter, prefix, @tracking) do
        {text, timestamp} = types(adapter)

        query!(repo, """
        CREATE TABLE #{table(adapter, prefix, @tracking)} (
          library VARCHAR(255) NOT NULL PRIMARY KEY,
          version INTEGER NOT NULL,
          install_options #{text} NOT NULL,
          updated_at #{timestamp} NOT NULL
        )
        """)

        query!(repo, """
        CREATE TABLE #{table(adapter, prefix, @backfills)} (
          library VARCHAR(255) NOT NULL,
          name VARCHAR(255) NOT NULL,
          status VARCHAR(20) NOT NULL,
          resume_from #{text},
          processed BIGINT NOT NULL DEFAULT 0,
          error #{text},
          updated_at #{timestamp} NOT NULL,
          PRIMARY KEY (library, name)
        )
        """)

        put_row!(repo, adapter, prefix, @meta_library, @meta_version, %{})
      end

      :ok
    end

    defp types(:postgres), do: {"TEXT", "TIMESTAMP(0)"}
    defp types(:mysql), do: {"TEXT", "DATETIME"}
    defp types(:sqlite), do: {"TEXT", "TEXT"}

    @doc false
    def fetch_row(repo, adapter, prefix, library) do
      if table_exists?(repo, adapter, prefix, @tracking) do
        [p] = params(adapter, 1)

        case query!(
               repo,
               "SELECT version, install_options FROM #{table(adapter, prefix, @tracking)} WHERE library = #{p}",
               [library]
             ).rows do
          [[version, options]] -> {:ok, version, JSON.decode!(options)}
          [] -> :error
        end
      else
        :error
      end
    end

    @doc false
    def put_row!(repo, adapter, prefix, library, version, install_options) do
      table = table(adapter, prefix, @tracking)
      json = JSON.encode!(install_options)
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      [p1, p2, p3, p4] = params(adapter, 4)

      %{num_rows: updated} =
        query!(
          repo,
          "UPDATE #{table} SET version = #{p1}, install_options = #{p2}, updated_at = #{p3} WHERE library = #{p4}",
          [version, json, now, library]
        )

      if updated == 0 do
        query!(
          repo,
          "INSERT INTO #{table} (library, version, install_options, updated_at) VALUES (#{p1}, #{p2}, #{p3}, #{p4})",
          [library, version, json, now]
        )
      end

      :ok
    end

    @doc false
    def delete_row!(repo, adapter, prefix, library) do
      [p] = params(adapter, 1)

      query!(repo, "DELETE FROM #{table(adapter, prefix, @tracking)} WHERE library = #{p}", [
        library
      ])

      query!(repo, "DELETE FROM #{table(adapter, prefix, @backfills)} WHERE library = #{p}", [
        library
      ])

      :ok
    end

    ## Backfill rows

    @doc false
    def backfill_rows(repo, adapter, prefix, library) do
      if table_exists?(repo, adapter, prefix, @backfills) do
        [p] = params(adapter, 1)

        query!(
          repo,
          "SELECT name, status, resume_from, processed, error FROM #{table(adapter, prefix, @backfills)} " <>
            "WHERE library = #{p} ORDER BY name",
          [library]
        ).rows
        |> Enum.map(fn [name, status, cursor, processed, error] ->
          %{
            name: name,
            status: status,
            cursor: decode_cursor(cursor),
            processed: processed,
            error: error
          }
        end)
      else
        []
      end
    end

    @doc false
    def put_backfill!(repo, adapter, prefix, library, name, fields) do
      table = table(adapter, prefix, @backfills)
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      fields = Map.put(fields, :updated_at, now)
      # The column is resume_from: CURSOR is reserved in MySQL.
      fields =
        if Map.has_key?(fields, :cursor) do
          {cursor, fields} = Map.pop(fields, :cursor)
          Map.put(fields, :resume_from, encode_cursor(cursor))
        else
          fields
        end

      keys = Map.keys(fields)
      values = Map.values(fields)

      set_params = params(adapter, length(keys) + 2)
      {set, [p_lib, p_name]} = Enum.split(set_params, length(keys))
      assignments = Enum.zip_with(keys, set, &"#{&1} = #{&2}") |> Enum.join(", ")

      %{num_rows: updated} =
        query!(
          repo,
          "UPDATE #{table} SET #{assignments} WHERE library = #{p_lib} AND name = #{p_name}",
          values ++ [library, name]
        )

      if updated == 0 do
        all =
          [library: library, name: name, status: "pending", processed: 0] ++ Enum.to_list(fields)

        all = Keyword.new(all)
        insert_params = params(adapter, length(all))

        query!(
          repo,
          "INSERT INTO #{table} (#{Enum.map_join(Keyword.keys(all), ", ", &to_string/1)}) " <>
            "VALUES (#{Enum.join(insert_params, ", ")})",
          Keyword.values(all)
        )
      end

      :ok
    end

    defp encode_cursor(nil), do: nil
    defp encode_cursor(cursor), do: cursor |> :erlang.term_to_binary() |> Base.encode64()

    defp decode_cursor(nil), do: nil
    defp decode_cursor(text), do: text |> Base.decode64!() |> :erlang.binary_to_term([:safe])

    ## Introspection

    @doc false
    def tables(repo, adapter, prefix) do
      {sql, params} =
        case adapter do
          :postgres ->
            {"SELECT table_name FROM information_schema.tables WHERE table_schema = $1 AND table_type = 'BASE TABLE'",
             [prefix || "public"]}

          :mysql ->
            {"SELECT table_name FROM information_schema.tables WHERE table_schema = COALESCE(?, DATABASE()) " <>
               "AND table_type = 'BASE TABLE'", [prefix]}

          :sqlite ->
            {"SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
             []}
        end

      query!(repo, sql, params).rows |> List.flatten() |> Enum.sort()
    end

    @doc """
    The columns of a table: name, type, nullable and default, in order.
    """
    def columns(repo, adapter, prefix, table) do
      case adapter do
        :postgres ->
          query!(
            repo,
            "SELECT column_name, data_type, is_nullable, column_default FROM information_schema.columns " <>
              "WHERE table_schema = $1 AND table_name = $2 ORDER BY ordinal_position",
            [prefix || "public", table]
          ).rows
          |> Enum.map(fn [name, type, nullable, default] ->
            %{
              name: name,
              type: type,
              null: nullable == "YES",
              default: normalize_default(default, prefix)
            }
          end)

        :mysql ->
          query!(
            repo,
            "SELECT column_name, column_type, is_nullable, column_default FROM information_schema.columns " <>
              "WHERE table_schema = COALESCE(?, DATABASE()) AND table_name = ? ORDER BY ordinal_position",
            [prefix, table]
          ).rows
          |> Enum.map(fn [name, type, nullable, default] ->
            %{name: name, type: type, null: nullable == "YES", default: default}
          end)

        :sqlite ->
          query!(repo, "SELECT * FROM pragma_table_info(?)", [table]).rows
          |> Enum.map(fn [_cid, name, type, notnull, default, pk] ->
            %{name: name, type: type, null: notnull == 0 and pk == 0, default: default, pk: pk}
          end)
      end
    end

    # A sequence default names its schema; ignore it so two prefixes compare.
    defp normalize_default(nil, _prefix), do: nil

    defp normalize_default(default, prefix) when is_binary(default) and is_binary(prefix) do
      String.replace(default, "#{prefix}.", "")
    end

    defp normalize_default(default, _prefix), do: default

    @doc """
    The indexes of a table: name, columns and uniqueness.
    """
    def indexes(repo, adapter, prefix, table) do
      case adapter do
        :postgres ->
          query!(
            repo,
            """
            SELECT i.relname, ix.indisunique, ix.indisprimary,
                   array_agg(a.attname ORDER BY array_position(ix.indkey, a.attnum))
            FROM pg_index ix
            JOIN pg_class t ON t.oid = ix.indrelid
            JOIN pg_class i ON i.oid = ix.indexrelid
            JOIN pg_namespace n ON n.oid = t.relnamespace
            JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY(ix.indkey)
            WHERE n.nspname = $1 AND t.relname = $2
            GROUP BY i.relname, ix.indisunique, ix.indisprimary
            """,
            [prefix || "public", table]
          ).rows
          |> Enum.reject(fn [_, _, primary, _] -> primary end)
          |> Enum.map(fn [name, unique, _, columns] ->
            %{name: name, unique: unique, columns: columns}
          end)

        :mysql ->
          query!(
            repo,
            "SELECT index_name, non_unique, column_name FROM information_schema.statistics " <>
              "WHERE table_schema = COALESCE(?, DATABASE()) AND table_name = ? AND index_name <> 'PRIMARY' " <>
              "ORDER BY index_name, seq_in_index",
            [prefix, table]
          ).rows
          |> Enum.group_by(&Enum.at(&1, 0))
          |> Enum.map(fn {name, [[_, non_unique, _] | _] = rows} ->
            %{name: name, unique: non_unique == 0, columns: Enum.map(rows, &Enum.at(&1, 2))}
          end)

        :sqlite ->
          query!(repo, "SELECT * FROM pragma_index_list(?)", [table]).rows
          |> Enum.reject(fn [_seq, _name, _unique, origin | _] -> origin == "pk" end)
          |> Enum.map(fn [_seq, name, unique, origin | _] ->
            columns =
              query!(repo, "SELECT * FROM pragma_index_info(?)", [name]).rows
              |> Enum.map(fn [_seqno, _cid, column] -> column end)

            %{name: name, unique: unique == 1, columns: columns, origin: origin}
          end)
      end
      |> Enum.sort_by(& &1.name)
    end

    @doc """
    A comparable description of the tables in a prefix: columns and indexes.
    """
    def schema(repo, adapter, prefix, opts \\ []) do
      except = Keyword.get(opts, :except, [@tracking, @backfills, "schema_migrations"])

      for table <- tables(repo, adapter, prefix), table not in except, into: %{} do
        # Columns by name: re-adding a dropped column puts it last, and order
        # does not affect compatibility.
        columns = repo |> columns(adapter, prefix, table) |> Enum.sort_by(& &1.name)
        {table, %{columns: columns, indexes: indexes(repo, adapter, prefix, table)}}
      end
    end
  end
end
