if Code.ensure_loaded?(Phoenix.Router) do
  defmodule PhoenixMountable.Router do
    @moduledoc false
    # Host side of a mount: what a mount macro expands to in the host router.
    #
    # The library's routes are known when the macro expands, so they are
    # unrolled into literal `Phoenix.Router` and `Phoenix.LiveView.Router`
    # calls. Only what depends on the host's options (the mount name in route
    # helpers, live session names and hooks) is computed in the router body,
    # from the `mount` the expansion binds first.

    alias PhoenixMountable.Mount

    @builtin_schema [
      as: [
        type: :atom,
        doc:
          "The mount name: names the live sessions and route helpers. Mount a library twice with different names."
      ],
      on_mount: [
        type: {:list, {:or, [:atom, {:tuple, [:atom, :any]}]}},
        default: [],
        doc: "The host's `on_mount` hooks, run before the library's."
      ],
      socket_path: [
        type: :string,
        doc: "The path of the host's LiveView socket. Defaults to `\"/live\"`."
      ],
      transport: [
        type: {:in, [:websocket, :longpoll, "websocket", "longpoll"]},
        doc: "The LiveView transport, `:websocket` (default) or `:longpoll`."
      ],
      csp_nonce_assign_key: [
        type: {:or, [nil, :atom, {:map, :atom, :atom}]},
        default: nil,
        doc:
          "The assign holding the request's CSP nonce, or a map of kinds to assigns, such as " <>
            "`%{script: :script_nonce, style: :style_nonce}`."
      ],
      asset_host: [
        type: {:or, [nil, :string]},
        default: nil,
        doc: "A scheme and host to load the library's assets from, such as a CDN."
      ],
      pubsub: [
        type: {:or, [nil, :atom]},
        default: nil,
        doc: "The PubSub server of `PhoenixMountable.PubSub`. Defaults to the endpoint's."
      ]
    ]

    @doc false
    def builtin_schema, do: @builtin_schema

    @doc false
    def __mount_quoted__(definition, path, opts) do
      mount = Macro.var(:mount, __MODULE__)

      routes =
        definition
        |> groups()
        |> Enum.map(&group(&1, mount))

      live_require =
        if Enum.any?(definition.__phoenix_mountable__(:routes), &(&1.kind == :live)) do
          quote(do: require(Phoenix.LiveView.Router))
        end

      quote do
        require Phoenix.Router
        unquote(live_require)

        unquote(mount) =
          PhoenixMountable.Router.__prepare__(
            __MODULE__,
            unquote(definition),
            unquote(path),
            unquote(opts)
          )

        Phoenix.Router.scope unquote(path), alias: false, as: false do
          (unquote_splicing(routes))
        end
      end
    end

    # The library's routes, asset routes first, in groups of consecutive
    # routes of one live session or of plain routes.
    defp groups(definition) do
      config = definition.__phoenix_mountable__(:config)

      asset_routes =
        config.assets
        |> PhoenixMountable.Assets.routes(definition)
        |> Enum.map(&Map.merge(%{kind: :match, pipes: [], session: nil, opts: []}, &1))

      (asset_routes ++ definition.__phoenix_mountable__(:routes))
      |> Enum.chunk_by(&{&1.kind == :live, &1.session})
      |> Enum.map(fn
        [%{kind: :live, session: session} | _] = routes -> {:live_session, session, routes}
        routes -> {:routes, routes}
      end)
    end

    defp group({:live_session, session, routes}, mount) do
      quote do
        Phoenix.LiveView.Router.live_session PhoenixMountable.Router.__session_name__(
                                               unquote(mount),
                                               unquote(session)
                                             ),
                                             PhoenixMountable.Router.__session_opts__(
                                               unquote(mount),
                                               unquote(session)
                                             ) do
          (unquote_splicing(Enum.map(routes, &route(&1, mount))))
        end
      end
    end

    defp group({:routes, routes}, mount) do
      quote do
        (unquote_splicing(Enum.map(routes, &route(&1, mount))))
      end
    end

    defp route(%{kind: :live} = route, mount) do
      call =
        quote do
          Phoenix.LiveView.Router.live(
            unquote(route.path),
            unquote(route.module),
            unquote(route.action),
            PhoenixMountable.Router.__route_opts__(
              unquote(mount),
              unquote(Macro.escape(route.opts))
            )
          )
        end

      piped(route.pipes, call)
    end

    defp route(%{kind: :match} = route, mount) do
      call =
        quote do
          Phoenix.Router.match(
            unquote(route.verb),
            unquote(route.path),
            unquote(route.plug),
            unquote(Macro.escape(route.plug_opts)),
            PhoenixMountable.Router.__route_opts__(
              unquote(mount),
              unquote(Macro.escape(route.opts))
            )
          )
        end

      piped([PhoenixMountable.Plug | route.pipes], call)
    end

    defp route(%{kind: :forward} = route, mount) do
      # forward/4 adds `as: nil` to its options at expansion, so they are a
      # literal list whose values are computed in the router body.
      opts =
        for key <- Keyword.keys(route.opts) -- [:private, :as] do
          {key, Macro.escape(route.opts[key])}
        end

      private =
        quote do
          PhoenixMountable.Router.__private__(
            unquote(mount),
            unquote(Macro.escape(route.opts[:private] || %{}))
          )
        end

      call =
        quote do
          Phoenix.Router.forward(
            unquote(route.path),
            unquote(route.plug),
            unquote(Macro.escape(route.plug_opts)),
            unquote([{:private, private} | opts])
          )
        end

      piped([PhoenixMountable.Plug | route.pipes], call)
    end

    defp piped([], call), do: call

    defp piped(pipes, call) do
      quote do
        Phoenix.Router.scope "/", alias: false, as: false do
          Phoenix.Router.pipe_through(unquote(pipes))
          unquote(call)
        end
      end
    end

    @doc false
    def __prepare__(router, definition, path, opts) do
      mount = build(router, definition, Phoenix.Router.scoped_path(router, path), opts)
      register!(router, mount, definition.__phoenix_mountable__(:verify))
      mount
    end

    @doc false
    # The mount for `opts`, validated and normalized as the mount macro does.
    def build(router, definition, path, opts) do
      config = definition.__phoenix_mountable__(:config)
      library_schema = definition.__phoenix_mountable__(:options)

      opts =
        case NimbleOptions.validate(opts, library_schema ++ @builtin_schema) do
          {:ok, opts} ->
            opts

          {:error, %NimbleOptions.ValidationError{message: message}} ->
            raise ArgumentError,
                  "invalid options for #{config.macro}/2 (#{inspect(definition)}): #{message}"
        end

      {builtin, library} = Keyword.split(opts, Keyword.keys(@builtin_schema))

      library =
        if function_exported?(definition, :normalize_options, 1) do
          definition.normalize_options(library)
        else
          library
        end

      %Mount{
        definition: definition,
        name: builtin[:as] || config.as,
        path: path,
        router: router,
        options:
          Map.merge(Map.new(library_schema, fn {key, _} -> {key, nil} end), Map.new(library)),
        socket_path: builtin[:socket_path] || config.socket_path,
        transport: transport(builtin[:transport] || config.transport),
        csp_nonce_assign_key: builtin[:csp_nonce_assign_key],
        asset_host: builtin[:asset_host],
        assets: config.assets,
        pubsub: builtin[:pubsub],
        host_on_mount: builtin[:on_mount]
      }
    end

    # Strings are accepted for hosts used to LiveDashboard's and Oban Web's
    # `transport: "longpoll"`.
    defp transport(value) when value in [:websocket, "websocket"], do: :websocket
    defp transport(value) when value in [:longpoll, "longpoll"], do: :longpoll

    defp register!(router, mount, verify) do
      if not Module.has_attribute?(router, :phoenix_mountable_mounts) do
        Module.register_attribute(router, :phoenix_mountable_mounts, accumulate: true)
        Module.register_attribute(router, :phoenix_mountable_verify, accumulate: true)
        Module.put_attribute(router, :before_compile, __MODULE__)
        Module.put_attribute(router, :after_verify, {__MODULE__, :__verify__})
      end

      if Enum.any?(
           Module.get_attribute(router, :phoenix_mountable_mounts),
           &(&1.name == mount.name)
         ) do
        raise ArgumentError, """
        #{inspect(mount.definition)} is mounted twice in #{inspect(router)} with the name \
        #{inspect(mount.name)}. Pass a different :as to each mount.
        """
      end

      for {option, check} <- verify, value = Map.get(mount.options, option), value != nil do
        Module.put_attribute(
          router,
          :phoenix_mountable_verify,
          {mount.name, option, value, check}
        )
      end

      Module.put_attribute(router, :phoenix_mountable_mounts, mount)
    end

    @doc false
    def __session_name__(%Mount{name: name}, :default), do: name
    def __session_name__(%Mount{name: name}, session), do: :"#{name}_#{session}"

    @doc false
    def __session_opts__(%Mount{} = mount, session_name) do
      definition = mount.definition
      config = definition.__phoenix_mountable__(:config)
      session = Enum.find(definition.__phoenix_mountable__(:sessions), &(&1.name == session_name))
      host_hooks = if session.host_on_mount, do: mount.host_on_mount, else: []

      opts = [
        on_mount:
          [{PhoenixMountable.Hook, {mount.router, mount.name, session.name}}] ++
            host_hooks ++ config.on_mount ++ session.on_mount,
        session:
          {PhoenixMountable.Session, :__session__, [mount.router, mount.name, session.name]}
      ]

      opts =
        case session.root_layout || config.layout do
          :host -> opts
          {_mod, _fun} = layout -> Keyword.put(opts, :root_layout, layout)
        end

      if session.layout, do: Keyword.put(opts, :layout, session.layout), else: opts
    end

    @doc false
    # Route helpers are named after the mount: `as: :export` in the library
    # becomes `lotus_dashboard_export`, and routes without one share the
    # mount's name.
    def __route_opts__(%Mount{} = mount, opts) do
      as =
        case Keyword.fetch(opts, :as) do
          {:ok, as} when is_atom(as) and as not in [nil, false] -> :"#{mount.name}_#{as}"
          _ -> mount.name
        end

      opts
      |> Keyword.put(:as, as)
      |> Keyword.put(:private, __private__(mount, Keyword.get(opts, :private, %{})))
    end

    @doc false
    def __private__(%Mount{} = mount, private) do
      Map.put(private, :phoenix_mountable, {mount.router, mount.name})
    end

    defmacro __before_compile__(env) do
      mounts = env.module |> Module.get_attribute(:phoenix_mountable_mounts) |> Enum.reverse()
      verify = env.module |> Module.get_attribute(:phoenix_mountable_verify) |> Enum.reverse()

      clauses =
        for mount <- mounts do
          quote do
            def __phoenix_mountable_mount__(unquote(mount.name)), do: unquote(Macro.escape(mount))
          end
        end

      quote do
        @doc false
        def __phoenix_mountable_mounts__, do: unquote(Macro.escape(mounts))
        @doc false
        def __phoenix_mountable_verify__, do: unquote(Macro.escape(verify))
        unquote(clauses)
        @doc false
        def __phoenix_mountable_mount__(name) do
          raise ArgumentError, "no mount named #{inspect(name)} in #{inspect(__MODULE__)}"
        end
      end
    end

    @doc false
    # Runs once the host router is compiled, when modules that depend on the
    # router (a resolver using ~p) can be loaded without a deadlock.
    def __verify__(router) do
      __verify_entries__(router, router.__phoenix_mountable_verify__())
    end

    @doc false
    def __verify_entries__(router, entries) do
      Enum.each(entries, fn {mount_name, option, value, check} ->
        verify!(router, mount_name, option, value, check)
      end)
    end

    defp verify!(router, mount_name, option, value, check) do
      if not Code.ensure_loaded?(value) do
        raise ArgumentError, """
        the #{inspect(option)} option of mount #{inspect(mount_name)} in #{inspect(router)} \
        names a module that does not exist:

            #{inspect(value)}

        Check the module name for a typo.
        """
      end

      with {:behaviour, behaviour} <- check,
           false <- value == behaviour,
           false <- behaviour in behaviours(value) do
        raise ArgumentError, """
        the #{inspect(option)} option of mount #{inspect(mount_name)} in #{inspect(router)} \
        must implement the #{inspect(behaviour)} behaviour, but #{inspect(value)} does not.

        Add `@behaviour #{inspect(behaviour)}` to #{inspect(value)}.
        """
      end

      :ok
    end

    defp behaviours(module) do
      module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()
    end
  end
end
