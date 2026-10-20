if Code.ensure_loaded?(Phoenix.Router) do
  defmodule PhoenixMountable.Assets.Embedded do
    @moduledoc """
    Assets read, concatenated and gzipped at compile time, and served from
    memory under content-hashed URLs.

    This is the approach of Phoenix LiveDashboard, Oban Web and Lotus Web: the
    library ships prebuilt CSS and JavaScript in its Hex package, and the host
    needs no Node.js, no asset pipeline changes and no `Plug.Static` entry.

        assets: {PhoenixMountable.Assets.Embedded,
                 css: "priv/static/app.css",
                 js: "priv/static/app.js",
                 prepend: [:phoenix, :phoenix_html, :phoenix_live_view, :phoenix_mountable]}

    ## Options

      * `:at` — the path under the mount where assets are served. Defaults to
        `""`, so the CSS is at `<mount>/css-<md5>`.
      * `:prepend` — JavaScript to put before the `:js` entry, from the deps:
        `:phoenix`, `:phoenix_html`, `:phoenix_live_view` and
        `:phoenix_mountable` (the `PhoenixMountable` browser helper). Defaults
        to `[]`.
      * any other key is an entry: its name, and a source, a list of sources, or
        a keyword list with `:sources` and an explicit `:content_type`. A source
        is a path relative to the library root, or `{app, path}` relative to a
        dependency's directory.

    ## Responses

    Each URL names the MD5 of its content, so responses are cached for a year
    as immutable. A hash this build did not produce (an old node during a
    rolling deploy, a bookmarked URL) gets a 404 with `no-store`, rather than
    the wrong bundle cached for a year. JavaScript responses opt out of
    `Plug.CSRFProtection`'s cross-origin script check, since the bundle is
    public.
    """

    @behaviour PhoenixMountable.Assets

    @prepend_sources %{
      phoenix: {:phoenix, "priv/static/phoenix.js"},
      phoenix_html: {:phoenix_html, "priv/static/phoenix_html.js"},
      phoenix_live_view: {:phoenix_live_view, "priv/static/phoenix_live_view.js"},
      phoenix_mountable: {:phoenix_mountable, "priv/static/phoenix_mountable.js"}
    }

    @impl true
    def init(opts, _context) do
      {at, opts} = Keyword.pop(opts, :at, "")
      {prepend, entries} = Keyword.pop(opts, :prepend, [])

      for name <- prepend, not Map.has_key?(@prepend_sources, name) do
        raise ArgumentError,
              "unknown :prepend #{inspect(name)}, expected one of #{inspect(Map.keys(@prepend_sources))}"
      end

      if entries == [],
        do: raise(ArgumentError, "PhoenixMountable.Assets.Embedded needs at least one entry")

      entries =
        Enum.map(entries, fn {name, spec} ->
          {sources, content_type} = sources(spec)

          prepended =
            if name == :js,
              do: Enum.map(prepend, &{:prepend, Map.fetch!(@prepend_sources, &1)}),
              else: []

          sources = prepended ++ sources
          {files, body} = read_all!(sources)

          content_type =
            content_type || PhoenixMountable.Assets.content_type(name, List.last(files))

          %{
            name: name,
            sources: sources,
            files: files,
            hash: Base.encode16(:crypto.hash(:md5, body), case: :lower),
            content_type: content_type
          }
        end)

      %{at: at, entries: entries}
    end

    defp sources(spec) when is_binary(spec) or is_tuple(spec), do: {[spec], nil}

    defp sources(spec) when is_list(spec) do
      if Keyword.keyword?(spec) and Keyword.has_key?(spec, :sources) do
        {List.wrap(spec[:sources]), spec[:content_type]}
      else
        {spec, nil}
      end
    end

    defp read_all!(sources) do
      files =
        Enum.map(sources, fn
          {:prepend, source} -> read_prepended!(source)
          source -> PhoenixMountable.Assets.read_source!(source)
        end)

      {Enum.map(files, &elem(&1, 0)), Enum.map_join(files, "\n", &elem(&1, 1))}
    end

    defp read_prepended!({:phoenix_mountable, path}) do
      file = Path.expand(Path.join("../../..", path), __DIR__)
      {file, strip_source_map(File.read!(file))}
    end

    defp read_prepended!(source) do
      {file, body} = PhoenixMountable.Assets.read_source!(source)
      {file, strip_source_map(body)}
    end

    defp strip_source_map(body), do: String.replace(body, "//# sourceMappingURL=", "// ")

    @impl true
    def inject(%{entries: entries}, _definition) do
      # The bodies are compiled into the definition module only; mounts carry
      # the hashes. Reading again gives the same bytes, so the same hash.
      clauses =
        for entry <- entries do
          {_files, body} = read_all!(entry.sources)
          gzipped = :zlib.gzip(body)

          quote do
            for file <- unquote(entry.files), do: @external_resource(file)

            @doc false
            def __phoenix_mountable_asset__(unquote(entry.name), :identity), do: unquote(body)
            def __phoenix_mountable_asset__(unquote(entry.name), :gzip), do: unquote(gzipped)
          end
        end

      quote do
        (unquote_splicing(clauses))
      end
    end

    @impl true
    def routes(%{at: at, entries: entries}, definition) do
      for entry <- entries do
        %{
          verb: :get,
          path: PhoenixMountable.Path.join(at, "/#{entry.name}-:md5"),
          plug: PhoenixMountable.Assets.Embedded.Plug,
          plug_opts: {definition, entry.name, entry.hash, entry.content_type},
          opts: [as: :asset]
        }
      end
    end

    @impl true
    def entries(%{at: at, entries: entries}, _mount, path) do
      for entry <- entries do
        %{
          name: entry.name,
          url: path.(PhoenixMountable.Path.join(at, "/#{entry.name}-#{entry.hash}")),
          kind: PhoenixMountable.Assets.kind(entry.content_type)
        }
      end
    end

    @impl true
    def stale?(%{entries: entries}, mount, tracked) do
      Enum.any?(tracked, fn url ->
        path = PhoenixMountable.Assets.url_path(url)

        String.starts_with?(path, mount.path) and
          Enum.any?(entries, fn entry ->
            case Regex.run(
                   ~r"/#{Regex.escape(Atom.to_string(entry.name))}-([0-9a-f]{32})\z",
                   path
                 ) do
              [_, hash] -> hash != entry.hash
              nil -> false
            end
          end)
      end)
    end
  end

  defmodule PhoenixMountable.Assets.Embedded.Plug do
    @moduledoc false
    @behaviour Plug

    import Plug.Conn

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(%{path_params: %{"md5" => md5}} = conn, {definition, name, hash, content_type})
        when md5 == hash do
      encoding = if gzip_accepted?(conn), do: :gzip, else: :identity

      conn
      |> skip_csrf(content_type)
      |> put_resp_header("content-type", content_type)
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> put_resp_header("vary", "accept-encoding")
      |> put_encoding(encoding)
      |> send_resp(200, definition.__phoenix_mountable_asset__(name, encoding))
      |> halt()
    end

    def call(conn, _opts) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(404, "")
      |> halt()
    end

    # Plug.CSRFProtection rejects non-XHR GET responses with a JavaScript
    # content type as a cross-origin script read. The bundle is public.
    defp skip_csrf(conn, "text/javascript"),
      do: put_private(conn, :plug_skip_csrf_protection, true)

    defp skip_csrf(conn, _), do: conn

    defp gzip_accepted?(conn) do
      conn
      |> get_req_header("accept-encoding")
      |> Enum.any?(&String.contains?(String.downcase(&1), "gzip"))
    end

    defp put_encoding(conn, :gzip), do: put_resp_header(conn, "content-encoding", "gzip")
    defp put_encoding(conn, :identity), do: conn
  end
end
