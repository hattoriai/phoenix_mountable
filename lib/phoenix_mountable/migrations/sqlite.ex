if Code.ensure_loaded?(Ecto.Adapters.SQL) do
  defmodule PhoenixMountable.Migrations.SQLite do
    @moduledoc """
    Table rebuilds for SQLite, whose `ALTER TABLE` cannot change a column.

    SQLite can add, rename and drop columns, but changing a column's type,
    nullability or default means creating a new table, copying the rows and
    swapping the tables. Done naively, that drops whatever the host added to
    the table. `rebuild_table/3` keeps it:

      * every column of the current table is copied, including columns the
        library does not know about;
      * every index (including unique constraints) and trigger is recreated;
      * foreign keys are kept and checked before committing;
      * a table with `CHECK` constraints or `COLLATE` clauses is refused,
        since they cannot be reproduced reliably, rather than silently lost.

    It runs in its own transaction with foreign keys off (dropping a table
    with them on would cascade deletes), so the version runs outside the
    migration's transaction; `PhoenixMountable.Migration` detects this.

    ## Changes

        rebuild_table(ctx, :my_lib_items,
          modify: [title: [type: "TEXT", null: false, default: "''"]],
          remove: [:legacy_flag],
          rename: [body: :content]
        )

      * `:modify` — columns to change: `:type` (SQL type), `:null` and
        `:default` (an SQL expression, as a string). Unmentioned attributes
        are kept.
      * `:remove` — columns to drop.
      * `:rename` — columns to rename, `old: :new`.
    """

    alias PhoenixMountable.Migrations.{Context, SQL}

    @doc """
    Rebuilds a SQLite table with the given changes. See the module documentation.
    """
    @spec rebuild_table(Context.t(), atom | String.t(), keyword) :: :ok
    def rebuild_table(%Context{adapter: :sqlite} = ctx, table, changes) do
      SQL.flush()
      table = to_string(table)
      repo = ctx.repo

      [[create_sql]] =
        SQL.query!(repo, "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", [
          table
        ]).rows

      if create_sql =~ ~r/\bCHECK\s*\(/i or create_sql =~ ~r/\bCOLLATE\b/i do
        raise ArgumentError,
              "cannot rebuild #{table}: it has CHECK constraints or COLLATE clauses, which a rebuild " <>
                "would not reproduce exactly. Rebuild it with explicit SQL in the migration."
      end

      columns = SQL.query!(repo, "SELECT * FROM pragma_table_info(?)", [table]).rows
      foreign_keys = SQL.query!(repo, "SELECT * FROM pragma_foreign_key_list(?)", [table]).rows

      others =
        SQL.query!(
          repo,
          "SELECT type, name, sql FROM sqlite_master WHERE tbl_name = ? AND type IN ('index', 'trigger') " <>
            "AND sql IS NOT NULL",
          [table]
        ).rows

      autoindexes = autoindexes(repo, table)

      remove = changes |> Keyword.get(:remove, []) |> Enum.map(&to_string/1)

      rename =
        changes
        |> Keyword.get(:rename, [])
        |> Map.new(fn {old, new} -> {to_string(old), to_string(new)} end)

      modify =
        changes
        |> Keyword.get(:modify, [])
        |> Map.new(fn {name, opts} -> {to_string(name), opts} end)

      kept = Enum.reject(columns, fn [_cid, name | _] -> name in remove end)
      pks = for [_cid, name, _type, _notnull, _default, pk] <- kept, pk > 0, do: {pk, name}
      single_pk = if length(pks) == 1, do: elem(hd(pks), 1)

      column_defs =
        Enum.map(kept, fn [_cid, name, type, notnull, default, _pk] ->
          opts = Map.get(modify, name, [])
          new_name = Map.get(rename, name, name)
          type = Keyword.get(opts, :type, type)
          null? = Keyword.get(opts, :null, notnull == 0)
          default = Keyword.get(opts, :default, default)

          pk =
            cond do
              name == single_pk and String.upcase(type) == "INTEGER" ->
                " PRIMARY KEY AUTOINCREMENT"

              name == single_pk ->
                " PRIMARY KEY"

              true ->
                ""
            end

          "#{q(new_name)} #{type}#{pk}#{if null?, do: "", else: " NOT NULL"}" <>
            if(default != nil, do: " DEFAULT #{default}", else: "")
        end)

      composite_pk =
        if length(pks) > 1 do
          names =
            pks |> Enum.sort() |> Enum.map(fn {_, name} -> q(Map.get(rename, name, name)) end)

          ["PRIMARY KEY (#{Enum.join(names, ", ")})"]
        else
          []
        end

      fk_defs =
        foreign_keys
        |> Enum.group_by(fn [id | _] -> id end)
        |> Enum.map(fn {_id, rows} ->
          [[_, _, ref_table, _, _, on_update, on_delete, _] | _] = rows
          from = Enum.map(rows, fn [_, _, _, from | _] -> q(Map.get(rename, from, from)) end)
          to = Enum.map(rows, fn [_, _, _, _, to | _] -> q(to) end)

          "FOREIGN KEY (#{Enum.join(from, ", ")}) REFERENCES #{q(ref_table)} (#{Enum.join(to, ", ")}) " <>
            "ON UPDATE #{on_update} ON DELETE #{on_delete}"
        end)
        |> Enum.reject(fn definition ->
          Enum.any?(remove, &String.contains?(definition, q(&1)))
        end)

      tmp = "#{table}__phoenix_mountable_rebuild"
      old_names = Enum.map(kept, fn [_cid, name | _] -> q(name) end)
      new_names = Enum.map(kept, fn [_cid, name | _] -> q(Map.get(rename, name, name)) end)

      recreate =
        Enum.flat_map(others, fn [_type, _name, sql] ->
          if Enum.any?(remove, &String.contains?(sql, &1)),
            do: [],
            else: [rename_in_sql(sql, rename)]
        end) ++ Enum.map(autoindexes, &unique_index_sql(table, &1, rename, remove))

      repo.checkout(fn ->
        [[foreign_keys_on]] = SQL.query!(repo, "SELECT * FROM pragma_foreign_keys()").rows
        SQL.query!(repo, "PRAGMA foreign_keys = OFF")

        try do
          SQL.query!(repo, "BEGIN")

          SQL.query!(
            repo,
            "CREATE TABLE #{q(tmp)} (#{Enum.join(column_defs ++ composite_pk ++ fk_defs, ", ")})"
          )

          SQL.query!(
            repo,
            "INSERT INTO #{q(tmp)} (#{Enum.join(new_names, ", ")}) SELECT #{Enum.join(old_names, ", ")} FROM #{q(table)}"
          )

          SQL.query!(repo, "DROP TABLE #{q(table)}")
          SQL.query!(repo, "ALTER TABLE #{q(tmp)} RENAME TO #{q(table)}")
          Enum.each(Enum.reject(recreate, &is_nil/1), &SQL.query!(repo, &1))

          case SQL.query!(repo, "SELECT * FROM pragma_foreign_key_check(?)", [table]).rows do
            [] ->
              SQL.query!(repo, "COMMIT")

            rows ->
              raise ArgumentError, "rebuilding #{table} breaks foreign keys: #{inspect(rows)}"
          end
        rescue
          error ->
            SQL.query!(repo, "ROLLBACK")
            reraise error, __STACKTRACE__
        after
          if foreign_keys_on == 1, do: SQL.query!(repo, "PRAGMA foreign_keys = ON")
        end
      end)

      :ok
    end

    def rebuild_table(%Context{adapter: adapter}, _table, _changes) do
      raise ArgumentError,
            "rebuild_table/3 is for SQLite; on #{adapter}, use alter table with modify"
    end

    defp q(name), do: SQL.quote_name(:sqlite, name)

    # UNIQUE constraints declared in CREATE TABLE become automatic indexes,
    # which are not in sqlite_master with SQL; recreate them as unique indexes.
    defp autoindexes(repo, table) do
      SQL.query!(repo, "SELECT * FROM pragma_index_list(?)", [table]).rows
      |> Enum.filter(fn [_seq, _name, unique, origin | _] -> unique == 1 and origin == "u" end)
      |> Enum.map(fn [_seq, name | _] ->
        SQL.query!(repo, "SELECT * FROM pragma_index_info(?)", [name]).rows
        |> Enum.map(fn [_, _, column] -> column end)
      end)
    end

    defp unique_index_sql(table, columns, rename, remove) do
      if Enum.any?(columns, &(&1 in remove)) do
        nil
      else
        columns = Enum.map(columns, &Map.get(rename, &1, &1))
        name = "#{table}_#{Enum.join(columns, "_")}_unique"
        "CREATE UNIQUE INDEX #{q(name)} ON #{q(table)} (#{Enum.map_join(columns, ", ", &q/1)})"
      end
    end

    defp rename_in_sql(sql, rename) do
      Enum.reduce(rename, sql, fn {old, new}, sql ->
        sql
        |> String.replace(~s("#{old}"), ~s("#{new}"))
        |> String.replace(~r/\b#{Regex.escape(old)}\b/, new)
      end)
    end
  end
end
