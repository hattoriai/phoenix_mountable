if Code.ensure_loaded?(Phoenix.Router) do
  defmodule PhoenixMountable.Assets.Host do
    @moduledoc """
    The host's own asset pipeline.

    For libraries whose templates are styled by the host's Tailwind and whose
    JavaScript hooks the host registers. The library serves no files: its
    LiveViews usually render inside the host's root layout (`layout: :host`),
    which already loads the host's CSS and JavaScript.

        use PhoenixMountable,
          otp_app: :my_lib,
          macro: :my_lib,
          layout: :host,
          assets: {PhoenixMountable.Assets.Host, []}

    The host tells Tailwind to scan the library's templates. With Tailwind v4
    (Phoenix 1.8), in `assets/css/app.css`:

        @source "../../deps/my_lib";

    With Tailwind v3 (Phoenix 1.7), in `assets/tailwind.config.js`:

        content: [
          // ...
          "../deps/my_lib/**/*.*ex"
        ]

    `tailwind_source/2` returns the right line, and
    `PhoenixMountable.Igniter.add_tailwind_source/2` adds it for the host.

    ## Options

      * `:entries` — host asset paths to expose as entries, for a library that
        renders its own layout but loads the host's files, such as
        `[css: "/assets/css/app.css", js: "/assets/js/app.js"]`. URLs go
        through the endpoint's static path, so they carry the digest in
        production. Defaults to `[]`.
    """

    @behaviour PhoenixMountable.Assets

    @impl true
    def init(opts, _context) do
      entries =
        for {name, path} <- Keyword.get(opts, :entries, []) do
          kind = if Path.extname(path) == ".css", do: :css, else: :js
          %{name: name, path: path, kind: kind}
        end

      %{entries: entries}
    end

    @impl true
    def routes(_state, _definition), do: []

    @impl true
    def entries(%{entries: entries}, mount, _path) do
      for entry <- entries do
        url =
          case mount.endpoint do
            nil -> entry.path
            endpoint -> Phoenix.VerifiedRoutes.static_path(endpoint, entry.path)
          end

        %{name: entry.name, kind: entry.kind, url: url}
      end
    end

    @impl true
    # A tracked URL is stale when it is a digested build of one of the entries
    # (`app-<digest>.css`) other than the endpoint's current one.
    def stale?(%{entries: []}, _mount, _tracked), do: false
    def stale?(_state, %{endpoint: nil}, _tracked), do: false

    def stale?(%{entries: entries}, mount, tracked) do
      current = Enum.map(entries, &Phoenix.VerifiedRoutes.static_path(mount.endpoint, &1.path))
      current_paths = MapSet.new(current, &PhoenixMountable.Assets.url_path/1)

      Enum.any?(tracked, fn url ->
        path = PhoenixMountable.Assets.url_path(url)

        not MapSet.member?(current_paths, path) and
          Enum.any?(entries, fn entry -> digest_of?(path, entry.path) end)
      end)
    end

    defp digest_of?(path, entry_path) do
      ext = Path.extname(entry_path)
      base = String.trim_trailing(entry_path, ext)
      Regex.match?(~r"\A#{Regex.escape(base)}-[0-9a-f]{32}#{Regex.escape(ext)}\z", path)
    end

    @doc """
    The line that makes the host's Tailwind scan a library's templates.

    `version` is `:v4` (a CSS `@source` directive, relative to
    `assets/css/app.css`) or `:v3` (a `content` glob, relative to
    `assets/tailwind.config.js`).
    """
    @spec tailwind_source(atom, :v3 | :v4) :: String.t()
    def tailwind_source(otp_app, :v4), do: ~s(@source "../../deps/#{otp_app}";)
    def tailwind_source(otp_app, :v3), do: ~s("../deps/#{otp_app}/**/*.*ex")
  end
end
