if Code.ensure_loaded?(Ecto.Migration) do
  defmodule PhoenixMountable.Migration do
    @moduledoc ~S"""
    One version of a mountable library's schema.

        defmodule MyLib.Migrations.V4 do
          use PhoenixMountable.Migration,
            safety: :expand,
            description: "Archive items"

          def up(ctx) do
            alter table(:my_lib_items, prefix: ctx.prefix) do
              add :archived_at, :utc_datetime_usec
            end

            create_concurrently index(:my_lib_items, [:archived_at], prefix: ctx.prefix)
          end

          def down(ctx) do
            drop_if_exists index(:my_lib_items, [:archived_at], prefix: ctx.prefix)

            alter table(:my_lib_items, prefix: ctx.prefix) do
              remove :archived_at
            end
          end
        end

    The `Ecto.Migration` DSL is imported. `up/1` and `down/1` receive a
    `PhoenixMountable.Migrations.Context` with the repo, the adapter
    (`:postgres`, `:mysql` or `:sqlite`), the prefix, and the install options
    recorded when the library was first installed. Pattern match on the
    adapter for SQL that differs:

        def up(%{adapter: :sqlite} = ctx), do: ...
        def up(ctx), do: ...

    ## Options

      * `:safety` — `:expand` (the default) for additive changes that old code
        can run against: new tables, nullable columns, new indexes. `:contract`
        for changes that break code still reading the old schema: dropping or
        renaming tables and columns, changing types. A compile-time lint warns
        about destructive operations in an `:expand` version.
      * `:description` — a line about the change, written into the host's
        migration by the generator.
      * `:requires_backfills` — backfill modules that must have finished
        before this version runs (a contract version that drops the column a
        backfill copied from).
      * `:irreversible` — a reason why `down/1` cannot be written. The
        generator shows it, and rolling back past this version raises.
      * `:no_transaction` — adapters on which this version cannot run inside a
        transaction, up or down. Detected automatically for
        `create_concurrently/1`, `drop_concurrently/1` (Postgres) and
        `rebuild_table/3` (SQLite).
      * `:baseline` — marks the module as the library's baseline: the whole
        schema at the given version, for fresh installs.
    """

    alias PhoenixMountable.Migrations.Context

    @callback up(Context.t()) :: any
    @callback down(Context.t()) :: any
    @optional_callbacks down: 1

    @destructive [:remove, :remove_if_exists, :rename, :modify, :rebuild_table]

    @doc false
    defmacro __using__(opts) do
      quote do
        use Ecto.Migration
        import PhoenixMountable.Migration.Helpers
        @behaviour PhoenixMountable.Migration
        @phoenix_mountable_migration unquote(opts)
        @before_compile PhoenixMountable.Migration
      end
    end

    @doc false
    defmacro __before_compile__(env) do
      opts = Module.get_attribute(env.module, :phoenix_mountable_migration)

      bodies =
        for name <- [:up, :down],
            {:v1, :def, _meta, clauses} <- [Module.get_definition(env.module, {name, 1})],
            {_meta, _args, _guards, body} <- clauses,
            do: {name, body}

      safety = Keyword.get(opts, :safety, :expand)

      if safety not in [:expand, :contract] do
        raise ArgumentError, ":safety must be :expand or :contract, got: #{inspect(safety)}"
      end

      up_calls = for {:up, body} <- bodies, call <- calls(body), do: call
      calls = for {_name, body} <- bodies, call <- calls(body), do: call

      if safety == :expand and is_nil(opts[:baseline]) do
        for {name, line} <- up_calls, destructive?(name) do
          IO.warn(
            "#{inspect(env.module)} is marked safety: :expand but calls #{name}, which breaks code still " <>
              "using the old schema during a rolling deploy. Mark the version `safety: :contract`, or split " <>
              "the change into an expand version and a later contract version.",
            Macro.Env.stacktrace(%{env | line: line})
          )
        end
      end

      detected =
        Enum.flat_map(calls, fn
          {name, _} when name in [:create_concurrently, :drop_concurrently] -> [:postgres]
          {:rebuild_table, _} -> [:sqlite]
          _ -> []
        end)

      no_transaction = Enum.uniq(List.wrap(opts[:no_transaction]) ++ detected)

      info = %{
        safety: safety,
        description: opts[:description],
        requires_backfills: List.wrap(opts[:requires_backfills]),
        irreversible: opts[:irreversible],
        no_transaction: no_transaction,
        backfills?: Enum.any?(up_calls, &match?({:backfill, _}, &1)),
        baseline: opts[:baseline]
      }

      quote do
        @doc false
        def __phoenix_mountable_migration__, do: unquote(Macro.escape(info))
      end
    end

    defp destructive?(:drop_table), do: true
    defp destructive?(name), do: name in @destructive

    # The functions called in an up/1 body, with their line. `drop table(...)`
    # is reported as :drop_table, so dropping an index stays allowed.
    # The functions called in an up/1 or down/1 body, with their line. The
    # body comes expanded, so imported calls are remote calls. `drop table(...)`
    # is reported as :drop_table, so dropping an index stays allowed.
    defp calls(body) do
      {_, acc} =
        Macro.prewalk(body, [], fn node, acc ->
          case call(node) do
            {name, meta, [arg | _]} when name in [:drop, :drop_if_exists] ->
              name = if match?({:table, _, _}, call(arg)), do: :drop_table, else: name
              {node, [{name, meta[:line]} | acc]}

            {name, meta, _args} ->
              {node, [{name, meta[:line]} | acc]}

            nil ->
              {node, acc}
          end
        end)

      Enum.reverse(acc)
    end

    defp call({{:., _, [_module, name]}, meta, args}) when is_atom(name) and is_list(args),
      do: {name, meta, args}

    defp call({name, meta, args}) when is_atom(name) and is_list(args), do: {name, meta, args}
    defp call(_node), do: nil
  end

  defmodule PhoenixMountable.Migration.Helpers do
    @moduledoc """
    Functions imported in `PhoenixMountable.Migration` modules.
    """

    require Ecto.Migration

    alias PhoenixMountable.Migrations.{Context, SQL}

    @doc """
    Creates an index without locking writes on Postgres (`CREATE INDEX
    CONCURRENTLY`), and normally on other databases.

    A version using it runs outside a transaction on Postgres. The generator
    adds `@disable_ddl_transaction true` and `@disable_migration_lock true` to
    the host's migration for it.
    """
    def create_concurrently(%Ecto.Migration.Index{} = index) do
      Ecto.Migration.create(%{index | concurrently: postgres?()})
    end

    @doc """
    Drops an index if it exists, without locking writes on Postgres. See
    `create_concurrently/1`.
    """
    def drop_concurrently(%Ecto.Migration.Index{} = index) do
      if postgres?() do
        Ecto.Migration.drop_if_exists(%{index | concurrently: true})
      else
        drop_index_if_present(index)
      end
    end

    @doc """
    Creates an index unless one with its name exists, on every adapter.

    MySQL has no `CREATE INDEX IF NOT EXISTS`, so Ecto's `create_if_not_exists`
    raises there. This checks first, which keeps a version safe to run again
    after a partial failure (MySQL DDL is not transactional).
    """
    def create_index_if_missing(%Ecto.Migration.Index{} = index) do
      if not index_exists?(index), do: Ecto.Migration.create(index)
      :ok
    end

    @doc """
    Drops an index if one with its name exists, on every adapter.
    """
    def drop_index_if_present(%Ecto.Migration.Index{} = index) do
      if index_exists?(index), do: Ecto.Migration.drop(index)
      :ok
    end

    @doc """
    Adds a column to a table unless it exists, on every adapter (MySQL has no
    `ADD COLUMN IF NOT EXISTS`).

        add_column_if_missing(ctx, :my_lib_items, :slug, :string)
    """
    def add_column_if_missing(%Context{} = ctx, table, column, type, opts \\ []) do
      if not column_exists?(ctx, table, column) do
        Ecto.Migration.alter Ecto.Migration.table(table, prefix: ctx.prefix) do
          Ecto.Migration.add(column, type, opts)
        end
      end

      :ok
    end

    defp index_exists?(%Ecto.Migration.Index{} = index) do
      SQL.flush()
      repo = Ecto.Migration.repo()
      adapter = SQL.adapter(repo)

      prefix =
        if adapter != :sqlite,
          do: index.prefix || Ecto.Migration.prefix() || SQL.default_prefix(adapter)

      repo
      |> SQL.indexes(adapter, prefix, to_string(index.table))
      |> Enum.any?(&(&1.name == to_string(index.name)))
    end

    defp postgres?, do: SQL.adapter(Ecto.Migration.repo()) == :postgres

    @doc """
    Recreates a SQLite table with changed columns, keeping every column, index
    and trigger the host added. See `PhoenixMountable.Migrations.SQLite`.
    """
    defdelegate rebuild_table(ctx, table, changes), to: PhoenixMountable.Migrations.SQLite

    @doc """
    Registers or runs a backfill. See `PhoenixMountable.Backfill`.
    """
    defdelegate backfill(ctx, backfill), to: PhoenixMountable.Backfill, as: :__migration__

    @doc """
    Whether a table exists in the context's prefix.
    """
    def table_exists?(%Context{} = ctx, table) do
      SQL.flush()
      SQL.table_exists?(ctx.repo, ctx.adapter, ctx.prefix, to_string(table))
    end

    @doc """
    Whether a column exists in a table of the context's prefix.
    """
    def column_exists?(%Context{} = ctx, table, column) do
      SQL.flush()

      ctx.repo
      |> SQL.columns(ctx.adapter, ctx.prefix, to_string(table))
      |> Enum.any?(&(&1.name == to_string(column)))
    end

    @doc """
    The primary key options chosen at install time, for library tables:

        create table(:my_lib_items, primary_key: primary_key(ctx), prefix: ctx.prefix)

    `[name: :id, type: :binary_id]` when installed with `primary_key:
    :binary_id`, otherwise `[name: :id, type: :bigserial]`.
    """
    def primary_key(%Context{} = ctx),
      do: [name: :id, type: if(binary_id?(ctx), do: :binary_id, else: :bigserial)]

    @doc """
    The column type of a foreign key to a library table: `:binary_id` or
    `:bigint`, matching `primary_key/1`.

        add :item_id, references(:my_lib_items, type: key_type(ctx), prefix: ctx.prefix)
    """
    def key_type(%Context{} = ctx), do: if(binary_id?(ctx), do: :binary_id, else: :bigint)

    defp binary_id?(%Context{install_options: options}),
      do: Map.get(options, "primary_key") == "binary_id"
  end
end
