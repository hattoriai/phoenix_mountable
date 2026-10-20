if Code.ensure_loaded?(Phoenix.Router) do
  defmodule PhoenixMountable.Definition do
    @moduledoc """
    The macros of a definition module: `options/1`, `routes/1` and `pipeline/2`.

    They are imported by `use PhoenixMountable`.

    ## Options

    `options/1` declares the options of the mount macro, as a
    [NimbleOptions](https://hexdocs.pm/nimble_options) schema. They are
    validated when the host router compiles, and documented in the mount
    macro's docs.

        options resolver: [
                  type: :atom,
                  default: MyLib.Resolver,
                  verify: {:behaviour, MyLib.Resolver},
                  doc: "The module that resolves the current user."
                ],
                features: [type: {:list, :atom}, default: []]

    Besides the NimbleOptions keys, an option can have `:verify`:
    `:module` checks that the value names an existing module, and
    `{:behaviour, mod}` also checks that it implements `mod` (or is `mod`).
    The check runs after the host router compiles: a module that uses the
    host's verified routes depends on the router, so checking it while the
    router compiles would deadlock.

    The values are in `mount.options`, a map with every declared option.

    ## Routes

    `routes/1` declares the library's routes with the macros of
    `PhoenixMountable.Routes`, relative to the mount path:

        routes do
          get "/export", MyLib.ExportController, :csv

          live_session :default, on_mount: [MyLib.Auth] do
            live "/", MyLib.HomeLive, :index
          end
        end

    ## Pipelines

    `pipeline/2` defines a pipeline of the library, like `Phoenix.Router.pipeline/2`,
    for its routes to `pipe_through`. It is compiled into a module plug, so the
    host needs nothing in its own router.

        pipeline :api do
          plug :accepts, ["json"]
        end
    """

    @use_schema [
      otp_app: [type: :atom, required: true, doc: "The library's OTP application."],
      macro: [type: :atom, required: true, doc: "The name of the mount macro defined for hosts."],
      as: [
        type: :atom,
        doc:
          "The default mount name, used to name live sessions and route helpers. Defaults to the " <>
            "macro name. Hosts pass `:as` to mount the library more than once."
      ],
      title: [
        type: :string,
        doc:
          "The page title of `PhoenixMountable.Layout`. Defaults to the camelized OTP application."
      ],
      layout: [
        type: {:or, [{:in, [:host]}, {:tuple, [:atom, :atom]}]},
        default: :host,
        doc:
          "The root layout of the library's pages: a `{module, function}` tuple for a document " <>
            "of its own (such as `{PhoenixMountable.Layout, :root}`), or `:host` to render inside the " <>
            "host's root layout."
      ],
      assets: [
        type: {:or, [nil, {:tuple, [:atom, :keyword_list]}]},
        default: nil,
        doc:
          "How the library's CSS and JavaScript reach the browser: `{strategy, options}`. See `PhoenixMountable.Assets`."
      ],
      on_mount: [
        type: {:list, {:or, [:atom, {:tuple, [:atom, :any]}]}},
        default: [],
        doc:
          "`on_mount` hooks of the library, run in every library live session after the host's."
      ],
      schema: [
        type: :atom,
        doc:
          "The library's `PhoenixMountable.Migrations` module. The first use of each mount then " <>
            "checks the host has run the library's migrations; see `c:PhoenixMountable.repo/1`."
      ],
      reload_on_stale: [
        type: :boolean,
        default: true,
        doc:
          "Reload a page whose library assets belong to a previous build when its LiveView reconnects."
      ],
      socket_path: [
        type: :string,
        default: "/live",
        doc: "The default of the `:socket_path` mount option."
      ],
      transport: [
        type: {:in, [:websocket, :longpoll]},
        default: :websocket,
        doc: "The default of the `:transport` mount option."
      ]
    ]

    @doc false
    def use_docs, do: NimbleOptions.docs(@use_schema)

    @doc false
    def __config__(module, opts) do
      opts =
        case NimbleOptions.validate(opts, @use_schema) do
          {:ok, opts} ->
            opts

          {:error, error} ->
            raise ArgumentError,
                  "invalid options for use PhoenixMountable in #{inspect(module)}: #{error.message}"
        end

      %{
        otp_app: opts[:otp_app],
        macro: opts[:macro],
        as: opts[:as] || opts[:macro],
        title: opts[:title] || Macro.camelize(Atom.to_string(opts[:otp_app])),
        layout: opts[:layout],
        assets: opts[:assets],
        on_mount: opts[:on_mount],
        schema: opts[:schema],
        reload_on_stale: opts[:reload_on_stale],
        socket_path: opts[:socket_path],
        transport: opts[:transport]
      }
    end

    @doc """
    Declares the options of the mount macro. See the module documentation.
    """
    defmacro options(schema) do
      quote do
        PhoenixMountable.Definition.__options__(__MODULE__, unquote(schema))
      end
    end

    @doc """
    Declares the routes of the library. See `PhoenixMountable.Routes`.
    """
    defmacro routes(do: block) do
      quote do
        if Module.get_attribute(__MODULE__, :phoenix_mountable_scope) do
          raise ArgumentError, "routes/1 can only be called once in #{inspect(__MODULE__)}"
        end

        @phoenix_mountable_scope [%{path: "", pipes: []}]
        @phoenix_mountable_current_session nil

        import PhoenixMountable.Routes
        unquote(block)
        import PhoenixMountable.Routes, only: []
      end
    end

    @doc """
    Defines a pipeline of the library. See the module documentation.
    """
    defmacro pipeline(name, do: block) when is_atom(name) do
      quote do
        module =
          Module.concat([__MODULE__, Pipelines, Macro.camelize(Atom.to_string(unquote(name)))])

        defmodule module do
          @moduledoc false
          use Plug.Builder
          import Plug.Conn
          import Phoenix.Controller

          unquote(block)
        end

        @phoenix_mountable_pipelines {unquote(name), module}
      end
    end

    @doc false
    def __options__(module, schema) do
      if Module.get_attribute(module, :phoenix_mountable_options) do
        raise ArgumentError, "options/1 can only be called once in #{inspect(module)}"
      end

      {schema, verify} =
        Enum.map_reduce(schema, [], fn {name, spec}, verify ->
          case Keyword.pop(spec, :verify) do
            {nil, spec} -> {{name, spec}, verify}
            {check, spec} -> {{name, spec}, [{name, verify_check!(module, name, check)} | verify]}
          end
        end)

      builtin = Keyword.keys(PhoenixMountable.Router.builtin_schema())

      for {name, _} <- schema, name in builtin do
        raise ArgumentError,
              "#{inspect(module)}: the option #{inspect(name)} is reserved by PhoenixMountable"
      end

      # Raises on an invalid schema, at the library's compile.
      NimbleOptions.new!(schema)

      Module.put_attribute(module, :phoenix_mountable_options, schema)
      Module.put_attribute(module, :phoenix_mountable_verify, Enum.reverse(verify))
    end

    defp verify_check!(_module, _name, :module), do: :module
    defp verify_check!(_module, _name, {:behaviour, mod} = check) when is_atom(mod), do: check

    defp verify_check!(module, name, other) do
      raise ArgumentError,
            "#{inspect(module)}: invalid :verify for option #{inspect(name)}, expected :module or " <>
              "{:behaviour, module}, got: #{inspect(other)}"
    end

    @doc false
    def __record_route__(module, route) do
      [scope | _] =
        Module.get_attribute(module, :phoenix_mountable_scope) ||
          raise ArgumentError, "routes can only be declared inside routes/1"

      session = Module.get_attribute(module, :phoenix_mountable_current_session)

      if route.kind == :live and not Code.ensure_loaded?(Phoenix.LiveView) do
        raise ArgumentError,
              "#{inspect(module)}: live #{inspect(route.path)} needs Phoenix LiveView. " <>
                "Add {:phoenix_live_view, \"~> 1.1\"} to the library's dependencies."
      end

      if route.kind != :live and session != nil do
        raise ArgumentError,
              "#{inspect(module)}: #{route.kind} #{inspect(route.path)} is inside a live_session. " <>
                "Only live routes belong in a live_session; declare it outside."
      end

      route =
        Map.merge(route, %{
          path: PhoenixMountable.Path.join(scope.path, route.path),
          pipes: scope.pipes,
          session: if(route.kind == :live, do: session || :default)
        })

      Module.put_attribute(module, :phoenix_mountable_routes, route)
    end

    @doc false
    def __push_scope__(module, path, opts) do
      [top | _] = stack = Module.get_attribute(module, :phoenix_mountable_scope)
      pipes = top.pipes ++ List.wrap(Keyword.get(opts, :pipe_through, []))
      scope = %{path: PhoenixMountable.Path.join(top.path, path), pipes: pipes}
      Module.put_attribute(module, :phoenix_mountable_scope, [scope | stack])
    end

    @doc false
    def __pop_scope__(module) do
      [_ | stack] = Module.get_attribute(module, :phoenix_mountable_scope)
      Module.put_attribute(module, :phoenix_mountable_scope, stack)
    end

    @doc false
    def __pipe_through__(module, pipes) do
      [top | rest] = Module.get_attribute(module, :phoenix_mountable_scope)

      Module.put_attribute(module, :phoenix_mountable_scope, [
        %{top | pipes: top.pipes ++ List.wrap(pipes)} | rest
      ])
    end

    @session_schema [
      on_mount: [type: {:list, {:or, [:atom, {:tuple, [:atom, :any]}]}}, default: []],
      host_on_mount: [type: :boolean, default: true],
      root_layout: [type: {:tuple, [:atom, :atom]}],
      layout: [type: {:tuple, [:atom, :atom]}]
    ]

    @doc false
    def __start_session__(module, name, opts) do
      if not is_atom(name) do
        raise ArgumentError, "live_session name must be an atom, got: #{inspect(name)}"
      end

      if current = Module.get_attribute(module, :phoenix_mountable_current_session) do
        raise ArgumentError,
              "live_session #{inspect(name)} cannot be nested inside #{inspect(current)}"
      end

      if Enum.any?(Module.get_attribute(module, :phoenix_mountable_sessions), &(&1.name == name)) do
        raise ArgumentError,
              "live_session #{inspect(name)} is declared twice in #{inspect(module)}. " <>
                "A live session's routes must be declared in a single block."
      end

      opts =
        case NimbleOptions.validate(opts, @session_schema) do
          {:ok, opts} ->
            opts

          {:error, error} ->
            raise ArgumentError,
                  "invalid live_session #{inspect(name)} in #{inspect(module)}: #{error.message}"
        end

      Module.put_attribute(
        module,
        :phoenix_mountable_sessions,
        Map.new([name: name] ++ opts) |> session()
      )

      Module.put_attribute(module, :phoenix_mountable_current_session, name)
    end

    defp session(map), do: Map.merge(%{root_layout: nil, layout: nil}, map)

    @doc false
    def __end_session__(module) do
      Module.put_attribute(module, :phoenix_mountable_current_session, nil)
    end

    defmacro __before_compile__(env) do
      module = env.module
      config = Module.get_attribute(module, :phoenix_mountable_config)

      {assets, assets_inject} =
        PhoenixMountable.Assets.__init__(config.assets, module, config.otp_app)

      config = %{config | assets: assets}

      routes = module |> Module.get_attribute(:phoenix_mountable_routes) |> Enum.reverse()
      sessions = module |> Module.get_attribute(:phoenix_mountable_sessions) |> Enum.reverse()
      pipelines = module |> Module.get_attribute(:phoenix_mountable_pipelines) |> Map.new()
      schema = Module.get_attribute(module, :phoenix_mountable_options) || []
      verify = Module.get_attribute(module, :phoenix_mountable_verify) || []

      routes = resolve_pipelines(routes, pipelines, module)
      check_contiguous_sessions!(routes, module)

      sessions =
        if Enum.any?(routes, &(&1.session == :default)) and
             not Enum.any?(sessions, &(&1.name == :default)) do
          sessions ++ [session(%{name: :default, on_mount: [], host_on_mount: true})]
        else
          sessions
        end

      route_patterns = routes |> Enum.map(& &1.path) |> Enum.uniq()

      options_doc =
        if schema == [] do
          ""
        else
          "## Options\n\n" <> NimbleOptions.docs(schema) <> "\n"
        end

      quote do
        @doc false
        def __phoenix_mountable__(:config), do: unquote(Macro.escape(config))
        def __phoenix_mountable__(:routes), do: unquote(Macro.escape(routes))
        def __phoenix_mountable__(:sessions), do: unquote(Macro.escape(sessions))
        def __phoenix_mountable__(:options), do: unquote(Macro.escape(schema))
        def __phoenix_mountable__(:verify), do: unquote(Macro.escape(verify))
        def __phoenix_mountable__(:route_patterns), do: unquote(route_patterns)
        def __phoenix_mountable__(key), do: Map.fetch!(__phoenix_mountable__(:config), key)

        unquote(assets_inject)

        @doc """
        Mounts #{inspect(__MODULE__)} at `path` in a host router.

            import #{inspect(__MODULE__)}

            scope "/" do
              pipe_through :browser
              #{unquote(config.macro)} "/#{unquote(config.otp_app)}"
            end

        #{unquote(options_doc)}
        Every mount also takes the options listed in `PhoenixMountable`, such as
        `:as`, `:on_mount` and `:csp_nonce_assign_key`.
        """
        defmacro unquote(config.macro)(path, opts \\ []) do
          PhoenixMountable.Router.__mount_quoted__(__MODULE__, path, opts)
        end
      end
    end

    defp resolve_pipelines(routes, pipelines, module) do
      Enum.map(routes, fn route ->
        pipes =
          Enum.map(route.pipes, fn
            name when is_map_key(pipelines, name) ->
              Map.fetch!(pipelines, name)

            name when is_atom(name) ->
              if function_exported?(name, :call, 2) or
                   match?("Elixir." <> _, Atom.to_string(name)) do
                name
              else
                raise ArgumentError,
                      "#{inspect(module)}: unknown pipeline #{inspect(name)} in pipe_through. " <>
                        "Define it with pipeline/2 or pass a module plug."
              end
          end)

        %{route | pipes: pipes}
      end)
    end

    defp check_contiguous_sessions!(routes, module) do
      routes
      |> Enum.chunk_by(& &1.session)
      |> Enum.flat_map(fn
        [%{session: nil} | _] -> []
        [%{session: session} | _] -> [session]
      end)
      |> Enum.frequencies()
      |> Enum.each(fn
        {_session, 1} ->
          :ok

        {session, _} ->
          raise ArgumentError,
                "#{inspect(module)}: the live routes of session #{inspect(session)} are split by " <>
                  "other routes. Declare a live session's routes together."
      end)
    end
  end

  defmodule PhoenixMountable.Routes do
    @moduledoc """
    The macros available inside `PhoenixMountable.Definition.routes/1`.

    They mirror `Phoenix.Router` and `Phoenix.LiveView.Router`, with paths
    relative to the mount path. The mount macro turns them into ordinary
    routes of the host router.

        routes do
          get "/export", MyLib.ExportController, :csv
          forward "/api", MyLib.API.Router

          scope "/admin" do
            pipe_through :admin
            live "/settings", MyLib.SettingsLive, :edit
          end

          live_session :public, host_on_mount: false do
            live "/share/:token", MyLib.ShareLive, :show
          end

          live_session :default, on_mount: [MyLib.Auth] do
            live "/", MyLib.HomeLive, :index
          end
        end

    Live routes outside a `live_session` belong to the `:default` session. A
    live session's routes must be declared together.

    Route helpers are named after the mount: a route with `as: :export` gets
    the helper `<mount name>_export_path`, and routes without `:as` share the
    mount's name.
    """

    alias PhoenixMountable.Definition

    @doc """
    A LiveView route. See `Phoenix.LiveView.Router.live/4`.
    """
    defmacro live(path, live_view, action \\ nil, opts \\ []) do
      live_view = Macro.expand(live_view, %{__CALLER__ | function: {:live, 4}})

      quote do
        Definition.__record_route__(__MODULE__, %{
          kind: :live,
          path: unquote(path),
          module: unquote(live_view),
          action: unquote(action),
          opts: unquote(opts)
        })
      end
    end

    for verb <- [:get, :post, :put, :patch, :delete, :options, :head] do
      @doc """
      A `#{String.upcase(Atom.to_string(verb))}` route to a controller or plug. See `Phoenix.Router.#{verb}/4`.
      """
      defmacro unquote(verb)(path, plug, plug_opts, opts \\ []) do
        match(unquote(verb), path, plug, plug_opts, opts, __CALLER__)
      end
    end

    defp match(verb, path, plug, plug_opts, opts, caller) do
      plug = Macro.expand(plug, %{caller | function: {:init, 1}})

      quote do
        Definition.__record_route__(__MODULE__, %{
          kind: :match,
          verb: unquote(verb),
          path: unquote(path),
          plug: unquote(plug),
          plug_opts: unquote(plug_opts),
          opts: unquote(opts)
        })
      end
    end

    @doc """
    Forwards requests under `path` to a plug, such as a router of the library's
    API. See `Phoenix.Router.forward/4`.
    """
    defmacro forward(path, plug, plug_opts \\ [], opts \\ []) do
      plug = Macro.expand(plug, %{__CALLER__ | function: {:init, 1}})

      quote do
        Definition.__record_route__(__MODULE__, %{
          kind: :forward,
          path: unquote(path),
          plug: unquote(plug),
          plug_opts: unquote(plug_opts),
          opts: unquote(opts)
        })
      end
    end

    @doc """
    A live session of the library.

    The host's live session is named after the mount: `:default` becomes the
    mount name, any other session `<mount name>_<session>`.

    ## Options

      * `:on_mount` — hooks of this session, run after the library's.
      * `:host_on_mount` — whether the host's `:on_mount` hooks run. Defaults
        to `true`. Use `false` for public pages, which the host's
        authentication hooks would otherwise guard.
      * `:root_layout` — overrides the library's root layout.
      * `:layout` — the LiveView layout of the session.
    """
    defmacro live_session(name, opts \\ [], do: block) do
      quote do
        Definition.__start_session__(__MODULE__, unquote(name), unquote(opts))
        unquote(block)
        Definition.__end_session__(__MODULE__)
      end
    end

    @doc """
    Groups routes under a path. Takes `:pipe_through` as an option, or call
    `pipe_through/1` inside.
    """
    defmacro scope(path, opts \\ [], do: block) do
      quote do
        Definition.__push_scope__(__MODULE__, unquote(path), unquote(opts))
        unquote(block)
        Definition.__pop_scope__(__MODULE__)
      end
    end

    @doc """
    Pipes the routes of the scope through pipelines of the library
    (`PhoenixMountable.Definition.pipeline/2`) or module plugs.
    """
    defmacro pipe_through(pipes) do
      pipes = Macro.prewalk(pipes, &Macro.expand(&1, __CALLER__))

      quote do
        Definition.__pipe_through__(__MODULE__, unquote(pipes))
      end
    end
  end
end
