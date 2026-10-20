defmodule Mix.Tasks.SampleLib.Install do
  use PhoenixMountable.Install,
    otp_app: :sample_lib,
    mounts: [{SampleLib.Router, "/sample", options: "resolver: {web}.SampleResolver"}],
    hook: {"Sample", "sample_lib"},
    css: ["sample.css"]

  @impl PhoenixMountable.Install
  def install(igniter) do
    Igniter.Project.Module.create_module(igniter, TestWeb.SampleResolver, "")
  end
end

defmodule PhoenixMountable.IgniterTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  alias PhoenixMountable.Igniter, as: PMIgniter

  @app_js """
  import "phoenix_html"
  import {Socket} from "phoenix"
  import {LiveSocket} from "phoenix_live_view"

  const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
  const liveSocket = new LiveSocket("/live", Socket, {
    params: {_csrf_token: csrfToken},
    hooks: {},
  })

  liveSocket.connect()
  """

  @app_css """
  @import "tailwindcss" source(none);
  @source "../css";
  """

  @router """
  defmodule TestWeb.Router do
    use Phoenix.Router

    pipeline :browser do
      plug :accepts, ["html"]
    end

    scope "/", TestWeb do
      pipe_through :browser
    end
  end
  """

  # A Phoenix app's files, written here rather than by phx_test_project/1,
  # which needs the phx_new archive.
  defp project(files \\ %{}) do
    test_project(
      files:
        Map.merge(
          %{
            ".formatter.exs" =>
              "[import_deps: [:phoenix], inputs: [\"{lib,test}/**/*.{ex,exs}\"]]\n",
            "lib/test_web/router.ex" => @router,
            "assets/js/app.js" => @app_js,
            "assets/css/app.css" => @app_css
          },
          files
        )
    )
  end

  defp router(igniter) do
    igniter
    |> apply_igniter!()
    |> Map.fetch!(:rewrite)
    |> Rewrite.source!("lib/test_web/router.ex")
    |> Rewrite.Source.get(:content)
  end

  defp file(igniter, path) do
    igniter
    |> apply_igniter!()
    |> Map.fetch!(:rewrite)
    |> Rewrite.source!(path)
    |> Rewrite.Source.get(:content)
  end

  describe "mount/4" do
    test "mounts in the browser scope, with the import" do
      source = project() |> PMIgniter.mount(SampleLib.Router, "/sample") |> router()

      assert source =~ "import SampleLib.Router"

      # Before apply_igniter!/1, which leaves out the dotfiles of the project.
      formatter =
        project()
        |> PMIgniter.mount(SampleLib.Router, "/sample")
        |> Map.fetch!(:rewrite)
        |> Rewrite.source!(".formatter.exs")
        |> Rewrite.Source.get(:content)

      assert formatter =~ ":phoenix_mountable"

      assert source =~ ~r/sample_lib[ (]"\/sample"/
    end

    test "mounts in another scope, with its pipelines, and the host's web module in the options" do
      source =
        project()
        |> PMIgniter.mount(SampleLib.Router, "/sample",
          scope: "/admin",
          pipelines: [:browser],
          options: "resolver: {web}.SampleResolver"
        )
        |> router()

      assert source =~
               ~r/scope "\/admin" do\s+pipe_through[ (]\[:browser\]\)?\s+import SampleLib.Router\s+sample_lib[ (]"\/sample", resolver: TestWeb.SampleResolver/
    end

    test "imports another module for a re-exported macro" do
      source =
        project()
        |> PMIgniter.mount(PlainLib.Router, "/plain", import: SampleLib.Router)
        |> router()

      assert source =~ "import SampleLib.Router\n"
      assert source =~ ~r/plain_lib[ (]"\/plain"/
      refute source =~ "import PlainLib.Router"
    end

    test "mounts once, even when the mount moved" do
      igniter =
        project()
        |> PMIgniter.mount(SampleLib.Router, "/sample")
        |> apply_igniter!()

      igniter
      |> PMIgniter.mount(SampleLib.Router, "/sample", scope: "/elsewhere")
      |> assert_unchanged()
    end
  end

  describe "add_hook/4" do
    test "imports the hook and adds it to the LiveSocket" do
      source = project() |> PMIgniter.add_hook("Sample", "sample_lib") |> file("assets/js/app.js")

      assert source =~ ~s(import { Sample } from "sample_lib")
      assert source =~ "hooks: {Sample}"
    end

    test "warns with the lines to add when it cannot edit the hooks" do
      project(%{
        "assets/js/app.js" => "const liveSocket = new LiveSocket(\"/live\", Socket, opts())\n"
      })
      |> PMIgniter.add_hook("Sample", "sample_lib")
      |> assert_has_warning(&(&1 =~ "Add Sample to the hooks of the LiveSocket"))
    end
  end

  describe "add_css_imports/4" do
    test "imports the style sheets of the package, a theme as a comment" do
      source =
        project()
        |> PMIgniter.add_css_imports(:sample_lib, ["sample.css", {"sample-dark.css", :comment}])
        |> file("assets/css/app.css")

      assert source =~ ~s(@import "../../deps/sample_lib/priv/static/sample.css";)
      assert source =~ ~s(/* @import "../../deps/sample_lib/priv/static/sample-dark.css"; */)
    end
  end

  describe "use PhoenixMountable.Install" do
    test "runs the declared steps, then the library's own" do
      igniter = Igniter.compose_task(project(), Mix.Tasks.SampleLib.Install, [])

      assert router(igniter) =~ ~r/sample_lib[ (]"\/sample", resolver: TestWeb.SampleResolver/
      assert file(igniter, "assets/js/app.js") =~ "hooks: {Sample}"
      assert file(igniter, "assets/css/app.css") =~ "sample_lib/priv/static/sample.css"
      assert_creates(igniter, "lib/test_web/sample_resolver.ex")
    end

    test "without Igniter, is a Mix task that says how to install, and names no Igniter module" do
      opts = [otp_app: :sample_lib, manual: "Mount it."]
      ast = PhoenixMountable.Install.__using__(opts, false)

      # The compiler expands every macro of the module, so a host without
      # Igniter compiles only if the task never names it.
      refute Macro.to_string(ast) =~ "Igniter"

      Code.compile_quoted(
        quote do
          defmodule Mix.Tasks.NoIgniter.Install do
            unquote(ast)
          end
        end
      )

      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

      Mix.Tasks.NoIgniter.Install.run([])
      assert_received {:mix_shell, :info, [text]}
      assert text =~ "mix igniter.install sample_lib"
      assert text =~ "Mount it."
    end

    test "has a short doc, and refuses unknown options" do
      assert Mix.Task.shortdoc(Mix.Tasks.SampleLib.Install) ==
               "Installs SampleLib in a Phoenix app"

      assert_raise ArgumentError, ~r/unknown options \[:mount\]/, fn ->
        PhoenixMountable.Install.__config__(otp_app: :x, mount: [])
      end
    end
  end
end
