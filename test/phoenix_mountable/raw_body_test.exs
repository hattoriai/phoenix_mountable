defmodule PhoenixMountable.RawBodyTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias PhoenixMountable.RawBody

  defmodule Webhook do
    use PhoenixMountable.RawBody

    def init(opts), do: opts
    def call(conn, _opts), do: conn
  end

  defmodule HookController do
    use PhoenixMountable.RawBody, only: [:create]

    def init(action), do: action
    def call(conn, _action), do: conn
  end

  defmodule Plain do
    def init(opts), do: opts
    def call(conn, _opts), do: conn
  end

  defmodule ApiRouter do
    use Phoenix.Router

    post "/hooks/:name", PhoenixMountable.RawBodyTest.Webhook, []
    post "/plain", PhoenixMountable.RawBodyTest.Plain, []
  end

  defmodule Router do
    use Phoenix.Router

    # Paths, scopes and pipelines of the host's choosing: nothing in the
    # reader depends on them.
    scope "/somewhere/renamed" do
      post "/provider", PhoenixMountable.RawBodyTest.Webhook, []
    end

    post "/hooks/create", PhoenixMountable.RawBodyTest.HookController, :create
    post "/hooks/update", PhoenixMountable.RawBodyTest.HookController, :update
    post "/plain", PhoenixMountable.RawBodyTest.Plain, []
    forward "/api", PhoenixMountable.RawBodyTest.ApiRouter
  end

  @json ~s({"a": 1,  "b" : [2]})

  defp parsed(path, body \\ @json, content_type \\ "application/json") do
    parsers =
      Plug.Parsers.init(
        parsers: [:urlencoded, :json],
        pass: ["*/*"],
        json_decoder: JSON,
        body_reader: {RawBody, :read_body, [Router]}
      )

    conn(:post, path, body)
    |> Plug.Conn.put_req_header("content-type", content_type)
    |> Plug.Parsers.call(parsers)
  end

  test "keeps the body of a route whose plug wants it, at any path" do
    conn = parsed("/somewhere/renamed/provider")

    assert conn.body_params == %{"a" => 1, "b" => [2]}
    assert {:ok, @json, _conn} = RawBody.fetch(conn, 1_000)
  end

  test "keeps nothing for a route whose plug does not want it" do
    assert RawBody.fetch(parsed("/plain"), 1_000) == {:error, :no_raw_body}
    assert RawBody.fetch(parsed("/no/such/route"), 1_000) == {:error, :no_raw_body}
  end

  test "a controller's actions, by only:" do
    assert {:ok, @json, _conn} = RawBody.fetch(parsed("/hooks/create"), 1_000)
    assert RawBody.fetch(parsed("/hooks/update"), 1_000) == {:error, :no_raw_body}
  end

  test "through a forward, in the router it forwards to" do
    assert {:ok, @json, _conn} = RawBody.fetch(parsed("/api/hooks/github"), 1_000)
    assert RawBody.fetch(parsed("/api/plain"), 1_000) == {:error, :no_raw_body}
  end

  test "a body the parsers pass is read as it is" do
    email = "From: a@example.com\r\n\r\nHello"
    conn = parsed("/plain", email, "message/rfc822")

    assert {:ok, ^email, _conn} = RawBody.fetch(conn, 1_000)
  end

  test "a body larger than the limit" do
    assert RawBody.fetch(parsed("/somewhere/renamed/provider"), 5) == {:error, :too_large}
  end

  test "a body read in chunks is kept whole" do
    body = JSON.encode!(%{"text" => String.duplicate("x", 300_000)})

    parsers =
      Plug.Parsers.init(
        parsers: [:json],
        json_decoder: JSON,
        read_length: 10_000,
        body_reader: {RawBody, :read_body, [Router]}
      )

    conn =
      conn(:post, "/somewhere/renamed/provider", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Parsers.call(parsers)

    assert {:ok, ^body, _conn} = RawBody.fetch(conn, 1_000_000)
  end

  test "routers as a list: a route of any of them" do
    parsers =
      Plug.Parsers.init(
        parsers: [:json],
        json_decoder: JSON,
        body_reader: {RawBody, :read_body, [[Router, ApiRouter]]}
      )

    conn =
      conn(:post, "/hooks/github", @json)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Parsers.call(parsers)

    assert {:ok, @json, _conn} = RawBody.fetch(conn, 1_000)
  end
end
