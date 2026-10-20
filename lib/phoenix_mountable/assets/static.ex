if Code.ensure_loaded?(Phoenix.Router) do
  defmodule PhoenixMountable.Assets.Static do
    @moduledoc """
    A directory of built files served under the mount.

    For libraries whose frontend is built with Vite, esbuild or another bundler
    into many files: code-split chunks, fonts, images, a React or Vue app.

        # esbuild or plain files
        assets: {PhoenixMountable.Assets.Static,
                 from: "priv/static/my_lib",
                 entries: [css: "app.css", js: "app.js"]}

        # Vite, with hashed file names from its manifest
        assets: {PhoenixMountable.Assets.Static,
                 from: "priv/static/my_lib",
                 manifest: ".vite/manifest.json",
                 entries: [app: {"src/main.tsx", :module}]}

    ## Options

      * `:from` — the directory, relative to the library root and inside its
        `priv` directory, or `{app, path}`. Resolved with
        `Application.app_dir/2` at runtime, so it works in releases.
      * `:at` — the path under the mount. Defaults to `"/assets"`.
      * `:manifest` — a Vite manifest, relative to `:from`. Entries are then
        manifest keys, and their CSS files are added as entries too.
      * `:entries` — the files a page loads: a name and a file (or manifest
        key), or `{file, kind}` with kind `:css`, `:js` or `:module`.

    The manifest and the entry files are read at compile time, so the library
    must be built before it compiles (as it is in a Hex package). Without a
    manifest, entry URLs carry `?vsn=<md5>`; with one, file names are already
    hashed. Both are cached as immutable.
    """

    @behaviour PhoenixMountable.Assets

    @impl true
    def init(opts, %{otp_app: otp_app}) do
      from =
        case Keyword.fetch(opts, :from) do
          {:ok, {app, path}} when is_atom(app) and is_binary(path) -> {app, path}
          {:ok, path} when is_binary(path) -> {otp_app, path}
          _ -> raise ArgumentError, "PhoenixMountable.Assets.Static needs :from"
        end

      dir = compile_dir(from)
      at = Keyword.get(opts, :at, "/assets")
      manifest = Keyword.get(opts, :manifest)
      entries = Keyword.get(opts, :entries, [])

      entries =
        if manifest do
          manifest_entries(dir, manifest, entries)
        else
          Enum.map(entries, &plain_entry(dir, &1))
        end

      %{from: from, at: at, entries: entries, files: Enum.map(entries, &Path.join(dir, &1.file))}
    end

    defp compile_dir({app, path}) do
      if Mix.Project.config()[:app] == app do
        Path.expand(path, File.cwd!())
      else
        Application.app_dir(app, path)
      end
    end

    defp plain_entry(dir, {name, spec}) do
      {file, kind} = file_and_kind(spec)
      full = Path.join(dir, file)

      vsn =
        case File.read(full) do
          {:ok, body} -> Base.encode16(:crypto.hash(:md5, body), case: :lower)
          {:error, _} -> raise ArgumentError, "asset entry #{inspect(name)} not found at #{full}"
        end

      %{name: name, file: file, kind: kind, query: "?vsn=" <> vsn}
    end

    defp file_and_kind({file, kind}) when kind in [:css, :js, :module], do: {file, kind}

    defp file_and_kind(file) when is_binary(file) do
      case Path.extname(file) do
        ".css" -> {file, :css}
        ".mjs" -> {file, :module}
        _ -> {file, :js}
      end
    end

    defp manifest_entries(dir, manifest, entries) do
      path = Path.join(dir, manifest)
      manifest = path |> File.read!() |> JSON.decode!()

      Enum.flat_map(entries, fn {name, spec} ->
        {key, kind} = file_and_kind(spec)

        chunk =
          Map.get(manifest, key) ||
            raise ArgumentError, "no #{inspect(key)} in the Vite manifest #{path}"

        css =
          chunk
          |> Map.get("css", [])
          |> Enum.with_index()
          |> Enum.map(fn {file, index} ->
            %{
              name: if(index == 0, do: :"#{name}_css", else: :"#{name}_css_#{index}"),
              file: file,
              kind: :css,
              query: ""
            }
          end)

        kind = if String.ends_with?(chunk["file"], ".css"), do: :css, else: kind
        [%{name: name, file: chunk["file"], kind: kind, query: ""} | css]
      end)
    end

    @impl true
    def inject(%{files: files}, _definition) do
      quote do
        for file <- unquote(files), do: @external_resource(file)
      end
    end

    @impl true
    def routes(%{from: from, at: at}, _definition) do
      [
        %{
          verb: :get,
          path: PhoenixMountable.Path.join(at, "/*path"),
          plug: PhoenixMountable.Assets.Static.Plug,
          plug_opts: from,
          opts: [as: :asset]
        }
      ]
    end

    @impl true
    def entries(%{at: at, entries: entries}, _mount, path) do
      for entry <- entries do
        %{
          name: entry.name,
          kind: entry.kind,
          url: path.(PhoenixMountable.Path.join(at, "/" <> entry.file)) <> entry.query
        }
      end
    end

    @impl true
    def stale?(state, mount, tracked) do
      prefix = PhoenixMountable.Path.join(mount.path, state.at) <> "/"
      current = MapSet.new(state.entries, &(&1.file <> &1.query))

      Enum.any?(tracked, fn url ->
        %URI{path: path, query: query} = URI.parse(url)
        path = path || ""

        with true <- String.starts_with?(path, prefix),
             file = String.replace_prefix(path, prefix, ""),
             true <- Enum.any?(state.entries, &same_entry?(&1, file)) do
          not MapSet.member?(current, file <> if(query, do: "?" <> query, else: ""))
        else
          _ -> false
        end
      end)
    end

    # A tracked file belongs to an entry when it is that entry's file, or a
    # hashed build of it (same directory, same name before the hash).
    defp same_entry?(%{file: file}, tracked) do
      file == tracked or base_name(file) == base_name(tracked)
    end

    defp base_name(file) do
      dir = Path.dirname(file)
      name = file |> Path.basename() |> String.split(["-", "."]) |> hd()
      {dir, name}
    end
  end

  defmodule PhoenixMountable.Assets.Static.Plug do
    @moduledoc false
    # Plug.Static for the files under the route's `*path`. `from: {app, path}`
    # is resolved by Plug.Static at runtime, so releases find the files.
    @behaviour Plug

    import Plug.Conn

    @impl Plug
    def init({app, path}) do
      Plug.Static.init(
        at: "/",
        from: {app, path},
        gzip: true,
        brotli: true,
        cache_control_for_vsn_requests: "public, max-age=31536000, immutable"
      )
    end

    @impl Plug
    def call(%{path_params: %{"path" => segments}} = conn, opts) do
      conn =
        %{conn | path_info: segments}
        |> put_private(:plug_skip_csrf_protection, true)
        |> Plug.Static.call(opts)

      if conn.halted do
        conn
      else
        conn
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(404, "")
        |> halt()
      end
    end
  end
end
