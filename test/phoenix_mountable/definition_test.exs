defmodule PhoenixMountable.DefinitionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  defp unique, do: "M#{System.unique_integer([:positive])}"

  defp compile_router(mount_call) do
    name = unique()

    Code.compile_string("""
    defmodule #{name}.Router do
      use Phoenix.Router
      import SampleLib.Router

      scope "/" do
        #{mount_call}
      end
    end
    """)

    Module.concat(name, Router)
  end

  describe "host options" do
    test "an unknown option fails the host's compile with the valid ones" do
      error =
        assert_raise ArgumentError, fn -> compile_router(~s(sample_lib "/s", greting: "hi")) end

      assert error.message =~ "invalid options for sample_lib/2 (SampleLib.Router)"
      assert error.message =~ "unknown options [:greting]"
      assert error.message =~ ":greeting"
      assert error.message =~ ":csp_nonce_assign_key"
    end

    test "a value of the wrong type fails with the expected type" do
      error =
        assert_raise ArgumentError, fn -> compile_router(~s(sample_lib "/s", theme: :pink)) end

      assert error.message =~ "invalid value for :theme option"
      assert error.message =~ "[:light, :dark, :system]"

      error =
        assert_raise ArgumentError, fn ->
          compile_router(~s(sample_lib "/s", transport: "carrier pigeon"))
        end

      assert error.message =~ "invalid value for :transport option"
    end

    test "normalize_options/1 can reject a combination" do
      error =
        assert_raise ArgumentError, fn -> compile_router(~s(sample_lib "/s", theme: :system)) end

      assert error.message =~ "theme :system is not one of [:light, :dark]"
    end

    test "the same mount name twice fails" do
      error =
        assert_raise ArgumentError, fn ->
          compile_router(~s(sample_lib "/a"\n sample_lib "/b"))
        end

      assert error.message =~ "mounted twice"
      assert error.message =~ "Pass a different :as"
    end

    test "verified options are recorded for the after-verify check" do
      assert [
               {:sample_lib, :resolver, SampleLib.TestResolver, {:behaviour, SampleLib.Resolver}}
               | _
             ] =
               SampleLib.TestHost.Router.__phoenix_mountable_verify__()

      assert :ok = PhoenixMountable.Router.__verify__(SampleLib.TestHost.Router)
    end

    test "a verified option that names a missing module fails" do
      error =
        assert_raise ArgumentError, fn ->
          PhoenixMountable.Router.__verify_entries__(Host, [
            {:lib, :resolver, Does.Not.Exist, :module}
          ])
        end

      assert error.message =~
               "the :resolver option of mount :lib in Host names a module that does not exist"

      assert error.message =~ "Does.Not.Exist"
    end

    test "a verified option must implement the behaviour" do
      error =
        assert_raise ArgumentError, fn ->
          PhoenixMountable.Router.__verify_entries__(Host, [
            {:lib, :resolver, SampleLib.Counter, {:behaviour, SampleLib.Resolver}}
          ])
        end

      assert error.message =~ "must implement the SampleLib.Resolver behaviour"
      assert error.message =~ "Add `@behaviour SampleLib.Resolver` to SampleLib.Counter"

      assert :ok =
               PhoenixMountable.Router.__verify_entries__(Host, [
                 {:lib, :resolver, SampleLib.Resolver, {:behaviour, SampleLib.Resolver}}
               ])
    end
  end

  describe "definition errors" do
    test "use options and routes are validated" do
      assert_raise ArgumentError, ~r/required :macro option not found/, fn ->
        Code.compile_string("defmodule #{unique()} do\n use PhoenixMountable, otp_app: :x\n end")
      end

      assert_raise ArgumentError, ~r/unknown options \[:lyout\]/, fn ->
        Code.compile_string(
          "defmodule #{unique()} do\n use PhoenixMountable, otp_app: :x, macro: :x, lyout: :host\n end"
        )
      end

      assert_raise ArgumentError, ~r/split by other routes/, fn ->
        Code.compile_string("""
        defmodule #{unique()} do
          use PhoenixMountable, otp_app: :x, macro: :x
          routes do
            live "/a", SampleLib.ItemLive
            get "/b", SampleLib.ExportController, :csv
            live "/c", SampleLib.ItemLive
          end
        end
        """)
      end

      assert_raise ArgumentError, ~r/Only live routes belong in a live_session/, fn ->
        Code.compile_string("""
        defmodule #{unique()} do
          use PhoenixMountable, otp_app: :x, macro: :x
          routes do
            live_session :s do
              get "/b", SampleLib.ExportController, :csv
            end
          end
        end
        """)
      end

      assert_raise ArgumentError, ~r/unknown pipeline :nope/, fn ->
        Code.compile_string("""
        defmodule #{unique()} do
          use PhoenixMountable, otp_app: :x, macro: :x
          routes do
            pipe_through :nope
            get "/b", SampleLib.ExportController, :csv
          end
        end
        """)
      end
    end
  end

  describe "~m verification" do
    test "warns about paths that match no route of the library" do
      name = unique()

      warnings =
        capture_io(:stderr, fn ->
          [{module, _}] =
            Code.compile_string("""
            defmodule #{name} do
              use PhoenixMountable.Path, mountable: SampleLib.Router
              def ok(id), do: ~m"/items/\#{id}"
              def root, do: ~m"/"
              def asset, do: ~m"/css-abc"
              def bad, do: ~m"/itemz/1"
            end
            """)

          PhoenixMountable.Path.__verify__(module)
        end)

      assert warnings =~ ~s(no route of SampleLib.Router matches ~m"/itemz/1")
      refute warnings =~ "/items/"
    end

    test "matches route patterns" do
      assert PhoenixMountable.Path.match_route?("/items/:__dynamic__", "/items/:id")
      assert PhoenixMountable.Path.match_route?("/items/42", "/items/:id")
      assert PhoenixMountable.Path.match_route?("/a/b/c", "/a/*rest")
      refute PhoenixMountable.Path.match_route?("/items", "/items/:id")
      refute PhoenixMountable.Path.match_route?("/other/1", "/items/:id")
    end
  end
end
