if Code.ensure_loaded?(Ecto.Adapters.SQL) do
  defmodule PhoenixMountable.Backfill do
    @moduledoc ~S"""
    Data migrations, kept apart from schema changes and run in batches.

    Filling a new column on a table with millions of rows inside a migration
    holds locks for minutes and blocks the deploy. A backfill runs in batches
    instead: inline in the migration for small tables, or deferred to a process
    in the running app after the deploy, recording its progress after every
    batch so it resumes where it stopped after a crash or a restart.

        defmodule MyLib.Backfills.Slugs do
          use PhoenixMountable.Backfill,
            table: "my_lib_items",
            where: "slug IS NULL",
            set: "slug = LOWER(title)",
            batch_size: 1_000
        end

        # in a migration version
        def up(ctx) do
          alter table(:my_lib_items, prefix: ctx.prefix), do: add(:slug, :string)
          backfill(ctx, MyLib.Backfills.Slugs)
        end

    A later contract version that relies on the data declares
    `requires_backfills: [MyLib.Backfills.Slugs]`, and refuses to run until the
    backfill has finished.

    ## Options

      * `:mode` — `:inline` (the default) runs every batch inside the migration;
        `:deferred` records the backfill as pending, to be run by
        `PhoenixMountable.Backfill.Runner` (or `mix phoenix_mountable.backfill`).
        The host overrides it for a migration with
        `up(version: n, backfills: :deferred)`.
      * `:batch_size` — rows per batch. Defaults to `1_000`.
      * `:throttle` — milliseconds to wait between batches (deferred mode).
        Defaults to `0`.

    For the common case, an `UPDATE` keyed by an ordered column:

      * `:table` — the table.
      * `:key` — the column to paginate by. Defaults to `"id"`.
      * `:where` — an SQL condition selecting the rows still to fill.
      * `:set` — the SQL assignments.

    For anything else, implement `c:batch/3` instead.
    """

    alias PhoenixMountable.Migrations.{Context, SQL}

    @doc """
    Processes one batch after `cursor` (`nil` for the first), returning the
    cursor to continue from and the number of rows processed, or `:done`.

    Runs in a transaction together with the recording of the new cursor, so a
    batch is either fully done and recorded, or not at all.
    """
    @callback batch(Context.t(), cursor :: term, batch_size :: pos_integer) ::
                {:cont, term, non_neg_integer} | :done

    @doc false
    defmacro __using__(opts) do
      quote bind_quoted: [opts: opts] do
        @behaviour PhoenixMountable.Backfill
        @phoenix_mountable_backfill Map.new(opts)

        @doc false
        def __phoenix_mountable_backfill__, do: @phoenix_mountable_backfill

        if Map.has_key?(@phoenix_mountable_backfill, :table) do
          @impl PhoenixMountable.Backfill
          def batch(ctx, cursor, batch_size) do
            PhoenixMountable.Backfill.keyset_batch(
              ctx,
              @phoenix_mountable_backfill,
              cursor,
              batch_size
            )
          end
        end
      end
    end

    @doc false
    def config(backfill) do
      Map.merge(
        %{mode: :inline, batch_size: 1_000, throttle: 0},
        backfill.__phoenix_mountable_backfill__()
      )
    end

    @doc false
    def name(backfill), do: inspect(backfill)

    @doc false
    # Called from a migration version through `backfill/2`.
    def __migration__(%Context{} = ctx, backfill) do
      Code.ensure_loaded!(backfill)
      SQL.flush()
      config = config(backfill)
      mode = ctx.backfills || config.mode

      case mode do
        :deferred ->
          SQL.put_backfill!(ctx.repo, ctx.adapter, ctx.prefix, ctx.library, name(backfill), %{
            status: "pending"
          })

        :inline ->
          run(ctx, backfill, nil, 0, fn -> :ok end)

          SQL.put_backfill!(ctx.repo, ctx.adapter, ctx.prefix, ctx.library, name(backfill), %{
            status: "done"
          })
      end

      :ok
    end

    @doc false
    # Runs batches until done. `between` runs after each batch (throttling).
    def run(ctx, backfill, cursor, processed, between) do
      config = config(backfill)
      start = System.monotonic_time()

      result =
        if ctx.repo.in_transaction?() do
          step(ctx, backfill, cursor, processed, config)
        else
          {:ok, result} =
            ctx.repo.transaction(fn -> step(ctx, backfill, cursor, processed, config) end)

          result
        end

      case result do
        {:cont, cursor, processed, count} ->
          PhoenixMountable.Telemetry.execute(
            [:backfill, :batch],
            %{count: count, duration: System.monotonic_time() - start},
            %{library: ctx.library, backfill: backfill}
          )

          between.()
          run(ctx, backfill, cursor, processed, between)

        {:done, processed} ->
          PhoenixMountable.Telemetry.execute([:backfill, :stop], %{processed: processed}, %{
            library: ctx.library,
            backfill: backfill,
            status: :done
          })

          {:ok, processed}
      end
    end

    defp step(ctx, backfill, cursor, processed, config) do
      case backfill.batch(ctx, cursor, config.batch_size) do
        {:cont, cursor, count} ->
          processed = processed + count

          SQL.put_backfill!(ctx.repo, ctx.adapter, ctx.prefix, ctx.library, name(backfill), %{
            status: "running",
            cursor: cursor,
            processed: processed
          })

          {:cont, cursor, processed, count}

        :done ->
          SQL.put_backfill!(ctx.repo, ctx.adapter, ctx.prefix, ctx.library, name(backfill), %{
            status: "done",
            processed: processed,
            error: nil
          })

          {:done, processed}
      end
    end

    @doc false
    # Keyset pagination: select the next keys, then update exactly those rows.
    # Two statements, so it works on MySQL, which cannot LIMIT in a subquery.
    def keyset_batch(ctx, config, cursor, batch_size) do
      adapter = ctx.adapter
      table = SQL.table(adapter, ctx.prefix, config.table)
      key = SQL.quote_name(adapter, Map.get(config, :key, "id"))
      where = Map.get(config, :where, "1 = 1")

      {sql, params} =
        case cursor do
          nil ->
            {"SELECT #{key} FROM #{table} WHERE (#{where}) ORDER BY #{key} LIMIT #{batch_size}",
             []}

          cursor ->
            [p] = SQL.params(adapter, 1)

            {"SELECT #{key} FROM #{table} WHERE #{key} > #{p} AND (#{where}) ORDER BY #{key} LIMIT #{batch_size}",
             [cursor]}
        end

      case SQL.query!(ctx.repo, sql, params).rows |> List.flatten() do
        [] ->
          :done

        keys ->
          placeholders = SQL.params(adapter, length(keys)) |> Enum.join(", ")

          %{num_rows: count} =
            SQL.query!(
              ctx.repo,
              "UPDATE #{table} SET #{config.set} WHERE #{key} IN (#{placeholders})",
              keys
            )

          {:cont, List.last(keys), count}
      end
    end
  end

  defmodule PhoenixMountable.Backfill.Runner do
    @moduledoc """
    Runs a library's deferred backfills in the running app.

    Add it to the host's supervision tree after the repo, or to the library's
    `c:PhoenixMountable.children/1`:

        {PhoenixMountable.Backfill.Runner, migrations: MyLib.Migrations, repo: MyApp.Repo}

    On start it runs every pending backfill, batch by batch, recording the
    cursor after each batch, so a restart resumes where it stopped. On
    Postgres and MySQL it takes a database lock per backfill, so several nodes
    can run the runner and each backfill still runs once at a time. A batch
    that fails marks the backfill `failed` with the error; it is retried with
    a backoff.

    ## Options

      * `:migrations` (required), `:repo` (required), `:prefix`
      * `:retry_after` — milliseconds before retrying a failed backfill.
        Defaults to `30_000`.
    """

    use GenServer

    require Logger

    alias PhoenixMountable.Backfill
    alias PhoenixMountable.Migrations.{Context, SQL}

    @doc false
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @doc false
    def child_spec(opts) do
      %{
        id: {__MODULE__, opts[:migrations], opts[:prefix]},
        start: {__MODULE__, :start_link, [opts]}
      }
    end

    @impl true
    def init(opts) do
      {:ok, Map.new(opts) |> Map.put_new(:retry_after, 30_000), {:continue, :run}}
    end

    @impl true
    def handle_continue(:run, state) do
      case run_all(state.migrations, Map.to_list(state)) do
        :ok ->
          {:noreply, state}

        {:error, _} ->
          Process.send_after(self(), :retry, state.retry_after)
          {:noreply, state}
      end
    end

    @impl true
    def handle_info(:retry, state), do: {:noreply, state, {:continue, :run}}

    @doc """
    Runs every pending backfill of `migrations` to completion, in the caller.

    Returns `:ok`, or `{:error, failed}` with the backfills that failed.
    """
    @spec run_all(module, keyword) :: :ok | {:error, [{String.t(), term}]}
    def run_all(migrations, opts) do
      repo = Keyword.fetch!(opts, :repo)
      adapter = SQL.adapter(repo)

      prefix =
        if adapter == :sqlite,
          do: nil,
          else: Keyword.get(opts, :prefix) || SQL.default_prefix(adapter)

      library = migrations.__phoenix_mountable_migrations__(:library)
      throttle_override = Keyword.get(opts, :throttle)

      ctx = %Context{
        repo: repo,
        adapter: adapter,
        prefix: prefix,
        library: library,
        migrations: migrations,
        install_options:
          case SQL.fetch_row(repo, adapter, prefix, library) do
            {:ok, _, options} -> options
            :error -> %{}
          end
      }

      failed =
        for row <- SQL.backfill_rows(repo, adapter, prefix, library),
            row.status != "done",
            result = run_one(ctx, row, throttle_override),
            result != :ok,
            do: {row.name, result}

      if failed == [], do: :ok, else: {:error, failed}
    end

    defp run_one(ctx, row, throttle_override) do
      backfill = Module.concat([String.replace_prefix(row.name, "Elixir.", "")])

      if Code.ensure_loaded?(backfill) do
        throttle = throttle_override || Backfill.config(backfill).throttle

        with_lock(ctx, row.name, fn ->
          try do
            Backfill.run(ctx, backfill, row.cursor, row.processed, fn ->
              if throttle > 0, do: Process.sleep(throttle)
            end)

            :ok
          rescue
            error ->
              message = Exception.message(error)
              Logger.error("#{ctx.library}: backfill #{row.name} failed: #{message}")

              SQL.put_backfill!(ctx.repo, ctx.adapter, ctx.prefix, ctx.library, row.name, %{
                status: "failed",
                error: message
              })

              PhoenixMountable.Telemetry.execute(
                [:backfill, :stop],
                %{processed: row.processed},
                %{
                  library: ctx.library,
                  backfill: backfill,
                  status: :failed
                }
              )

              {:error, message}
          end
        end)
      else
        Logger.error("#{ctx.library}: backfill #{row.name} no longer exists in the library")
        {:error, :missing}
      end
    end

    # One runner per backfill across nodes: a session-level database lock held
    # on the connection that runs the batches.
    defp with_lock(%{adapter: :sqlite}, _name, fun), do: fun.()

    defp with_lock(ctx, name, fun) do
      key = "phoenix_mountable:#{ctx.library}:#{name}"

      ctx.repo.checkout(fn ->
        {acquire, release, params} =
          case ctx.adapter do
            :postgres ->
              {"SELECT pg_try_advisory_lock(hashtext($1))",
               "SELECT pg_advisory_unlock(hashtext($1))", [key]}

            :mysql ->
              {"SELECT GET_LOCK(?, 0)", "SELECT RELEASE_LOCK(?)", [String.slice(key, 0, 64)]}
          end

        case SQL.query!(ctx.repo, acquire, params).rows do
          [[locked]] when locked in [true, 1] ->
            try do
              fun.()
            after
              SQL.query!(ctx.repo, release, params)
            end

          _ ->
            :ok
        end
      end)
    end
  end
end
