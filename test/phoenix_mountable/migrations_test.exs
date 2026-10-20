for db <- [:postgres, :mysql, :sqlite] do
  defmodule Module.concat(
              PhoenixMountable.MigrationsTest,
              db |> Atom.to_string() |> Macro.camelize()
            ) do
    use ExUnit.Case, async: false

    alias PhoenixMountable.Migrations.{SQL, Test}

    @db db
    @moduletag db: db
    @prefix "pm_kit"

    setup do
      repo = PhoenixMountable.TestDB.repo(@db)
      Test.reset!(repo, prefix: @prefix)
      {:ok, repo: repo, opts: [prefix: @prefix]}
    end

    defp prefix(repo), do: Test.prefix(repo, prefix: @prefix)

    defp insert_titles(repo, titles) do
      table = SQL.table(SQL.adapter(repo), prefix(repo), "sample_items")

      for title <- titles do
        [p] = SQL.params(SQL.adapter(repo), 1)
        SQL.query!(repo, "INSERT INTO #{table} (title) VALUES (#{p})", [title])
      end
    end

    defp slugs(repo) do
      table = SQL.table(SQL.adapter(repo), prefix(repo), "sample_items")
      SQL.query!(repo, "SELECT slug FROM #{table} ORDER BY title").rows |> List.flatten()
    end

    describe "the test kit" do
      test "passes for the sample library", %{repo: repo, opts: opts} do
        seed = fn
          version, ctx when version >= 1 -> insert_titles(ctx.repo, ["B", "A", "C"])
          _version, _ctx -> :ok
        end

        # Rows inserted at version 1 are backfilled by version 2; rows inserted
        # later are the app's to fill.
        verify = fn
          1, ctx -> assert slugs(ctx.repo) == ["a", "b", "c"]
          version, ctx when version >= 2 -> assert slugs(ctx.repo) == [nil, nil, nil]
          _version, _ctx -> :ok
        end

        assert :ok =
                 Test.run_suite(repo, SampleLib.Migrations, opts ++ [seed: seed, verify: verify])
      end

      test "the rerunnable check passes for idempotent versions", %{repo: repo, opts: opts} do
        assert :ok = Test.assert_rerunnable(repo, TinyLib.Migrations, opts)
      end

      test "the rerunnable check fails for versions that are not", %{repo: repo, opts: opts} do
        assert_raise ExUnit.AssertionError,
                     ~r/fails when run again after a partial failure/,
                     fn ->
                       Test.assert_rerunnable(repo, SampleLib.Migrations, opts)
                     end
      end
    end

    describe "tracking" do
      test "records the version and the install options", %{repo: repo, opts: opts} do
        Test.up(repo, SampleLib.Migrations, opts ++ [version: 2])

        assert SampleLib.Migrations.migrated_version(repo: repo, prefix: prefix(repo)) == 2

        assert {:ok, 2, %{"primary_key" => "id"}} =
                 SQL.fetch_row(repo, SQL.adapter(repo), prefix(repo), "sample_lib")

        Test.down(repo, SampleLib.Migrations, opts ++ [to: 0])
        assert SampleLib.Migrations.migrated_version(repo: repo, prefix: prefix(repo)) == 0
        assert :error = SQL.fetch_row(repo, SQL.adapter(repo), prefix(repo), "sample_lib")
      end

      test "install options apply to every later version", %{repo: repo, opts: opts} do
        Test.up(
          repo,
          SampleLib.Migrations,
          opts ++ [version: 1, install: [primary_key: :binary_id]]
        )

        Test.up(repo, SampleLib.Migrations, opts ++ [version: 4, install: [primary_key: :id]])

        assert {:ok, 4, %{"primary_key" => "binary_id"}} =
                 SQL.fetch_row(repo, SQL.adapter(repo), prefix(repo), "sample_lib")

        [id | _] = SQL.columns(repo, SQL.adapter(repo), prefix(repo), "sample_items")
        assert id.name == "id"
        assert id.type in ["uuid", "binary(16)", "TEXT", "UUID"]
      end

      test "down takes :to, not :version", %{repo: repo} do
        assert_raise ArgumentError, ~r/takes :to/, fn ->
          SampleLib.Migrations.down(version: 2, repo: repo)
        end
      end

      test "an irreversible version refuses to roll back", %{repo: repo, opts: opts} do
        Test.up(repo, TinyLib.Migrations, opts)

        error =
          assert_raise PhoenixMountable.MigrationError, fn ->
            Test.down(repo, TinyLib.Migrations, opts ++ [to: 0])
          end

        assert error.message =~ "cannot roll tiny_lib back past version 2"
        assert error.message =~ "history is discarded"
      end
    end

    describe "legacy installs" do
      test "an install made before PhoenixMountable is adopted at its detected version", %{
        repo: repo,
        opts: opts
      } do
        Test.run(
          repo,
          fn ->
            SampleLib.Migrations.V1.up(%PhoenixMountable.Migrations.Context{
              repo: repo,
              adapter: SQL.adapter(repo),
              prefix: prefix(repo)
            })
          end,
          prefix: prefix(repo)
        )

        insert_titles(repo, ["Old"])

        assert %{current: 1, tracked?: false} =
                 SampleLib.Migrations.status(repo: repo, prefix: prefix(repo))

        Test.up(repo, SampleLib.Migrations, opts ++ [version: 4])

        assert %{current: 4, tracked?: true} =
                 SampleLib.Migrations.status(repo: repo, prefix: prefix(repo))

        assert slugs(repo) == ["old"]
      end
    end

    describe "backfills" do
      test "run inline by default, in batches", %{repo: repo, opts: opts} do
        Test.up(repo, SampleLib.Migrations, opts ++ [version: 1])
        insert_titles(repo, ~w(E D C B A))
        Test.up(repo, SampleLib.Migrations, opts ++ [version: 2])

        assert slugs(repo) == ~w(a b c d e)

        assert [%{status: "done", processed: 5}] =
                 SampleLib.Migrations.status(repo: repo, prefix: prefix(repo)).backfills
      end

      test "deferred backfills block the contract version until they finish", %{
        repo: repo,
        opts: opts
      } do
        Test.up(repo, SampleLib.Migrations, opts ++ [version: 1])
        insert_titles(repo, ~w(Y X Z))
        Test.up(repo, SampleLib.Migrations, opts ++ [version: 3, backfills: :deferred])

        assert slugs(repo) == [nil, nil, nil]

        assert [%{status: "pending"}] =
                 SampleLib.Migrations.status(repo: repo, prefix: prefix(repo)).pending_backfills

        error =
          assert_raise PhoenixMountable.MigrationError, fn ->
            Test.up(repo, SampleLib.Migrations, opts ++ [version: 4])
          end

        assert error.message =~ "needs the backfill SampleLib.Backfills.Slugs to have finished"

        assert :ok = SampleLib.Migrations.run_backfills(repo: repo, prefix: prefix(repo))
        assert slugs(repo) == ~w(x y z)

        Test.up(repo, SampleLib.Migrations, opts ++ [version: 4])
        assert SampleLib.Migrations.migrated_version(repo: repo, prefix: prefix(repo)) == 4
      end

      test "the runner resumes from the recorded cursor", %{repo: repo, opts: opts} do
        Test.up(repo, SampleLib.Migrations, opts ++ [version: 1])
        insert_titles(repo, ~w(A B C D))
        Test.up(repo, SampleLib.Migrations, opts ++ [version: 2, backfills: :deferred])

        # A previous run processed the first batch (keys 1 and 2) and stopped.
        table = SQL.table(SQL.adapter(repo), prefix(repo), "sample_items")
        SQL.query!(repo, "UPDATE #{table} SET slug = 'done-before' WHERE title IN ('A', 'B')")

        SQL.put_backfill!(
          repo,
          SQL.adapter(repo),
          prefix(repo),
          "sample_lib",
          "SampleLib.Backfills.Slugs",
          %{
            status: "running",
            cursor: 2,
            processed: 2
          }
        )

        pid =
          start_supervised!(
            {PhoenixMountable.Backfill.Runner,
             migrations: SampleLib.Migrations, repo: repo, prefix: prefix(repo)}
          )

        _ = :sys.get_state(pid)

        assert slugs(repo) == ["done-before", "done-before", "c", "d"]

        assert [%{status: "done", processed: 4}] =
                 SampleLib.Migrations.status(repo: repo, prefix: prefix(repo)).backfills
      end
    end

    describe "check" do
      test "names the problem and the command", %{repo: repo, opts: opts} do
        p = prefix(repo)
        assert {:outdated, message} = SampleLib.Migrations.check(repo: repo, prefix: p)
        assert message =~ "sample_lib is not installed"
        assert message =~ "mix phoenix_mountable.gen.migration SampleLib.Migrations"

        Test.up(repo, SampleLib.Migrations, opts ++ [version: 2])
        assert {:outdated, message} = SampleLib.Migrations.check(repo: repo, prefix: p)

        assert message =~
                 "is at version 2, but this version of sample_lib needs at least version 3 (latest: 4)"

        Test.up(repo, SampleLib.Migrations, opts ++ [version: 3])
        assert {:pending, message} = SampleLib.Migrations.check(repo: repo, prefix: p)
        assert message =~ "version 4 is available"

        Test.up(repo, SampleLib.Migrations, opts ++ [version: 4])
        assert :ok = SampleLib.Migrations.check(repo: repo, prefix: p)
      end

      test "verify compares the tables with a snapshot, ignoring the host's additions", %{
        repo: repo,
        opts: opts
      } do
        Test.up(repo, SampleLib.Migrations, opts ++ [version: 4])
        snapshot = Test.schema(repo, opts)
        adapter = SQL.adapter(repo)
        table = SQL.table(adapter, prefix(repo), "sample_items")

        SQL.query!(repo, "ALTER TABLE #{table} ADD COLUMN host_note VARCHAR(10)")

        assert :ok =
                 SampleLib.Migrations.verify(repo: repo, prefix: prefix(repo), snapshot: snapshot)

        index =
          if adapter == :postgres,
            do: SQL.table(adapter, prefix(repo), "sample_items_slug_index"),
            else: "sample_items_slug_index"

        drop =
          if adapter == :mysql,
            do: "DROP INDEX sample_items_slug_index ON #{table}",
            else: "DROP INDEX #{index}"

        SQL.query!(repo, drop)

        assert {:error, [{:missing_index, "sample_items", "sample_items_slug_index"}]} =
                 SampleLib.Migrations.verify(repo: repo, prefix: prefix(repo), snapshot: snapshot)
      end
    end

    describe "telemetry" do
      test "reports each run", %{repo: repo, opts: opts} do
        parent = self()
        id = "migration-#{inspect(make_ref())}"
        on_exit(fn -> :telemetry.detach(id) end)

        :telemetry.attach(
          id,
          [:phoenix_mountable, :migration, :stop],
          fn _, measurements, metadata, _ ->
            send(parent, {:migrated, measurements, metadata})
          end,
          nil
        )

        Test.up(repo, SampleLib.Migrations, opts ++ [version: 2])

        assert_receive {:migrated, %{duration: _},
                        %{library: "sample_lib", direction: :up, from: 0, to: 2}}
      end
    end

    if db == :postgres do
      describe "transactions" do
        test "a concurrent index in a transactional migration fails with the attributes to add",
             %{repo: repo, opts: opts} do
          Test.up(repo, SampleLib.Migrations, opts ++ [version: 2])

          error =
            assert_raise PhoenixMountable.MigrationError, fn ->
              Test.run(repo, fn -> SampleLib.Migrations.up(version: 3) end, prefix: prefix(repo))
            end

          assert error.message =~ "@disable_ddl_transaction true"
          assert error.message =~ "@disable_migration_lock true"
        end
      end
    end

    if db == :sqlite do
      describe "rebuild_table/3" do
        test "keeps the host's triggers", %{repo: repo, opts: opts} do
          Test.up(repo, SampleLib.Migrations, opts ++ [version: 3])

          SQL.query!(repo, """
          CREATE TRIGGER sample_items_touch AFTER INSERT ON sample_items
          BEGIN UPDATE sample_items SET slug = 'trigger' WHERE id = NEW.id; END
          """)

          Test.up(repo, SampleLib.Migrations, opts ++ [version: 4])
          insert_titles(repo, ["T"])

          assert slugs(repo) == ["trigger"]
        end

        test "refuses tables with CHECK constraints", %{repo: repo} do
          SQL.query!(
            repo,
            "CREATE TABLE checked (id INTEGER PRIMARY KEY, n INTEGER CHECK (n > 0))"
          )

          ctx = %PhoenixMountable.Migrations.Context{repo: repo, adapter: :sqlite}

          assert_raise ArgumentError, ~r/CHECK constraints/, fn ->
            PhoenixMountable.Migrations.SQLite.rebuild_table(ctx, :checked,
              modify: [n: [null: false]]
            )
          end
        end
      end
    end
  end
end
