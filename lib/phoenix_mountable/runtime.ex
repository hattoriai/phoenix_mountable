if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule PhoenixMountable.Session do
    @moduledoc false

    alias PhoenixMountable.Mount

    # The session MFA of every library live session. Runs on the HTTP request,
    # so it can read the CSP nonces from the host's assigns.
    @doc false
    def __session__(conn, router, name, session_name) do
      mount = router.__phoenix_mountable_mount__(name)
      nonces = Mount.nonces_from_assigns(conn.assigns, mount.csp_nonce_assign_key)

      base = %{
        "phoenix_mountable" => %{"router" => router, "name" => name, "csp_nonces" => nonces}
      }

      definition = mount.definition

      if Code.ensure_loaded?(definition) and function_exported?(definition, :session, 3) do
        mount = %{
          mount
          | endpoint: conn.private[:phoenix_endpoint],
            csp_nonces: nonces,
            session: session_name
        }

        extra = definition.session(conn, mount, session_name)

        if not is_map(extra) do
          raise ArgumentError,
                "#{inspect(definition)}.session/3 must return a map, got: #{inspect(extra)}"
        end

        Map.merge(extra, base)
      else
        base
      end
    end
  end

  defmodule PhoenixMountable.Hook do
    @moduledoc false
    # The first on_mount hook of every library live session: puts the mount in
    # the socket assigns and the process, starts the mount's processes, checks
    # the library schema and reloads pages whose assets are stale.

    import Phoenix.Component, only: [assign: 3]

    import Phoenix.LiveView,
      only: [attach_hook: 4, connected?: 1, get_connect_params: 1, redirect: 2]

    alias PhoenixMountable.{Assets, Mount, Runtime}

    @doc false
    def on_mount({router, name, session_name}, _params, session, socket) do
      nonces = get_in(session, ["phoenix_mountable", "csp_nonces"]) || %{}

      mount =
        router.__phoenix_mountable_mount__(name)
        |> Map.merge(%{endpoint: socket.endpoint, csp_nonces: nonces, session: session_name})
        |> Runtime.enter(:live, socket.view)

      socket = assign(socket, :mount, mount)

      if connected?(socket) and mount.definition.__phoenix_mountable__(:reload_on_stale) and
           Assets.stale?(mount, tracked_static(socket)) do
        {:cont, attach_hook(socket, :phoenix_mountable_stale, :handle_params, &reload/3)}
      else
        {:cont, socket}
      end
    end

    defp tracked_static(socket) do
      case get_connect_params(socket) do
        %{"_track_static" => tracked} when is_list(tracked) -> tracked
        _ -> []
      end
    end

    # A relative redirect reloads the page through whatever proxy served it.
    defp reload(_params, uri, socket) do
      PhoenixMountable.Telemetry.execute([:assets, :stale], %{}, %{mount: Mount.fetch!(socket)})
      %URI{path: path, query: query} = URI.parse(uri)
      {:halt, redirect(socket, to: if(query, do: path <> "?" <> query, else: path))}
    end
  end
end
