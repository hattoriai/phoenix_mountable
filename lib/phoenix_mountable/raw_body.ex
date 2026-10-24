if Code.ensure_loaded?(Phoenix.Router) do
  defmodule PhoenixMountable.RawBody do
    @moduledoc """
    The body of a request as it was sent, for the routes that check a
    signature of it: a mail provider's webhooks, GitHub's, Stripe's.

    In a Phoenix app the endpoint's `Plug.Parsers` reads the body before the
    router, and a body can be read once. A Rails engine's controller can
    still read it (Rack keeps it rewindable); a library's route in Phoenix
    needs the endpoint to keep a copy. One reader keeps it for every
    library, given to `Plug.Parsers` with the app's router:

        plug Plug.Parsers,
          parsers: [:urlencoded, :multipart, :json],
          pass: ["*/*"],
          body_reader: {PhoenixMountable.RawBody, :read_body, [MyAppWeb.Router]},
          json_decoder: Phoenix.json_library()

    `use PhoenixMountable.Install, raw_body: true` adds it to the app's
    endpoint.

    ## Which requests

    Before it reads a body, the reader asks the router which plug the
    request will reach (`Phoenix.Router.route_info/4`, through the routers
    it forwards to), and keeps a copy only when that plug says it needs the
    body as sent:

        defmodule MyLib.Webhook do
          use PhoenixMountable.RawBody
          # every route to this plug
        end

        defmodule MyLibWeb.HookController do
          use MyLibWeb, :controller
          use PhoenixMountable.RawBody, only: [:create]
          # the routes to these actions
        end

    So nothing depends on a route's path, scope or pipeline: the app can
    move and rename the routes, and their bodies are kept. Every other
    request is read as `Plug.Conn.read_body/2` reads it, with one lookup in
    the router's compiled routes the first time, and nothing kept.

    The router can be a list of routers (an app with more than one
    endpoint's worth, or a router no forward reaches).

    ## Reading it

    In the plug, `fetch/2` gives the body: the copy the reader kept, or the
    body itself when the parsers left it unread (a type they `pass`, such as
    a raw email's `message/rfc822`).

        {:ok, body, conn} = PhoenixMountable.RawBody.fetch(conn, 1_000_000)
    """

    @private :phoenix_mountable_raw_body

    @doc """
    Marks a plug, or a controller's actions (`only:`), as needing the body
    of their requests as it was sent.
    """
    defmacro __using__(opts) do
      only = Keyword.get(opts, :only)

      quote do
        @doc false
        def __phoenix_mountable_raw_body__(plug_opts),
          do: PhoenixMountable.RawBody.__wanted__(unquote(only), plug_opts)
      end
    end

    @doc false
    def __wanted__(nil, _plug_opts), do: true
    def __wanted__(only, action) when is_list(only), do: action in only

    @doc """
    A body reader for `Plug.Parsers` (`body_reader: {PhoenixMountable.RawBody,
    :read_body, [router]}`): reads the body as `Plug.Conn.read_body/2` does,
    and keeps a copy of it for the routes that want it.
    """
    @spec read_body(Plug.Conn.t(), keyword(), module() | [module()]) ::
            {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
    def read_body(conn, opts, router) do
      {keep?, conn} = keep?(conn, router)

      case Plug.Conn.read_body(conn, opts) do
        {status, body, conn} when status in [:ok, :more] ->
          {status, body, if(keep?, do: keep(conn, body), else: conn)}

        {:error, reason} ->
          {:error, reason}
      end
    end

    # Asked once a request: the parsers call the reader for each chunk.
    defp keep?(%Plug.Conn{private: %{@private => {:keep, keep?, _chunks}}} = conn, _router),
      do: {keep?, conn}

    defp keep?(conn, router) do
      keep? = Enum.any?(List.wrap(router), &wanted?(&1, conn.method, conn.path_info, conn.host))
      {keep?, Plug.Conn.put_private(conn, @private, {:keep, keep?, []})}
    end

    defp keep(%Plug.Conn{private: %{@private => {:keep, true, chunks}}} = conn, body),
      do: Plug.Conn.put_private(conn, @private, {:keep, true, [chunks, body]})

    @doc """
    Whether the request to `path_info` reaches a plug that wants its body
    as sent, through the routers `router` forwards to.
    """
    @spec wanted?(module(), String.t(), [String.t()], String.t()) :: boolean()
    def wanted?(router, method, path_info, host) do
      case Phoenix.Router.route_info(router, method, path_info, host) do
        %{plug: plug, plug_opts: plug_opts} = route ->
          cond do
            forwarded_router?(plug, route) ->
              wanted?(plug, method, Enum.drop(path_info, length(route.forward)), host)

            Code.ensure_loaded?(plug) and
                function_exported?(plug, :__phoenix_mountable_raw_body__, 1) ->
              plug.__phoenix_mountable_raw_body__(plug_opts) == true

            true ->
              false
          end

        :error ->
          false
      end
    end

    defp forwarded_router?(plug, %{forward: forward}) when is_list(forward),
      do: Code.ensure_loaded?(plug) and function_exported?(plug, :__match_route__, 3)

    defp forwarded_router?(_plug, _route), do: false

    @doc """
    The body of the request as it was sent, at most `max` bytes: the copy
    `read_body/3` kept, or the body read now when the parsers left it
    unread. `{:error, :too_large}` past `max`, and `{:error, :no_raw_body}`
    when the parsers read it without keeping it (the endpoint has not got
    the reader, or the route's plug does not `use PhoenixMountable.RawBody`).
    """
    @spec fetch(Plug.Conn.t(), pos_integer()) ::
            {:ok, binary(), Plug.Conn.t()} | {:error, :too_large | :no_raw_body | term()}
    def fetch(%Plug.Conn{private: %{@private => {:keep, true, chunks}}} = conn, max) do
      body = IO.iodata_to_binary(chunks)
      if byte_size(body) > max, do: {:error, :too_large}, else: {:ok, body, conn}
    end

    def fetch(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}} = conn, max),
      do: read_all(conn, max, [])

    def fetch(%Plug.Conn{} = conn, max) do
      # The parsers passed it (a type they `pass`): it is still unread.
      case read_all(conn, max, []) do
        {:ok, "", _conn} -> {:error, :no_raw_body}
        result -> result
      end
    end

    defp read_all(conn, max, acc) do
      case Plug.Conn.read_body(conn, length: min(max, 8_000_000), read_length: 1_000_000) do
        {:ok, body, conn} ->
          total = IO.iodata_to_binary([acc, body])
          if byte_size(total) > max, do: {:error, :too_large}, else: {:ok, total, conn}

        {:more, body, conn} ->
          acc = [acc, body]
          if IO.iodata_length(acc) > max, do: {:error, :too_large}, else: read_all(conn, max, acc)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
