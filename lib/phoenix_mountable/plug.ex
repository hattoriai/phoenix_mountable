if Code.ensure_loaded?(Phoenix.Router) do
  defmodule PhoenixMountable.Plug do
    @moduledoc false
    # Runs in front of every route of a library that is not a LiveView: puts
    # the mount in `conn.assigns.mount` and `conn.private.phoenix_mountable`.

    @behaviour Plug

    alias PhoenixMountable.{Mount, Runtime}

    @impl Plug
    def init(opts), do: opts

    @impl Plug
    def call(%Plug.Conn{private: %{phoenix_mountable: {router, name}}} = conn, _opts) do
      mount = router.__phoenix_mountable_mount__(name)

      mount =
        %{
          mount
          | endpoint: conn.private[:phoenix_endpoint],
            csp_nonces: Mount.nonces_from_assigns(conn.assigns, mount.csp_nonce_assign_key)
        }
        |> Runtime.enter(
          :request,
          conn.private[:phoenix_controller] || conn.private[:phoenix_plug]
        )

      conn
      |> Plug.Conn.put_private(:phoenix_mountable, mount)
      |> Plug.Conn.assign(:mount, mount)
      |> put_root_layout(mount.definition.__phoenix_mountable__(:layout))
    end

    def call(conn, _opts), do: conn

    # Controllers of the library render in the library's root layout, like its
    # LiveViews, unless the library renders inside the host's.
    defp put_root_layout(conn, :host), do: conn

    defp put_root_layout(conn, {mod, fun}) do
      Phoenix.Controller.put_root_layout(conn, html: {mod, fun})
    end
  end

  defmodule PhoenixMountable.Runtime do
    @moduledoc false

    alias PhoenixMountable.{Children, Mount, SchemaCheck, Telemetry}

    @doc false
    # Everything that happens when library code starts handling a request or a
    # LiveView for a mount.
    def enter(%Mount{} = mount, kind, handler) do
      Mount.put_current(mount)
      Children.ensure_started(mount)
      SchemaCheck.ensure_checked(mount)

      Telemetry.execute([:mount, kind], %{system_time: System.system_time()}, %{
        mount: mount,
        handler: handler
      })

      mount
    end
  end
end
