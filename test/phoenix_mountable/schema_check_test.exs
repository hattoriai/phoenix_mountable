defmodule PhoenixMountable.SchemaCheckTest do
  use ExUnit.Case, async: false
  use PhoenixMountable.Test, host: SchemaLib.TestHost

  import ExUnit.CaptureIO

  alias PhoenixMountable.Migrations.Test

  @moduletag db: :sqlite

  setup_all do
    {:ok, _} = SchemaLib.TestHost.start()
    :ok
  end

  setup do
    repo = PhoenixMountable.TestRepo.SQLite
    Test.reset!(repo)
    clear_cache()
    {:ok, repo: repo}
  end

  defp clear_cache do
    for {{PhoenixMountable.SchemaCheck, _, _, _} = key, _} <- :persistent_term.get(),
        do: :persistent_term.erase(key)
  end

  test "a mount refuses to run until the host has migrated, naming the command", %{
    conn: conn,
    repo: repo
  } do
    error = assert_raise PhoenixMountable.Migrations.OutdatedError, fn -> get(conn, "/schema") end
    assert error.message =~ "tiny_lib is not installed"
    assert error.message =~ "mix phoenix_mountable.gen.migration TinyLib.Migrations"

    Test.up(repo, TinyLib.Migrations, version: 1)

    error =
      assert_raise PhoenixMountable.Migrations.OutdatedError, fn ->
        get(build_conn(), "/schema")
      end

    assert error.message =~
             "is at version 1, but this version of tiny_lib needs at least version 2"

    clear_cache()
    Test.up(repo, TinyLib.Migrations, version: 2)
    assert build_conn() |> get("/schema") |> text_response(200) == "ok"
  end

  describe "mix phoenix_mountable.check" do
    test "fails while a library is outdated and passes once migrated", %{repo: repo} do
      args = ["-r", inspect(repo), "--only", "TinyLib.Migrations"]

      assert catch_exit(capture_io(:stderr, fn -> Mix.Tasks.PhoenixMountable.Check.run(args) end)) ==
               {:shutdown, 1}

      Test.up(repo, TinyLib.Migrations)
      Mix.Task.reenable("phoenix_mountable.check")
      assert capture_io(fn -> Mix.Tasks.PhoenixMountable.Check.run(args) end) =~ "up to date"
    end

    test "finds every migrations module of the loaded applications" do
      assert TinyLib.Migrations in Mix.Tasks.PhoenixMountable.Check.discover()
      assert SampleLib.Migrations in Mix.Tasks.PhoenixMountable.Check.discover()
    end
  end

  describe "mix phoenix_mountable.backfill" do
    test "runs deferred backfills", %{repo: repo} do
      Test.up(repo, SampleLib.Migrations, version: 1)

      PhoenixMountable.Migrations.SQL.query!(
        repo,
        "INSERT INTO sample_items (title) VALUES ('Q')"
      )

      Test.up(repo, SampleLib.Migrations, version: 2, backfills: :deferred)

      output =
        capture_io(fn ->
          Mix.Tasks.PhoenixMountable.Backfill.run(["SampleLib.Migrations", "-r", inspect(repo)])
        end)

      assert output =~ "backfills done"

      assert PhoenixMountable.Migrations.SQL.query!(repo, "SELECT slug FROM sample_items").rows ==
               [["q"]]
    end
  end
end
