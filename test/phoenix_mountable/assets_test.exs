defmodule PhoenixMountable.AssetsTest do
  use ExUnit.Case, async: true
  use PhoenixMountable.Test, host: SampleLib.TestHost

  alias PhoenixMountable.Assets
  alias SampleLib.TestHost.{Endpoint, Router}

  defp mount(name), do: %{Router.__phoenix_mountable_mount__(name) | endpoint: Endpoint}

  describe "Embedded" do
    test "serves each entry under its content hash, gzipped on request", %{conn: conn} do
      css_url = Assets.url(mount(:sample_lib), :css)
      assert css_url =~ ~r"^/sample/css-[0-9a-f]{32}$"

      conn = get(conn, css_url)
      assert response(conn, 200) == File.read!("test/support/assets/app.css")
      assert get_resp_header(conn, "content-type") == ["text/css"]
      assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]

      gzipped = build_conn() |> put_req_header("accept-encoding", "gzip, br") |> get(css_url)
      assert get_resp_header(gzipped, "content-encoding") == ["gzip"]
      assert :zlib.gunzip(gzipped.resp_body) == File.read!("test/support/assets/app.css")
    end

    test "prepends the Phoenix and PhoenixMountable scripts and skips the CSRF script check", %{
      conn: conn
    } do
      conn = get(conn, Assets.url(mount(:sample_lib), :js))
      body = response(conn, 200)

      assert body =~ "LiveSocket"
      assert body =~ "window.PhoenixMountable"
      assert String.ends_with?(body, "window.sampleLib = true;\n")
      refute body =~ "//# sourceMappingURL="
    end

    test "answers 404 with no-store for a hash this build did not produce", %{conn: conn} do
      conn = get(conn, "/sample/css-" <> String.duplicate("0", 32))
      assert response(conn, 404) == ""
      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    test "detects pages running a previous build" do
      mount = mount(:sample_lib)
      current = Assets.url(mount, :css)
      old = "/sample/css-" <> String.duplicate("a", 32)

      refute Assets.stale?(mount, [current, "/assets/app.css"])
      assert Assets.stale?(mount, [old])
      refute Assets.stale?(mount, ["/other/css-" <> String.duplicate("a", 32)])
    end

    test "asset_host puts assets on another host" do
      mount = %{mount(:sample_lib) | asset_host: "https://cdn.example.com/"}
      assert Assets.url(mount, :css) =~ ~r"^https://cdn.example.com/sample/css-"
    end
  end

  describe "Static" do
    test "serves a directory with versioned entry URLs", %{conn: conn} do
      [css, js] = Assets.entries(mount(:static_lib))
      assert css.url =~ ~r"^/static_lib/assets/app.css\?vsn=[0-9a-f]{32}$"
      assert js.url =~ ~r"^/static_lib/assets/js/app.js\?vsn="

      conn = get(conn, js.url)
      assert response(conn, 200) == "window.staticLib=1;\n"
      assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]

      assert build_conn() |> get("/static_lib/assets/missing.js") |> response(404)
      assert_error_sent 400, fn -> get(build_conn(), "/static_lib/assets/../../mix.exs") end
    end

    test "reads a Vite manifest, adding the entry's CSS", %{conn: conn} do
      entries = Assets.entries(mount(:vite_lib))

      assert [
               %{name: :app, kind: :module, url: "/vite/static/assets/main-B1a2c3d4.js"},
               %{name: :app_css, kind: :css, url: "/vite/static/assets/main-C9f8e7d6.css"}
             ] = entries

      assert conn |> get("/vite/static/assets/main-B1a2c3d4.js") |> response(200) =~
               "export const x"
    end

    test "detects stale hashed files and versions" do
      vite = mount(:vite_lib)
      refute Assets.stale?(vite, ["/vite/static/assets/main-B1a2c3d4.js"])
      assert Assets.stale?(vite, ["/vite/static/assets/main-0ld0ld00.js"])

      static = mount(:static_lib)
      refute Assets.stale?(static, [Assets.url(static, :css)])
      assert Assets.stale?(static, ["/static_lib/assets/app.css?vsn=old"])
    end

    test "the built-in layout renders module scripts and a title", %{conn: conn} do
      html = conn |> get("/vite") |> html_response(200)

      assert html =~
               ~r|<script type="module" src="/vite/static/assets/main-B1a2c3d4.js" phx-track-static>\s*</script>|

      assert html =~
               ~s(<link rel="stylesheet" href="/vite/static/assets/main-C9f8e7d6.css" phx-track-static>)

      assert html =~ "Vite Lib"
      assert html =~ ~s(<meta name="phoenix-mountable-prefix" content="/vite">)
    end
  end

  describe "Host" do
    test "uses the endpoint's static paths and serves nothing" do
      mount = mount(:plain_lib)
      assert Assets.url(mount, :css) == "/assets/app.css"
      assert Assets.routes(mount.assets, mount.definition) == []
      assert Assets.stale?(mount, ["/assets/app-" <> String.duplicate("b", 32) <> ".css"])
      refute Assets.stale?(mount, ["/assets/app.css"])
    end

    test "tailwind_source/2 gives the line for each Tailwind version" do
      assert PhoenixMountable.Assets.Host.tailwind_source(:my_lib, :v4) ==
               ~s(@source "../../deps/my_lib";)

      assert PhoenixMountable.Assets.Host.tailwind_source(:my_lib, :v3) ==
               ~s("../deps/my_lib/**/*.*ex")
    end
  end

  describe "layout" do
    test "meta and asset tags carry the request's CSP nonces", %{conn: conn} do
      html =
        conn
        |> assign(:script_nonce, "scr")
        |> assign(:style_nonce, "sty")
        |> get("/sample")
        |> html_response(200)

      assert html =~
               ~r|<link rel="stylesheet" href="/sample/css-[0-9a-f]{32}" nonce="sty" phx-track-static>|

      assert html =~
               ~r|<script src="/sample/js-[0-9a-f]{32}" nonce="scr" defer phx-track-static>|

      assert html =~ ~s(<meta name="live-path" content="/live">)
      assert html =~ ~s(<meta name="live-transport" content="websocket">)
      assert html =~ ~s(<meta name="csrf-token")
    end
  end

  describe "stale reload" do
    test "a LiveView connecting with a previous build's assets reloads", %{conn: conn} do
      old = "/sample/css-" <> String.duplicate("c", 32)
      conn = put_connect_params(conn, %{"_track_static" => [old]})

      assert {:error, {:redirect, %{to: "/sample"}}} = live(conn, "/sample")
    end

    test "a LiveView with current assets connects", %{conn: conn} do
      current = Assets.url(mount(:sample_lib), :css)
      conn = put_connect_params(conn, %{"_track_static" => [current]})
      assert {:ok, _view, _html} = live(conn, "/sample")
    end
  end
end
