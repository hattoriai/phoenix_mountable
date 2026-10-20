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

    alias PhoenixMountable.Migrations.Generator

    @doc """
    Mounts the library in the host's router, inside the scope piped through
    `:browser`.

    ## Options

      * `:router` — the router (asked, or the only one)
      * `:options` — mount options, as a string of Elixir code
        (`"resolver: MyApp.MyLibResolver"`)
      * `:pipelines` — the pipelines of the scope. Defaults to `[:browser]`.
    """
    @spec mount(Igniter.t(), module, String.t(), keyword) :: Igniter.t()
    def mount(igniter, definition, path, opts \\ []) do
      {igniter, router} =
        case Keyword.fetch(opts, :router) do
          {:ok, router} -> {igniter, router}
          :error -> Igniter.Libs.Phoenix.select_router(igniter)
        end

      if router == nil do
        Igniter.add_warning(igniter, """
        No Phoenix router found. Mount #{inspect(definition)} in your router:

            import #{inspect(definition)}
            #{definition.__phoenix_mountable__(:macro)} #{inspect(path)}
        """)
      else
        macro = definition.__phoenix_mountable__(:macro)

        call =
          "#{macro} #{inspect(path)}#{if opts[:options], do: ", " <> opts[:options], else: ""}"

        if mounted?(igniter, router, definition) do
          igniter
        else
          Igniter.Libs.Phoenix.append_to_scope(
            igniter,
            "/",
            "import #{inspect(definition)}\n#{call}",
            router: router,
            with_pipelines: Keyword.get(opts, :pipelines, [:browser])
          )
        end
      end
    end

    defp mounted?(igniter, router, definition) do
      case Igniter.Project.Module.find_module(igniter, router) do
        {:ok, {_igniter, source, _zipper}} ->
          String.contains?(Rewrite.Source.get(source, :content), "import #{inspect(definition)}")

        _ ->
          false
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
