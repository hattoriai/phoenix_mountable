if Code.ensure_loaded?(Phoenix.Router) do
  defmodule PhoenixMountable do
    @moduledoc """
    Build libraries that mount into a Phoenix app.

    A mountable library brings its own routes, LiveViews, controllers, assets
    and processes, and a host app mounts it with one line in its router:

        # in the host router
        import MyLib.Router

        scope "/" do
          pipe_through :browser
          my_lib "/my_lib", resolver: MyApp.MyLibResolver
        end

    The library declares everything in a *definition module*:

        defmodule MyLib.Router do
          use PhoenixMountable,
            otp_app: :my_lib,
            macro: :my_lib,
            layout: {MyLib.Layouts, :root},
            assets:
              {PhoenixMountable.Assets.Embedded,
               css: "priv/static/app.css",
               js: "priv/static/app.js",
               prepend: [:phoenix, :phoenix_html, :phoenix_live_view, :phoenix_mountable]}

          options resolver: [type: :atom, default: MyLib.Resolver, verify: {:behaviour, MyLib.Resolver}],
                  features: [type: {:list, :atom}, default: []]

          routes do
            get "/export", MyLib.ExportController, :csv

            live_session :public, host_on_mount: false do
              live "/share/:token", MyLib.ShareLive, :show
            end

            live_session :default, on_mount: [MyLib.Auth] do
              live "/", MyLib.HomeLive, :index
              live "/items/:id", MyLib.ItemLive, :show
            end
          end
        end

    The generated macro (`my_lib/2`) inserts ordinary Phoenix routes and live
    sessions into the host router: `mix phx.routes` lists them, the host's
    pipelines and scopes apply to them, and LiveView navigation works between
    them. LiveView is optional: a library of controllers and plugs mounts in a
    host without it.

    See `PhoenixMountable.Definition` for `options/1`, `routes/1` and
    `pipeline/2`, and `PhoenixMountable.Routes` for the routes.

    ## `use` options

    #{PhoenixMountable.Definition.use_docs()}

    ## Mount options

    Besides the options a library declares, every mount macro takes:

    #{NimbleOptions.docs(PhoenixMountable.Router.builtin_schema())}

    ## The mount

    Library code reads the current `PhoenixMountable.Mount` as `@mount` in
    LiveViews and templates, `conn.assigns.mount` in controllers and plugs, or
    with `PhoenixMountable.Mount.current/0` in the process handling them.
    """

    alias PhoenixMountable.Mount

    @doc """
    Adjusts or cross-validates the library's options after their validation.

    Receives the options with defaults (a keyword list) and returns them,
    possibly changed. Raise `ArgumentError` for an invalid combination. Runs
    when the host router compiles.
    """
    @callback normalize_options(keyword) :: keyword

    @doc """
    Extra values for the LiveView session of a library live session.

    Runs on the HTTP request that renders a library LiveView, with the host's
    conn, so it can resolve the current user from the host's assigns. Returns a
    map with string keys, merged into the session.
    """
    @callback session(conn :: Plug.Conn.t(), Mount.t(), session :: atom) :: map

    @doc """
    Child specs of the processes of one mount.

    They start under a supervisor of their own the first time the mount is
    used, or when the host starts `PhoenixMountable.Supervisor`. Each mount
    gets its own subtree, so two mounts never share state. Name the children
    with `via/2`.
    """
    @callback children(Mount.t()) :: [Supervisor.child_spec() | {module, term} | module]

    @doc """
    The Ecto repo holding the library's tables, for the `:schema` check.
    """
    @callback repo(Mount.t()) :: module | nil

    @optional_callbacks normalize_options: 1, session: 3, children: 1, repo: 1

    @doc false
    defmacro __using__(opts) do
      quote bind_quoted: [opts: opts] do
        @behaviour PhoenixMountable
        @phoenix_mountable_config PhoenixMountable.Definition.__config__(__MODULE__, opts)

        Module.register_attribute(__MODULE__, :phoenix_mountable_routes, accumulate: true)
        Module.register_attribute(__MODULE__, :phoenix_mountable_sessions, accumulate: true)
        Module.register_attribute(__MODULE__, :phoenix_mountable_pipelines, accumulate: true)

        import PhoenixMountable.Definition, only: [options: 1, routes: 1, pipeline: 2]

        @before_compile PhoenixMountable.Definition
      end
    end

    @doc """
    A `:via` name for a process of a mount, unique to the mount.

        def children(mount) do
          [{MyLib.Cache, name: PhoenixMountable.via(mount, :cache)}]
        end
    """
    @spec via(Mount.t(), term) :: {:via, Registry, {PhoenixMountable.Registry, term}}
    def via(%Mount{} = mount, name) do
      {:via, Registry, {PhoenixMountable.Registry, {Mount.key(mount), name}}}
    end

    @doc """
    The mounts a host router declares.
    """
    @spec mounts(module) :: [Mount.t()]
    def mounts(router) do
      if Code.ensure_loaded?(router) and
           function_exported?(router, :__phoenix_mountable_mounts__, 0) do
        router.__phoenix_mountable_mounts__()
      else
        []
      end
    end
  end
end
