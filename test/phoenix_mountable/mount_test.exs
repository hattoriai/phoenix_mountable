defmodule PhoenixMountable.MountTest do
  use ExUnit.Case, async: true
  use PhoenixMountable.Test, host: SampleLib.TestHost

  alias SampleLib.TestHost.Router

  describe "mount macro" do
    test "records every mount with validated options and defaults" do
      mounts = PhoenixMountable.mounts(Router)

      assert Enum.map(mounts, & &1.name) ==
               [:sample_lib, :other_sample, :plain_lib, :static_lib, :vite_lib, :nested_sample]

      sample = Router.__phoenix_mountable_mount__(:sample_lib)
      assert sample.path == "/sample"
      assert sample.definition == SampleLib.Router
      assert sample.options.resolver == SampleLib.TestResolver
      assert sample.options.greeting == "Hi"
      assert sample.socket_path == "/live"
      assert sample.transport == :websocket
      assert sample.host_on_mount == [SampleLib.HostHook]

      other = Router.__phoenix_mountable_mount__(:other_sample)
      assert other.options.resolver == SampleLib.Resolver
      assert other.options.greeting == "Hello"
      assert other.options.theme == :dark
    end

    test "normalize_options/1 fills derived options" do
      assert Router.__phoenix_mountable_mount__(:sample_lib).options.theme == :light
    end

    test "nested scopes give the full path" do
      assert Router.__phoenix_mountable_mount__(:nested_sample).path == "/admin/nested"
    end

    test "routes are ordinary Phoenix routes" do
      paths = Router |> Phoenix.Router.routes() |> Enum.map(& &1.path)
      assert "/sample/items/:id" in paths
      assert "/other/public/:token" in paths
      assert "/plain/echo" in paths
      assert "/admin/nested/export" in paths
    end
  end

  describe "LiveViews" do
    test "assigns the mount, runs hooks in order and merges the library session", %{conn: conn} do
      {:ok, view, html} = live(conn, "/sample")

      assert html =~ ~s(data-layout="sample")
      assert view |> element("#greeting") |> render() =~ "Hi test-user"
      assert view |> element("#hooks") |> render() =~ "[:host, :library, :session]"
      assert view |> element("#session") |> render() =~ ":default"
    end

    test "a session with host_on_mount: false skips the host's hooks", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/sample/public/abc")
      assert view |> element("#token") |> render() =~ "abc"
      assert view |> element("#hooks") |> render() =~ "[:library]"
    end

    test "~m builds paths relative to each mount", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/sample")
      assert view |> element("#item") |> render() =~ ~s(href="/sample/items/42")
      assert view |> element("#query") |> render() =~ ~s(href="/sample/items/a%20b?page=2")
      assert view |> element("#component") |> render() =~ ~s(href="/sample/items/7")

      {:ok, view, _html} = live(conn, "/admin/nested")
      assert view |> element("#item") |> render() =~ ~s(href="/admin/nested/items/42")
    end

    test "~m works in event handlers", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/other")
      assert {:error, {:live_redirect, %{to: "/other/items/9"}}} = render_click(view, "go", %{})
    end

    test "live navigation stays inside the mount's live session", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/sample")
      {:ok, item, _html} = live_redirect(view, to: "/sample/items/5")
      assert item |> element("#item") |> render() =~ "5"
    end
  end

  describe "controllers and plugs" do
    test "get the mount and the CSP nonces from the host's assigns", %{conn: conn} do
      conn =
        conn
        |> assign(:script_nonce, "n0nce")
        |> get("/sample/export")

      assert conn.resp_body == ~s(mount,sample_lib,/sample/items/1,"n0nce")
    end

    test "forwarded plugs get the mount", %{conn: conn} do
      assert conn |> get("/other/plug") |> response(200) == "forwarded other_sample"
    end

    test "library pipelines run on their routes", %{conn: conn} do
      conn = conn |> put_req_header("accept", "application/json") |> get("/sample/api/status")
      assert json_response(conn, 200) == %{"mount" => "sample_lib"}
    end

    test "a library without LiveView mounts with controllers only", %{conn: conn} do
      body = conn |> get("/plain") |> html_response(200)
      assert body =~ ~s(href="/plain/echo")
      assert body =~ ~s(<link rel="stylesheet" href="/assets/app.css" phx-track-static>)
    end
  end

  describe "processes" do
    test "each mount gets its own children, started on first use", %{conn: conn} do
      get(conn, "/sample/export")
      get(conn, "/other/export")

      sample = PhoenixMountable.via(Router.__phoenix_mountable_mount__(:sample_lib), :counter)
      other = PhoenixMountable.via(Router.__phoenix_mountable_mount__(:other_sample), :counter)

      first = SampleLib.Counter.bump(sample)
      assert SampleLib.Counter.bump(sample) == first + 1
      assert SampleLib.Counter.bump(other) >= 1
      assert GenServer.whereis(sample) != GenServer.whereis(other)
    end
  end

  describe "sibling mounts" do
    test "Mount.sibling/2 finds another mount of the router by name, or nil" do
      sample = Router.__phoenix_mountable_mount__(:sample_lib)

      assert %PhoenixMountable.Mount{path: "/admin/nested"} =
               PhoenixMountable.Mount.sibling(sample, :nested_sample)

      assert PhoenixMountable.Mount.sibling(sample, :nope) == nil

      conn = Plug.Conn.put_private(build_conn(), :phoenix_mountable, sample)
      assert PhoenixMountable.Mount.sibling(conn, :plain_lib).path == "/plain"
      assert PhoenixMountable.Mount.sibling(build_conn(), :plain_lib) == nil
    end

    test "Path.path/3 builds a path under the sibling, with the endpoint's script name" do
      sample = Router.__phoenix_mountable_mount__(:sample_lib)
      assert PhoenixMountable.Path.path(sample, :other_sample, "/items/1") == "/other/items/1"
      assert PhoenixMountable.Path.path(sample, :nested_sample, "/") == "/admin/nested"

      conn =
        build_conn()
        |> Plug.Conn.put_private(:phoenix_mountable, sample)
        |> Map.put(:script_name, ["app"])

      assert PhoenixMountable.Path.path(conn, :other_sample, "/") == "/app/other"
    end

    test "Path.path/3 raises for a mount the host does not have" do
      sample = Router.__phoenix_mountable_mount__(:sample_lib)

      assert_raise ArgumentError, ~r/no mount named :nope in SampleLib.TestHost.Router/, fn ->
        PhoenixMountable.Path.path(sample, :nope, "/")
      end
    end
  end
end
