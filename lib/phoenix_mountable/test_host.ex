if Code.ensure_loaded?(Phoenix.Router) do
  defmodule PhoenixMountable.TestHost do
    @moduledoc """
    A host app for a mountable library's tests.

    A mountable library has no router or endpoint of its own, so its tests need
    a host to mount it in. Define one in `test/support`:

        defmodule MyLib.TestHost do
          use PhoenixMountable.TestHost,
            otp_app: :my_lib,
            mounts: [
              {MyLib.Router, "/my_lib", resolver: MyLib.TestResolver},
              {MyLib.Router, "/public", as: :public_lib}
            ]
        end

    start it in `test/test_helper.exs`:

        MyLib.TestHost.start()

    and use it from test cases:

        use PhoenixMountable.Test, host: MyLib.TestHost

        test "renders the home page", %{conn: conn} do
          {:ok, _view, html} = live(conn, "/my_lib")
          assert html =~ "Welcome"
        end

    This defines `MyLib.TestHost.Router` and `MyLib.TestHost.Endpoint`. The
    router's `:browser` pipeline fetches the session and flash and protects
    from forgery, like a generated Phoenix app. Mounts are declared in the
    order given, inside `scope "/"` with `pipe_through :browser`.

    ## Options

      * `:otp_app` — the application the endpoint reads its config from.
        Defaults to `:phoenix_mountable`.
      * `:mounts` — `{definition, path}` or `{definition, path, options}` tuples.
      * `:routes` — routes added to the host router after the mounts, for a
        host's own pages in tests, given as `(quote do ... end)`.
    """

    @doc false
    defmacro __using__(opts) do
      otp_app = Keyword.get(opts, :otp_app, :phoenix_mountable)
      mounts = Keyword.get(opts, :mounts, [])

      routes =
        case Keyword.get(opts, :routes) do
          {:quote, _, [[do: block]]} -> block
          other -> other
        end

      live? = Code.ensure_loaded?(Phoenix.LiveView)
      live_import = if live?, do: quote(do: import(Phoenix.LiveView.Router))
      live_flash = if live?, do: quote(do: plug(:fetch_live_flash))

      mount_calls =
        for mount <- mounts do
          {definition, path, mount_opts} =
            case mount do
              {:{}, _, [definition, path, mount_opts]} -> {definition, path, mount_opts}
              {definition, path} -> {definition, path, []}
            end

          definition = Macro.expand(definition, __CALLER__)
          Code.ensure_compiled!(definition)
          macro = definition.__phoenix_mountable__(:macro)

          quote do
            require unquote(definition)
            unquote(definition).unquote(macro)(unquote(path), unquote(mount_opts))
          end
        end

      quote do
        @otp_app unquote(otp_app)

        @config [
          url: [host: "localhost"],
          secret_key_base: String.duplicate("phoenix_mountable", 4),
          live_view: [signing_salt: "phoenix_mountable"],
          render_errors: [formats: [html: __MODULE__.ErrorHTML], layout: false],
          pubsub_server: __MODULE__.PubSub,
          check_origin: false,
          server: false
        ]

        @doc false
        def config, do: @config

        Application.put_env(@otp_app, __MODULE__.Endpoint, @config)

        defmodule ErrorHTML do
          @moduledoc false
          def render(template, _assigns),
            do: Phoenix.Controller.status_message_from_template(template)
        end

        defmodule Router do
          @moduledoc false
          use Phoenix.Router
          import Plug.Conn
          import Phoenix.Controller

          unquote(live_import)

          pipeline :browser do
            plug :accepts, ["html", "json"]
            plug :fetch_session

            unquote(live_flash)

            plug :protect_from_forgery
            plug :put_secure_browser_headers
          end

          scope "/" do
            pipe_through :browser
            unquote_splicing(mount_calls)
          end

          unquote(routes)
        end

        defmodule Endpoint do
          @moduledoc false
          use Phoenix.Endpoint, otp_app: unquote(otp_app)

          @session_options [store: :cookie, key: "_test_host", signing_salt: "phoenix_mountable"]

          if unquote(live?) do
            socket "/live", Phoenix.LiveView.Socket,
              websocket: [connect_info: [session: @session_options]],
              longpoll: [connect_info: [session: @session_options]]
          end

          plug Plug.Session, @session_options
          plug unquote(__CALLER__.module).Router
        end

        @doc """
        Starts the host: its PubSub and endpoint.
        """
        def start do
          Application.put_env(@otp_app, __MODULE__.Endpoint, config())

          children = [
            {Phoenix.PubSub, name: __MODULE__.PubSub},
            __MODULE__.Endpoint
          ]

          Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__.Supervisor)
        end
      end
    end
  end

  defmodule PhoenixMountable.Test do
    @moduledoc """
    Helpers for testing a mountable library.

        use PhoenixMountable.Test, host: MyLib.TestHost

    imports `Plug.Conn`, `Phoenix.ConnTest` and `Phoenix.LiveViewTest` (when
    available), sets `@endpoint` to the host's (see
    `PhoenixMountable.TestHost`), and adds a `conn` with an empty session to
    each test's context.

    `build_mount/3` builds a mount without a router, to test the library's
    options, `c:PhoenixMountable.normalize_options/1` and
    `c:PhoenixMountable.session/3`.
    """

    @doc """
    The mount a host would get with `my_lib path, opts`, validated and
    normalized like the mount macro does, but without a router.

        mount = PhoenixMountable.Test.build_mount(MyLib.Router, "/my_lib", features: [:beta])
        assert mount.options.features == [:beta]
    """
    @spec build_mount(module, String.t(), keyword) :: PhoenixMountable.Mount.t()
    def build_mount(definition, path \\ "/", opts \\ []) do
      PhoenixMountable.Router.build(nil, definition, path, opts)
    end

    @doc false
    defmacro __using__(opts) do
      host = Macro.expand(Keyword.fetch!(opts, :host), __CALLER__)

      live_import =
        if Code.ensure_loaded?(Phoenix.LiveViewTest), do: quote(do: import(Phoenix.LiveViewTest))

      quote do
        import Plug.Conn
        import Phoenix.ConnTest
        unquote(live_import)

        @endpoint unquote(host).Endpoint

        setup do
          {:ok, conn: Phoenix.ConnTest.build_conn() |> Plug.Test.init_test_session(%{})}
        end
      end
    end
  end
end
