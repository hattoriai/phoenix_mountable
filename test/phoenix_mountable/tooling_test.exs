defmodule PhoenixMountable.ToolingTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias PhoenixMountable.Migrations.Generator

  @tmp Path.expand("../../tmp/tooling", __DIR__)

  setup do
    File.rm_rf!(@tmp)
    File.mkdir_p!(@tmp)
    :ok
  end

  describe "pinned versions" do
    test "the highest pinned version among the host's migrations" do
      File.write!(
        Path.join(@tmp, "1_add.exs"),
        "defmodule A do\n def up, do: SampleLib.Migrations.up(version: 2)\nend"
      )

      File.write!(
        Path.join(@tmp, "2_up.exs"),
        "defmodule B do\n def up, do: SampleLib.Migrations.up(version: 3, prefix: \"x\")\nend"
      )

      File.write!(
        Path.join(@tmp, "3_other.exs"),
        "defmodule C do\n def up, do: Other.Migrations.up(version: 9)\nend"
      )

      assert Generator.pinned_version(SampleLib.Migrations, @tmp) == {:ok, 3}
      assert Generator.pinned_version(TinyLib.Migrations, @tmp) == {:ok, 0}
    end

    test "an unpinned call cannot be read from the files" do
      File.write!(
        Path.join(@tmp, "1_add.exs"),
        "defmodule A do\n def up, do: SampleLib.Migrations.up()\nend"
      )

      assert {:unpinned, [_]} = Generator.pinned_version(SampleLib.Migrations, @tmp)
    end
  end

  describe "rendering" do
    test "an install migration on Postgres disables the transaction for the concurrent index" do
      {name, body} =
        Generator.render(SampleLib.Migrations, PhoenixMountable.TestRepo.Postgres, 0, 4)

      assert name == "add_sample_lib"
      assert body =~ "#   v1 (expand) Items"
      assert body =~ "#   v4 (contract) Require titles, drop the legacy flag"
      assert body =~ "@disable_ddl_transaction true"
      assert body =~ "@disable_migration_lock true"
      assert body =~ "SampleLib.Migrations.up(version: 4)"
      assert body =~ "SampleLib.Migrations.down(to: 0)"
      assert body =~ "Version 4 is a contract change"
      assert body =~ "These versions include backfills"
    end

    test "an upgrade on MySQL needs no transaction attributes" do
      {name, body} = Generator.render(SampleLib.Migrations, PhoenixMountable.TestRepo.MySQL, 1, 2)
      assert name == "upgrade_sample_lib_to_v2"
      refute body =~ "@disable_ddl_transaction"
      assert body =~ "SampleLib.Migrations.down(to: 1)"
    end

    test "irreversible versions are called out" do
      {_name, body} = Generator.render(TinyLib.Migrations, PhoenixMountable.TestRepo.SQLite, 0, 2)
      assert body =~ "Version 2 cannot be rolled back: the notes' history is discarded"
    end
  end

  describe "mix phoenix_mountable.gen.migration" do
    test "writes the migration through ecto.gen.migration, then the upgrade" do
      args = [
        "SampleLib.Migrations",
        "-r",
        "PhoenixMountable.TestRepo.SQLite",
        "--migrations-path",
        @tmp
      ]

      capture_io(fn -> Mix.Tasks.PhoenixMountable.Gen.Migration.run(args ++ ["--to", "2"]) end)
      [install] = Path.wildcard(Path.join(@tmp, "*_add_sample_lib.exs"))
      source = File.read!(install)

      assert source =~ "defmodule PhoenixMountable.TestRepo.SQLite.Migrations.AddSampleLib do"
      assert source =~ "use Ecto.Migration"
      assert source =~ "SampleLib.Migrations.up(version: 2)"
      refute source =~ "def change"
      assert {:ok, _} = Code.string_to_quoted(source)

      Mix.Task.reenable("phoenix_mountable.gen.migration")
      Mix.Task.reenable("ecto.gen.migration")
      Process.sleep(1_000)
      output = capture_io(fn -> Mix.Tasks.PhoenixMountable.Gen.Migration.run(args) end)

      [upgrade] = Path.wildcard(Path.join(@tmp, "*_upgrade_sample_lib_to_v4.exs"))
      assert File.read!(upgrade) =~ "SampleLib.Migrations.down(to: 2)"
      assert File.read!(upgrade) =~ "@disable_ddl_transaction true"
      assert output =~ "contract change"

      Mix.Task.reenable("phoenix_mountable.gen.migration")

      assert capture_io(fn -> Mix.Tasks.PhoenixMountable.Gen.Migration.run(args) end) =~
               "already at version 4"
    end
  end

  describe "version modules" do
    test "warn about destructive operations in an expand version" do
      warnings =
        capture_io(:stderr, fn ->
          Code.compile_string("""
          defmodule PhoenixMountable.ToolingTest.Risky do
            use PhoenixMountable.Migration

            def up(ctx) do
              alter table(:items, prefix: ctx.prefix) do
                remove :title
              end

              drop index(:items, [:title])
            end
          end
          """)
        end)

      assert warnings =~ "is marked safety: :expand but calls remove"
      refute warnings =~ "calls drop"
    end

    test "detect versions that cannot run in a transaction" do
      assert SampleLib.Migrations.V3.__phoenix_mountable_migration__().no_transaction == [
               :postgres
             ]

      assert SampleLib.Migrations.V4.__phoenix_mountable_migration__().no_transaction == [:sqlite]
      assert SampleLib.Migrations.V2.__phoenix_mountable_migration__().no_transaction == [:sqlite]
      assert SampleLib.Migrations.V1.__phoenix_mountable_migration__().no_transaction == []
    end
  end

  describe "the Igniter installer" do
    import Igniter.Test

    @router """
    defmodule TestWeb.Router do
      use TestWeb, :router

      pipeline :browser do
        plug :accepts, ["html"]
        plug :fetch_session
      end

      scope "/", TestWeb do
        pipe_through :browser

        get "/", PageController, :home
      end
    end
    """

    @css """
    @import "tailwindcss" source(none);
    @source "../css";
    @source "../js";
    """

    defp phoenix_project do
      test_project(
        files: %{
          "lib/test_web/router.ex" => @router,
          "lib/test_web.ex" => "defmodule TestWeb do\nend\n",
          "lib/test/repo.ex" => """
          defmodule Test.Repo do
            use Ecto.Repo, otp_app: :test, adapter: Ecto.Adapters.Postgres
          end
          """,
          "assets/css/app.css" => @css
        }
      )
    end

    test "mounts the library, writes the migration and adds the Tailwind source" do
      igniter =
        phoenix_project()
        |> PhoenixMountable.Igniter.mount(SampleLib.Router, "/sample",
          options: ~s(greeting: "Hi")
        )
        |> PhoenixMountable.Igniter.gen_migration(SampleLib.Migrations, repo: Test.Repo)
        |> PhoenixMountable.Igniter.add_tailwind_source(:sample_lib)

      router =
        igniter.rewrite
        |> Rewrite.source!("lib/test_web/router.ex")
        |> Rewrite.Source.get(:content)

      assert router =~ "import SampleLib.Router"
      assert router =~ ~s|sample_lib("/sample", greeting: "Hi")|

      [{path, _}] =
        igniter.rewrite
        |> Rewrite.sources()
        |> Enum.map(&{&1.path, &1})
        |> Enum.filter(fn {path, _} -> path =~ "add_sample_lib" end)

      assert path =~ ~r"priv/repo/migrations/\d+_add_sample_lib.exs"

      css =
        igniter.rewrite |> Rewrite.source!("assets/css/app.css") |> Rewrite.Source.get(:content)

      assert css =~ ~s(@source "../js";\n@source "../../deps/sample_lib";)
    end

    test "is idempotent" do
      igniter =
        phoenix_project()
        |> PhoenixMountable.Igniter.mount(SampleLib.Router, "/sample")
        |> apply_igniter!()
        |> PhoenixMountable.Igniter.mount(SampleLib.Router, "/sample")

      assert_unchanged(igniter, "lib/test_web/router.ex")
    end

    test "adds the Tailwind v3 content entry" do
      config = """
      module.exports = {
        content: [
          "./js/**/*.js",
          "../lib/test_web.ex"
        ]
      }
      """

      updated = PhoenixMountable.Igniter.add_v3_content(config, ~s("../deps/sample_lib/**/*.*ex"))
      assert updated =~ ~s(content: [\n    "../deps/sample_lib/**/*.*ex",\n    "./js/**/*.js")

      assert PhoenixMountable.Igniter.add_v3_content(updated, ~s("../deps/sample_lib/**/*.*ex")) ==
               updated
    end
  end
end
