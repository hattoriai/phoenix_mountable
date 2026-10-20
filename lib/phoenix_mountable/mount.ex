defmodule PhoenixMountable.Mount do
  @moduledoc """
  One mounted instance of a mountable library.

  A host that calls a mount macro twice (for example an admin and a public
  mount of the same library) gets two mounts, each with its own path and
  options. The mount is available wherever the library's code runs:

    * in LiveViews, as `socket.assigns.mount` (and `@mount` in templates);
    * in controllers and plugs on the library's routes, as `conn.assigns.mount`
      and `conn.private.phoenix_mountable`;
    * anywhere in the process that handles the request or LiveView, through
      `current/0`.

  ## Fields

    * `:definition` — the library's definition module (the one that calls
      `use PhoenixMountable`)
    * `:name` — the mount name, the host's `:as` option
    * `:path` — the full mount path, including the host's enclosing scopes
    * `:router`, `:endpoint` — the host's router and endpoint (`:endpoint` is
      set at runtime)
    * `:options` — the library's options as given by the host, validated and
      with defaults, as a map
    * `:socket_path`, `:transport` — where and how the LiveView socket connects
    * `:csp_nonces` — the CSP nonces of the current request, by kind
      (`:script`, `:style`, ...), read from the host's assigns
    * `:asset_host` — an optional scheme and host for asset URLs (a CDN)
    * `:assets` — the asset strategy and its state
    * `:pubsub` — the PubSub server for `PhoenixMountable.PubSub`, if the host
      gave one; otherwise the endpoint's is used
    * `:session` — the library live session the current LiveView belongs to
  """

  @type t :: %__MODULE__{
          definition: module,
          name: atom,
          path: String.t(),
          router: module,
          endpoint: module | nil,
          options: map,
          socket_path: String.t(),
          transport: :websocket | :longpoll,
          csp_nonce_assign_key: nil | atom | map,
          csp_nonces: map,
          asset_host: String.t() | nil,
          assets: {module, term} | nil,
          pubsub: atom | nil,
          host_on_mount: list,
          session: atom | nil
        }

  defstruct [
    :definition,
    :name,
    :path,
    :router,
    :endpoint,
    :asset_host,
    :assets,
    :pubsub,
    :session,
    :csp_nonce_assign_key,
    options: %{},
    socket_path: "/live",
    transport: :websocket,
    csp_nonces: %{},
    host_on_mount: []
  ]

  @pdict_key :phoenix_mountable_mount

  @doc """
  Returns the mount of a socket, conn or assigns map, raising if there is none.
  """
  @spec fetch!(map) :: t
  def fetch!(source) do
    case fetch(source) do
      {:ok, mount} ->
        mount

      :error ->
        raise ArgumentError,
              "no PhoenixMountable mount found in #{describe(source)}. Mounts are set on the " <>
                "library's own routes and LiveViews; is this code running outside of them?"
    end
  end

  @doc """
  Returns `{:ok, mount}` for a socket, conn or assigns map, or `:error`.
  """
  @spec fetch(map) :: {:ok, t} | :error
  def fetch(%{private: %{phoenix_mountable: %__MODULE__{} = mount}}), do: {:ok, mount}
  def fetch(%{assigns: %{mount: %__MODULE__{} = mount}}), do: {:ok, mount}
  def fetch(%{mount: %__MODULE__{} = mount}), do: {:ok, mount}
  def fetch(%{socket: socket}) when is_map(socket), do: fetch(socket)
  def fetch(%{conn: conn}) when is_map(conn), do: fetch(conn)
  def fetch(_), do: :error

  @doc """
  The mount of the current process: the LiveView or request being handled.

  Set by PhoenixMountable when a library LiveView mounts and when a request
  reaches a library route. Returns `nil` outside of them.
  """
  @spec current() :: t | nil
  def current, do: Process.get(@pdict_key)

  @doc false
  @spec put_current(t) :: t
  def put_current(%__MODULE__{} = mount) do
    Process.put(@pdict_key, mount)
    mount
  end

  @doc """
  Another mount of the same router, by its name (the mount macro, or its
  `:as`), from a mount, a conn, a socket or an assigns map. Returns `nil`
  when the host has not mounted it.

  A library with several definitions links from one to another with it:
  its admin to its public page, say, wherever the host put the page.

      PhoenixMountable.Mount.sibling(conn, :my_lib_page)
      #=> %PhoenixMountable.Mount{name: :my_lib_page, path: "/changelog", ...}

  See `PhoenixMountable.Path.path/3` for its paths.
  """
  @spec sibling(t | map, atom) :: t | nil
  def sibling(%__MODULE__{router: router}, name) when is_atom(name) do
    if Code.ensure_loaded?(router) and
         function_exported?(router, :__phoenix_mountable_mounts__, 0),
       do: Enum.find(router.__phoenix_mountable_mounts__(), &(&1.name == name))
  end

  def sibling(source, name) when is_atom(name) do
    case fetch(source) do
      {:ok, mount} -> sibling(mount, name)
      :error -> if mount = current(), do: sibling(mount, name)
    end
  end

  @doc """
  A key that identifies the mount on this node: `{router, name}`.
  """
  @spec key(t) :: {module, atom}
  def key(%__MODULE__{router: router, name: name}), do: {router, name}

  @doc """
  Returns the value of a library option.
  """
  @spec option(t, atom, term) :: term
  def option(%__MODULE__{options: options}, key, default \\ nil),
    do: Map.get(options, key, default)

  @doc false
  @spec nonces_from_assigns(map, nil | atom | map) :: map
  def nonces_from_assigns(_assigns, nil), do: %{}

  def nonces_from_assigns(assigns, key) when is_atom(key) do
    nonce = Map.get(assigns, key)
    %{script: nonce, style: nonce, img: nonce}
  end

  def nonces_from_assigns(assigns, keys) when is_map(keys) do
    Map.new(keys, fn {kind, key} -> {kind, Map.get(assigns, key)} end)
  end

  defp describe(%{__struct__: struct}), do: inspect(struct)
  defp describe(_), do: "the given map"
end
