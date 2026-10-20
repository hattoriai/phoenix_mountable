if Code.ensure_loaded?(Phoenix.Router) do
  defmodule PhoenixMountable.Assets do
    @moduledoc """
    How a mountable library's CSS and JavaScript reach the browser.

    A library picks a strategy with the `:assets` option of `use PhoenixMountable`:

        use PhoenixMountable,
          otp_app: :my_lib,
          macro: :my_lib,
          assets: {PhoenixMountable.Assets.Embedded, css: "priv/static/app.css", js: "priv/static/app.js"}

    Strategies shipped with PhoenixMountable:

      * `PhoenixMountable.Assets.Embedded` — bundles read and gzipped at compile
        time and served from memory under content-hashed URLs, the approach of
        Phoenix LiveDashboard, Oban Web and Lotus Web.
      * `PhoenixMountable.Assets.Static` — a directory of files (a Vite, esbuild
        or React build, with an optional manifest) served under the mount.
      * `PhoenixMountable.Assets.Host` — the host's own asset pipeline, for
        libraries styled by the host's Tailwind.

    A strategy is any module implementing this behaviour, so a library can bring
    its own.

    ## Entries

    Each strategy describes the files a page needs as *entries*: a name, a URL
    and a kind (`:css`, `:js` or `:module`). `PhoenixMountable.Layout` renders
    them as tags with the request's CSP nonces and `phx-track-static`, and
    `url/2` returns one entry's URL.

    ## Stale assets

    After a deploy, a browser can keep running the previous bundle. When a
    library LiveView connects, PhoenixMountable asks the strategy whether any of
    the URLs the page tracks (`phx-track-static`) belongs to a previous build,
    and reloads the page if so. Phoenix's own `static_changed?/1` cannot see this
    because it only knows the host's static manifest.
    """

    alias PhoenixMountable.Mount

    @typedoc "An asset of a page."
    @type entry :: %{name: atom, url: String.t(), kind: :css | :js | :module}

    @typedoc "A route a strategy adds under the mount path."
    @type route :: %{
            required(:verb) => atom,
            required(:path) => String.t(),
            required(:plug) => module,
            required(:plug_opts) => term,
            optional(:opts) => keyword
          }

    @doc """
    Validates the strategy options and computes its state.

    Runs at compile time in the definition module. `context` has the
    definition `:module` and the library's `:otp_app`. The state is stored in
    every mount, so keep it small: file contents belong in `c:inject/2`.
    """
    @callback init(opts :: keyword, context :: %{module: module, otp_app: atom}) :: term

    @doc """
    Code to inject into the definition module, such as embedded file contents.
    """
    @callback inject(state :: term, definition :: module) :: Macro.t()

    @doc """
    Routes to add under the mount path.
    """
    @callback routes(state :: term, definition :: module) :: [route]

    @doc """
    The entries of the strategy for a mount.

    `path_fun` turns a path relative to the mount into a full path, honouring
    the endpoint's script name and the mount's `:asset_host`.
    """
    @callback entries(state :: term, Mount.t(), path_fun :: (String.t() -> String.t())) :: [entry]

    @doc """
    Whether any of the tracked URLs was produced by a previous build.
    """
    @callback stale?(state :: term, Mount.t(), tracked :: [String.t()]) :: boolean

    @optional_callbacks inject: 2

    @doc false
    def __init__(nil, _module, _otp_app), do: {nil, nil}

    def __init__({strategy, opts}, module, otp_app) when is_atom(strategy) and is_list(opts) do
      Code.ensure_compiled!(strategy)
      state = strategy.init(opts, %{module: module, otp_app: otp_app})

      inject =
        if function_exported?(strategy, :inject, 2) do
          strategy.inject(state, module)
        end

      {{strategy, state}, inject}
    end

    def __init__(other, _module, _otp_app) do
      raise ArgumentError, "invalid :assets #{inspect(other)}, expected {strategy, options}"
    end

    @doc false
    def routes(nil, _definition), do: []
    def routes({strategy, state}, definition), do: strategy.routes(state, definition)

    @doc """
    The asset entries of a mount, in order.
    """
    @spec entries(Mount.t()) :: [entry]
    def entries(%Mount{assets: nil}), do: []

    def entries(%Mount{assets: {strategy, state}} = mount) do
      strategy.entries(state, mount, &path(mount, &1))
    end

    @doc """
    The URL of the asset entry `name`.

        <script src={PhoenixMountable.Assets.url(@mount, :js)} defer></script>
    """
    @spec url(Mount.t(), atom) :: String.t()
    def url(%Mount{} = mount, name) do
      case Enum.find(entries(mount), &(&1.name == name)) do
        %{url: url} -> url
        nil -> raise ArgumentError, "no asset #{inspect(name)} in #{inspect(mount.definition)}"
      end
    end

    @doc """
    Whether the page that tracks `tracked` URLs runs assets of a previous build.
    """
    @spec stale?(Mount.t(), [String.t()]) :: boolean
    def stale?(%Mount{assets: nil}, _tracked), do: false
    def stale?(_mount, []), do: false

    def stale?(%Mount{assets: {strategy, state}} = mount, tracked) when is_list(tracked) do
      tracked = Enum.filter(tracked, &is_binary/1)
      strategy.stale?(state, mount, tracked)
    end

    def stale?(%Mount{}, _tracked), do: false

    @doc false
    # The URL of an asset path relative to the mount, honouring the endpoint's
    # script name and the mount's :asset_host.
    def path(%Mount{} = mount, path) do
      relative = PhoenixMountable.Path.join(mount.path, path)

      full =
        case mount.endpoint do
          nil -> relative
          endpoint -> Phoenix.VerifiedRoutes.unverified_path(endpoint, mount.router, relative)
        end

      case mount.asset_host do
        nil -> full
        host -> String.trim_trailing(host, "/") <> full
      end
    end

    @doc false
    def url_path(url) do
      URI.parse(url).path || ""
    end

    @doc false
    # Reads one source at compile time. A source is a path relative to the
    # library root, or `{app, path}` relative to a dependency's directory.
    def read_source!({app, path}) when is_atom(app) and is_binary(path) do
      file = Path.join(Application.app_dir(app), path)
      {file, File.read!(file)}
    end

    def read_source!(path) when is_binary(path) do
      file = Path.expand(path, File.cwd!())

      case File.read(file) do
        {:ok, body} ->
          {file, body}

        {:error, reason} ->
          raise ArgumentError, "cannot read asset #{inspect(file)}: #{:file.format_error(reason)}"
      end
    end

    @doc false
    def content_type(name, file) do
      case {name, Path.extname(file)} do
        {_, ".css"} -> "text/css"
        {_, ext} when ext in [".js", ".mjs"] -> "text/javascript"
        {:css, _} -> "text/css"
        {:js, _} -> "text/javascript"
        {_, ".json"} -> "application/json"
        {_, ".svg"} -> "image/svg+xml"
        _ -> MIME.from_path(file)
      end
    end

    @doc false
    def kind("text/css"), do: :css
    def kind("text/javascript"), do: :js
    def kind(_), do: :other
  end
end
