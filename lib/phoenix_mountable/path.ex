if Code.ensure_loaded?(Phoenix.Router) do
  defmodule PhoenixMountable.Path do
    @moduledoc ~S"""
    Paths relative to the mount: the `~m` sigil.

    Inside a mountable library the mount path is the host's choice, so `~p`
    cannot be used. `~m` builds a path relative to the mount instead:

        use PhoenixMountable.Path, mountable: MyLib.Router

        ~m"/items/#{item}"          #=> "/admin/my_lib/items/42"
        ~m"/items?#{[page: 2]}"     #=> "/admin/my_lib/items?page=2"
        ~m"/"                       #=> "/admin/my_lib"

    Like verified routes:

      * paths are **checked after compilation** against the library's own
        routes: a path that matches none of them emits a warning naming the
        file and line;
      * interpolated segments go through `Phoenix.Param` and are URL-encoded;
        an interpolated query takes a map or keyword list.

    At runtime the mount comes from the variable in scope (`assigns`, `socket`
    or `conn`, in that order), or from `PhoenixMountable.Mount.current/0`. The
    endpoint's script name and path are honoured, like `~p`.

    Outside of `~m`, `PhoenixMountable.Path.path/2` builds a path for an
    explicit mount, socket or conn.
    """

    alias PhoenixMountable.Mount

    @doc false
    # Joins a path to a base path, without doubled or trailing slashes.
    def join(base, path) do
      if not is_binary(path),
        do: raise(ArgumentError, "paths must be strings, got: #{inspect(path)}")

      base = String.trim_trailing(base, "/")

      case path do
        path when path in ["", "/"] -> if base == "", do: "/", else: base
        "/" <> _ -> base <> path
        path -> base <> "/" <> path
      end
    end

    @doc false
    defmacro __using__(opts) do
      mountable = Macro.expand(Keyword.fetch!(opts, :mountable), __CALLER__)

      quote do
        import PhoenixMountable.Path, only: [sigil_m: 2]
        @phoenix_mountable_path_definition unquote(mountable)
        Module.register_attribute(__MODULE__, :phoenix_mountable_paths,
          accumulate: true,
          persist: true
        )

        @after_verify {PhoenixMountable.Path, :__verify__}
      end
    end

    @doc """
    Builds a path relative to the mount. See the module documentation.
    """
    defmacro sigil_m({:<<>>, _meta, parts}, modifiers) do
      if modifiers != [], do: raise(ArgumentError, "~m does not take modifiers")

      {path_parts, query_parts} = split_query(parts)
      pattern = pattern(path_parts)

      if definition = Module.get_attribute(__CALLER__.module, :phoenix_mountable_path_definition) do
        Module.put_attribute(
          __CALLER__.module,
          :phoenix_mountable_paths,
          {definition, pattern, __CALLER__.file, __CALLER__.line}
        )
      end

      path = build(path_parts, &segment/1)
      query = build(query_parts, &query/1)
      context = context(__CALLER__)

      quote do
        PhoenixMountable.Path.__build__(unquote(context), unquote(path), unquote(query))
      end
    end

    defp split_query(parts) do
      index =
        Enum.find_index(parts, fn part -> is_binary(part) and String.contains?(part, "?") end)

      case index do
        nil ->
          {parts, []}

        index ->
          {before, [part | rest]} = Enum.split(parts, index)
          [path_part, query_part] = String.split(part, "?", parts: 2)
          {before ++ [path_part], [query_part | rest]}
      end
    end

    defp build([], _fun), do: nil

    defp build(parts, fun) do
      parts =
        Enum.map(parts, fn
          part when is_binary(part) -> part
          {:"::", _, [{{:., _, [Kernel, :to_string]}, _, [expr]}, _]} -> fun.(expr)
        end)

      quote do: IO.iodata_to_binary(unquote(parts))
    end

    defp segment(expr), do: quote(do: PhoenixMountable.Path.__segment__(unquote(expr)))
    defp query(expr), do: quote(do: PhoenixMountable.Path.__query__(unquote(expr)))

    defp pattern(parts) do
      Enum.map_join(parts, fn
        part when is_binary(part) -> part
        _ -> ":__dynamic__"
      end)
    end

    defp context(env) do
      vars = Macro.Env.vars(env)

      Enum.find_value([:assigns, :socket, :conn], fn name ->
        if {name, nil} in vars, do: Macro.var(name, nil)
      end)
    end

    @doc false
    def __segment__(value) do
      value |> Phoenix.Param.to_param() |> to_string() |> URI.encode(&URI.char_unreserved?/1)
    end

    @doc false
    def __query__(value) when is_map(value) or is_list(value),
      do: Plug.Conn.Query.encode(value, &Phoenix.Param.to_param/1)

    def __query__(value), do: value |> to_string() |> URI.encode_www_form()

    @doc false
    def __build__(context, path, query) do
      {source, mount} = source(context)
      path(source, mount, path, query)
    end

    @doc """
    Builds the full path of `path`, relative to the mount of `source`: a
    mount, a socket, a conn or an assigns map.
    """
    @spec path(Mount.t() | map, String.t()) :: String.t()
    def path(source, path) do
      {source, mount} = source(source)
      path(source, mount, path, nil)
    end

    @doc """
    Builds the full path of `path` under another mount of the same router,
    by its name (the mount macro, or its `:as`): a link from one of the
    library's definitions to another, wherever the host mounted it.

        PhoenixMountable.Path.path(conn, :my_lib_page, "/")  #=> "/changelog"

    Raises when the host has not mounted it; `PhoenixMountable.Mount.sibling/2`
    returns `nil` instead, for a link shown only when it has.
    """
    @spec path(Mount.t() | map, atom, String.t()) :: String.t()
    def path(source, name, path) when is_atom(name) do
      {source, mount} = source(source)

      case Mount.sibling(mount, name) do
        %Mount{} = sibling ->
          path(source, sibling, path, nil)

        nil ->
          raise ArgumentError,
                "no mount named #{inspect(name)} in #{inspect(mount.router)}: " <>
                  "mount it, or check with PhoenixMountable.Mount.sibling/2 first"
      end
    end

    defp path(source, mount, path, query) do
      relative = join(mount.path, path)

      full =
        case source do
          %{__struct__: struct} = conn_or_socket
          when struct in [Plug.Conn, Phoenix.LiveView.Socket] ->
            Phoenix.VerifiedRoutes.unverified_path(conn_or_socket, mount.router, relative)

          _ when mount.endpoint != nil ->
            Phoenix.VerifiedRoutes.unverified_path(mount.endpoint, mount.router, relative)

          _ ->
            relative
        end

      if query in [nil, ""], do: full, else: full <> "?" <> query
    end

    defp source(%Mount{} = mount), do: {mount, mount}

    defp source(%{__struct__: struct} = conn_or_socket)
         when struct in [Plug.Conn, Phoenix.LiveView.Socket] do
      case Mount.fetch(conn_or_socket) do
        {:ok, mount} -> {conn_or_socket, mount}
        :error -> {conn_or_socket, current!()}
      end
    end

    defp source(%{} = assigns) do
      case Mount.fetch(assigns) do
        {:ok, mount} -> {Map.get(assigns, :socket) || Map.get(assigns, :conn) || mount, mount}
        :error -> {current!(), current!()}
      end
    end

    defp source(nil), do: {current!(), current!()}

    defp current! do
      Mount.current() ||
        raise ArgumentError,
              "~m found no PhoenixMountable mount: it runs in the library's LiveViews, " <>
                "controllers and templates, where PhoenixMountable sets the current mount"
    end

    @doc false
    # Warns about ~m paths that match none of the library's routes, once the
    # module is compiled (like verified routes, to avoid compile-time
    # dependencies on the definition module).
    def __verify__(module) do
      paths =
        module.__info__(:attributes)
        |> Keyword.get_values(:phoenix_mountable_paths)
        |> List.flatten()

      for {definition, pattern, file, line} <- paths do
        if Code.ensure_loaded?(definition) and
             function_exported?(definition, :__phoenix_mountable__, 1) do
          routes = definition.__phoenix_mountable__(:route_patterns)

          if not Enum.any?(routes, &match_route?(pattern, &1)) do
            IO.warn(
              "no route of #{inspect(definition)} matches ~m\"#{pattern}\"",
              file: file,
              line: line
            )
          end
        end
      end

      :ok
    end

    @doc false
    def match_route?(pattern, route) do
      segments(pattern) |> match_segments?(segments(route))
    end

    defp segments(path), do: String.split(path, "/", trim: true)

    defp match_segments?([], []), do: true
    defp match_segments?(_rest, ["*" <> _]), do: true
    defp match_segments?([], _), do: false
    defp match_segments?(_, []), do: false

    defp match_segments?([given | given_rest], [route | route_rest]) do
      segment_match?(given, route) and match_segments?(given_rest, route_rest)
    end

    defp segment_match?(given, route) do
      cond do
        String.contains?(given, ":__dynamic__") -> true
        route == given -> true
        String.contains?(route, ":") -> prefix_match?(given, route)
        true -> false
      end
    end

    defp prefix_match?(given, route) do
      [prefix | _] = String.split(route, ":", parts: 2)
      String.starts_with?(given, prefix)
    end
  end
end
