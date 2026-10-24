if Code.ensure_loaded?(Igniter) do
  defmodule PhoenixMountable.Igniter do
    @moduledoc """
    Building blocks for a mountable library's Igniter installer.

    With them, a library's `mix my_lib.install` is a few lines:

        defmodule Mix.Tasks.MyLib.Install do
          use Igniter.Mix.Task

          @impl Igniter.Mix.Task
          def info(_argv, _parent), do: %Igniter.Mix.Task.Info{group: :my_lib}

          @impl Igniter.Mix.Task
          def igniter(igniter) do
            igniter
            |> PhoenixMountable.Igniter.mount(MyLib.Router, "/my_lib")
            |> PhoenixMountable.Igniter.gen_migration(MyLib.Migrations)
            |> PhoenixMountable.Igniter.add_tailwind_source(:my_lib)
          end
        end

    Hosts then run `mix igniter.install my_lib`. Every step is idempotent, so
    running the installer again changes nothing.

    For upgrades, call `gen_migration/3` from the library's Igniter upgrader:
    it writes the migration from the host's pinned version to the latest, or
    nothing when the host is up to date.
    """

    alias PhoenixMountable.Igniter.HostAssets
    alias PhoenixMountable.Migrations.Generator

    @doc """
    Mounts the library in the host's router: adds the mount call, with the
    import of the module that defines its macro, to the scope with the given
    path and pipelines (a new one when the router has none).

    It looks for the mount macro in the router, so running it again, or
    after the host moved the mount elsewhere, changes nothing. It adds the
    library to the `import_deps` of the host's `.formatter.exs`, so that the
    mount call keeps no parentheses when the library exports its macro:

        # the library's .formatter.exs
        [export: [locals_without_parens: [my_lib: 1, my_lib: 2]], ...]

    ## Options

      * `:router` — the router (asked, or the only one)
      * `:scope` — the path of the scope. Defaults to `"/"`. An admin goes
        in the host's admin scope: `scope: "/admin"`.
      * `:pipelines` — the pipelines of the scope. Defaults to `[:browser]`.
      * `:options` — mount options, as a string of Elixir code
        (`"resolver: MyApp.MyLibResolver"`). `{web}` in it is the host's web
        module (`"resolver: {web}.MyLibResolver"` gives
        `resolver: MyAppWeb.MyLibResolver`).
      * `:import` — the module to import for the macro. Defaults to the
        definition; a library with several definitions whose macros one
        module re-exports names that module.
    """
    @spec mount(Igniter.t(), module, String.t(), keyword) :: Igniter.t()
    def mount(igniter, definition, path, opts \\ []) do
      {igniter, router} =
        case Keyword.fetch(opts, :router) do
          {:ok, router} -> {igniter, router}
          :error -> Igniter.Libs.Phoenix.select_router(igniter)
        end

      macro = definition.__phoenix_mountable__(:macro)
      import = Keyword.get(opts, :import, definition)
      options = opts[:options] && web_module(igniter, opts[:options])
      call = "#{macro} #{inspect(path)}#{if options, do: ", " <> options, else: ""}"

      cond do
        router == nil ->
          Igniter.add_warning(igniter, """
          No Phoenix router found. Mount #{inspect(definition)} in your router:

              import #{inspect(import)}
              #{call}
          """)

        mounted?(igniter, router, macro) ->
          igniter

        true ->
          igniter
          # The host formats the mount call without parentheses, as the
          # library's .formatter.exs exports its macro.
          |> Igniter.Project.Formatter.import_dep(definition.__phoenix_mountable__(:otp_app))
          |> Igniter.Libs.Phoenix.append_to_scope(
            Keyword.get(opts, :scope, "/"),
            "import #{inspect(import)}\n#{call}",
            router: router,
            with_pipelines: Keyword.get(opts, :pipelines, [:browser])
          )
      end
    end

    # The mount macro called anywhere in the router.
    defp mounted?(igniter, router, macro) do
      case Igniter.Project.Module.find_module(igniter, router) do
        {:ok, {_igniter, source, _zipper}} ->
          Regex.match?(
            ~r/^\s*#{Regex.escape(Atom.to_string(macro))}[\s(]/m,
            Rewrite.Source.get(source, :content)
          )

        _ ->
          false
      end
    end

    defp web_module(igniter, code) do
      String.replace(code, "{web}", inspect(Igniter.Libs.Phoenix.web_module(igniter)))
    end

    @doc """
    Adds a LiveView hook of the library to the host's `assets/js/app.js`:
    `import { Hook } from "package"`, and `Hook` in the hooks of its
    `new LiveSocket(...)`. For a library whose components render in the
    host's own pages.

    When the hooks cannot be edited safely, it changes nothing and warns
    with the lines to add (see `PhoenixMountable.Igniter.HostAssets`). It
    tells the host when its esbuild config does not resolve packages from
    `deps/`.

    ## Options

      * `:path` — the file. Defaults to `"assets/js/app.js"`.
    """
    @spec add_hook(Igniter.t(), String.t(), String.t(), keyword) :: Igniter.t()
    def add_hook(igniter, hook, package, opts \\ []) do
      path = Keyword.get(opts, :path, "assets/js/app.js")

      if Igniter.exists?(igniter, path) do
        igniter
        |> Igniter.update_file(path, fn source ->
          case HostAssets.app_js(Rewrite.Source.get(source, :content), hook, package) do
            {:changed, new} -> Rewrite.Source.update(source, :content, new)
            :unchanged -> source
            {:manual, text} -> {:warning, text}
          end
        end)
        |> node_path_notice(package)
      else
        Igniter.add_warning(
          igniter,
          "#{path} not found. " <> HostAssets.app_js_manual(hook, package)
        )
      end
    end

    defp node_path_notice(igniter, package) do
      config =
        case File.read("config/config.exs") do
          {:ok, source} -> source
          {:error, _} -> ""
        end

      if HostAssets.node_path?(config) do
        igniter
      else
        Igniter.add_notice(igniter, """
        `import ... from "#{package}"` resolves through the NODE_PATH of your esbuild
        profile, which must have deps/. Add it in config/config.exs:

            env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
        """)
      end
    end

    @doc """
    Imports style sheets of the library in the host's `assets/css/app.css`,
    after its other `@import` lines: `files` are paths in the package (or
    names in its `priv/static`), each a string or `{path, :comment}` for an
    import left as a comment (a theme the host turns on).

        add_css_imports(igniter, :my_lib, ["my_lib.css", {"my_lib-dark.css", :comment}])

    The paths go through `deps/`, or the directory of a path dependency.

    ## Options

      * `:path` — the file. Defaults to `"assets/css/app.css"`.
    """
    @spec add_css_imports(
            Igniter.t(),
            atom,
            [String.t() | {String.t(), :import | :comment}],
            keyword
          ) ::
            Igniter.t()
    def add_css_imports(igniter, otp_app, files, opts \\ []) do
      path = Keyword.get(opts, :path, "assets/css/app.css")
      dir = HostAssets.relative(package_dir(otp_app), Path.dirname(path))

      imports =
        for file <- files do
          {file, kind} = if is_tuple(file), do: file, else: {file, :import}
          file = if String.contains?(file, "/"), do: file, else: "priv/static/" <> file
          {"#{dir}/#{file}", kind}
        end

      if Igniter.exists?(igniter, path) do
        Igniter.update_file(igniter, path, fn source ->
          case HostAssets.app_css(Rewrite.Source.get(source, :content), imports) do
            {:changed, new} -> Rewrite.Source.update(source, :content, new)
            :unchanged -> source
          end
        end)
      else
        Igniter.add_warning(igniter, "#{path} not found. " <> HostAssets.app_css_manual(imports))
      end
    end

    # Where the package is: in the deps directory, or the directory of a path
    # dependency, which Mix does not copy into deps/.
    defp package_dir(otp_app) do
      case Mix.Project.deps_paths()[otp_app] do
        nil -> Path.join(Mix.Project.deps_path(), Atom.to_string(otp_app))
        dir -> dir
      end
    end

    @doc """
    Writes the migration that installs the library, or upgrades it from the
    version the host's migrations pin, to the latest version.

    ## Options

      * `:repo` — the repo (asked, or the only one)
      * `:to` — the version. Defaults to the latest.
    """
    @spec gen_migration(Igniter.t(), module, keyword) :: Igniter.t()
    def gen_migration(igniter, migrations, opts \\ []) do
      {igniter, repo} =
        case Keyword.fetch(opts, :repo) do
          {:ok, repo} -> {igniter, repo}
          :error -> Igniter.Libs.Ecto.select_repo(igniter)
        end

      if repo == nil do
        Igniter.add_warning(
          igniter,
          "No Ecto repo found; run `mix phoenix_mountable.gen.migration #{inspect(migrations)}` once you have one."
        )
      else
        dir =
          Path.join([
            "priv",
            repo |> Module.split() |> List.last() |> Macro.underscore(),
            "migrations"
          ])

        to = Keyword.get(opts, :to, migrations.latest_version())

        case Generator.pinned_version(migrations, dir) do
          {:ok, from} when from >= to ->
            igniter

          {:ok, from} ->
            adapter = adapter(igniter, repo)
            {name, body} = Generator.render(migrations, {repo, adapter}, from, to)

            notes =
              Generator.notes(migrations, Generator.infos(migrations, adapter, from, to), adapter)

            igniter =
              Igniter.Libs.Ecto.gen_migration(igniter, repo, name, body: body, on_exists: :skip)

            Enum.reduce(notes, igniter, &Igniter.add_notice(&2, &1))

          {:unpinned, files} ->
            Igniter.add_warning(igniter, """
            #{Enum.join(files, ", ")} call #{inspect(migrations)}.up without a version, so the installed
            version cannot be read from the migrations. Run:

                mix phoenix_mountable.gen.migration #{inspect(migrations)}

            which asks the database.
            """)
        end
      end
    end

    # The repo's adapter, from the module when it is loaded, else from its
    # source in the project.
    defp adapter(igniter, repo) do
      if Code.ensure_loaded?(repo) do
        PhoenixMountable.Migrations.SQL.adapter(repo)
      else
        with {:ok, {_igniter, source, _zipper}} <-
               Igniter.Project.Module.find_module(igniter, repo),
             [_, name] <-
               Regex.run(
                 ~r/adapter:\s*Ecto\.Adapters\.(\w+)/,
                 Rewrite.Source.get(source, :content)
               ) do
          case name do
            "MyXQL" -> :mysql
            "SQLite3" -> :sqlite
            _ -> :postgres
          end
        else
          _ -> :postgres
        end
      end
    end

    @doc """
    Starts the processes of every mount at boot: adds
    `{PhoenixMountable.Supervisor, router: ..., endpoint: ...}` to the host's
    application, after its endpoint.
    """
    @spec add_supervisor(Igniter.t(), keyword) :: Igniter.t()
    def add_supervisor(igniter, opts \\ []) do
      {igniter, router} =
        case Keyword.fetch(opts, :router) do
          {:ok, router} -> {igniter, router}
          :error -> Igniter.Libs.Phoenix.select_router(igniter)
        end

      {igniter, endpoint} =
        case Keyword.fetch(opts, :endpoint) do
          {:ok, endpoint} -> {igniter, endpoint}
          :error -> Igniter.Libs.Phoenix.select_endpoint(igniter, router)
        end

      Igniter.Project.Application.add_new_child(
        igniter,
        {PhoenixMountable.Supervisor,
         {:code, quote(do: [router: unquote(router), endpoint: unquote(endpoint)])}},
        after: [endpoint]
      )
    end

    @doc """
    Keeps the body of the requests whose plug wants it as it was sent
    (`PhoenixMountable.RawBody`): adds `body_reader:
    {PhoenixMountable.RawBody, :read_body, [Router]}` to the `Plug.Parsers`
    of the host's endpoint.

    An endpoint whose `Plug.Parsers` has that reader already is left as it
    is. One with another reader is left as it is too, with a warning that
    says what to change: the host's reader may be there for a reason of its
    own.

    Options: `:router` and `:endpoint`, the host's by default.
    """
    @spec add_raw_body(Igniter.t(), keyword) :: Igniter.t()
    def add_raw_body(igniter, opts \\ []) do
      {igniter, router} =
        case Keyword.fetch(opts, :router) do
          {:ok, router} -> {igniter, router}
          :error -> Igniter.Libs.Phoenix.select_router(igniter)
        end

      {igniter, endpoint} =
        case Keyword.fetch(opts, :endpoint) do
          {:ok, endpoint} -> {igniter, endpoint}
          :error -> Igniter.Libs.Phoenix.select_endpoint(igniter, router)
        end

      reader = quote(do: {PhoenixMountable.RawBody, :read_body, [unquote(router)]})

      if is_nil(router) or is_nil(endpoint) do
        Igniter.add_warning(igniter, raw_body_by_hand(reader))
      else
        case Igniter.Project.Module.find_and_update_module(
               igniter,
               endpoint,
               &put_body_reader(&1, reader)
             ) do
          {:ok, igniter} -> igniter
          {:error, igniter} -> Igniter.add_warning(igniter, raw_body_by_hand(reader))
        end
      end
    end

    defp put_body_reader(zipper, reader) do
      alias Igniter.Code.Function

      case Function.move_to_function_call_in_current_scope(
             zipper,
             :plug,
             2,
             &Function.argument_equals?(&1, 0, Plug.Parsers)
           ) do
        {:ok, zipper} ->
          Function.update_nth_argument(zipper, 1, &put_or_keep_reader(&1, reader))

        :error ->
          {:warning, raw_body_by_hand(reader)}
      end
    end

    # The reader added to the parsers' options, unless they have one: this
    # one, left as it is, or the host's, left too, with a warning.
    defp put_or_keep_reader(options, reader) do
      case Igniter.Code.Keyword.get_key(options, :body_reader) do
        {:ok, existing} ->
          if existing |> Sourceror.Zipper.node() |> Sourceror.to_string() =~
               "PhoenixMountable.RawBody",
             do: {:ok, options},
             else: {:warning, raw_body_by_hand(reader)}

        :error ->
          Igniter.Code.Keyword.set_keyword_key(options, :body_reader, reader)
      end
    end

    defp raw_body_by_hand(reader) do
      """
      Give the Plug.Parsers of your endpoint this body reader, so the routes that
      check a signature of a request's body can read it as it was sent (see
      PhoenixMountable.RawBody):

          body_reader: #{Macro.to_string(reader)}

      If the endpoint has another reader, keep what it does in a plug of your own:
      only one can be given.
      """
    end

    @doc """
    Adds lines to the `html_helpers` of the host's web module, which every
    LiveView, component and template of the host gets: imports of the
    library's components, or of a module of the host's.

        add_html_helpers(igniter, ["import MyLib.Components"])
        add_html_helpers(igniter, ["import {app}.Permissions, only: [allowed?: 3]"])

    `{app}` is the host's module prefix (`MyApp`), `{web}` its web module
    (`MyAppWeb`). A line already there is not added again. When the web
    module has no `html_helpers` with a `quote` block, it changes nothing
    and warns with the lines to add.

    ## Options

      * `:web` — the web module. The host's by default.
    """
    @spec add_html_helpers(Igniter.t(), [String.t()], keyword) :: Igniter.t()
    def add_html_helpers(igniter, lines, opts \\ []) do
      web = Keyword.get_lazy(opts, :web, fn -> Igniter.Libs.Phoenix.web_module(igniter) end)
      app = Igniter.Project.Module.module_name_prefix(igniter)

      lines =
        Enum.map(lines, fn line ->
          line
          |> String.replace("{web}", inspect(web))
          |> String.replace("{app}", inspect(app))
          |> Code.format_string!()
          |> IO.iodata_to_binary()
        end)

      case Igniter.Project.Module.find_and_update_module(igniter, web, &put_helpers(&1, lines)) do
        {:ok, igniter} -> igniter
        {:error, igniter} -> Igniter.add_warning(igniter, helpers_by_hand(web, lines))
      end
    end

    defp put_helpers(zipper, lines) do
      alias Igniter.Code.{Common, Function}

      with {:ok, zipper} <- Function.move_to_defp(zipper, :html_helpers, 0),
           {:ok, zipper} <- Common.move_to_do_block(zipper),
           {:ok, zipper} <- into_quote(zipper) do
        body = zipper |> Sourceror.Zipper.node() |> Sourceror.to_string()
        missing = Enum.reject(lines, &String.contains?(body, &1))
        {:ok, Enum.reduce(missing, zipper, &add_last(&2, &1))}
      else
        _ -> {:warning, helpers_by_hand(nil, lines)}
      end
    end

    # The body of the function's quote: Igniter's move_to_do_block goes
    # through a body that is only the quote call; otherwise, into it.
    defp into_quote(zipper) do
      case Sourceror.Zipper.node(zipper) do
        {:quote, _, _} -> Igniter.Code.Common.move_to_do_block(zipper)
        {:__block__, _, [{:quote, _, _} | _]} -> :error
        _body -> {:ok, zipper}
      end
    end

    # After the last expression of the block.
    defp add_last(zipper, line) do
      zipper =
        case Sourceror.Zipper.node(zipper) do
          {:__block__, _, [_ | _]} -> zipper |> Sourceror.Zipper.down() |> rightmost()
          _ -> zipper
        end

      Igniter.Code.Common.add_code(zipper, line, placement: :after)
    end

    defp rightmost(zipper) do
      case Sourceror.Zipper.right(zipper) do
        nil -> zipper
        right -> rightmost(right)
      end
    end

    defp helpers_by_hand(web, lines) do
      """
      Add these lines to the quote block of html_helpers in your web module#{if web, do: " (#{inspect(web)})", else: ""}:

      #{Enum.map_join(lines, "\n", &("    " <> &1))}
      """
    end

    @doc """
    Makes the host's Tailwind scan the library's templates, for libraries
    styled by the host (`PhoenixMountable.Assets.Host`).

    Tailwind v4 (Phoenix 1.8): adds `@source "../../deps/<app>";` to
    `assets/css/app.css`. Tailwind v3 (Phoenix 1.7): adds
    `"../deps/<app>/**/*.*ex"` to the `content` of `assets/tailwind.config.js`.
    """
    @spec add_tailwind_source(Igniter.t(), atom) :: Igniter.t()
    def add_tailwind_source(igniter, otp_app) do
      css = "assets/css/app.css"
      config = "assets/tailwind.config.js"

      igniter =
        igniter |> Igniter.include_existing_file(css) |> Igniter.include_existing_file(config)

      cond do
        Igniter.exists?(igniter, css) and v4?(igniter, css) ->
          line = PhoenixMountable.Assets.Host.tailwind_source(otp_app, :v4)

          Igniter.update_file(igniter, css, fn source ->
            Rewrite.Source.update(source, :content, &add_v4_source(&1, line))
          end)

        Igniter.exists?(igniter, config) ->
          entry = PhoenixMountable.Assets.Host.tailwind_source(otp_app, :v3)

          Igniter.update_file(igniter, config, fn source ->
            Rewrite.Source.update(source, :content, &add_v3_content(&1, entry))
          end)

        true ->
          Igniter.add_notice(igniter, """
          Add the templates of #{otp_app} to your Tailwind sources. With Tailwind v4, in your CSS:

              #{PhoenixMountable.Assets.Host.tailwind_source(otp_app, :v4)}

          With Tailwind v3, in the content of tailwind.config.js:

              #{PhoenixMountable.Assets.Host.tailwind_source(otp_app, :v3)}
          """)
      end
    end

    defp v4?(igniter, css) do
      igniter.rewrite
      |> Rewrite.source!(css)
      |> Rewrite.Source.get(:content)
      |> String.contains?(~s(@import "tailwindcss"))
    end

    @doc false
    def add_v4_source(content, line) do
      cond do
        String.contains?(content, line) ->
          content

        Regex.match?(~r/^@source .*$/m, content) ->
          [last] = ~r/^@source .*$/m |> Regex.scan(content) |> List.last()
          String.replace(content, last, last <> "\n" <> line, global: false)

        true ->
          String.replace(content, ~r/^(@import "tailwindcss".*)$/m, "\\1\n" <> line,
            global: false
          )
      end
    end

    @doc false
    def add_v3_content(content, entry) do
      if String.contains?(content, entry) do
        content
      else
        String.replace(content, ~r/content:\s*\[/, "\\0\n    #{entry},", global: false)
      end
    end
  end
end
