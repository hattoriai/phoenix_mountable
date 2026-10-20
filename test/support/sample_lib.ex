defmodule SampleLib.Resolver do
  @moduledoc false
  @callback resolve_user(Plug.Conn.t()) :: term
  def resolve_user(conn), do: conn.assigns[:current_user]
end

defmodule SampleLib.TestResolver do
  @moduledoc false
  @behaviour SampleLib.Resolver
  def resolve_user(_conn), do: "test-user"
end

defmodule SampleLib.Router do
  @moduledoc false
  use PhoenixMountable,
    otp_app: :phoenix_mountable,
    macro: :sample_lib,
    title: "Sample",
    layout: {SampleLib.Layouts, :root},
    on_mount: [SampleLib.LibraryHook],
    assets:
      {PhoenixMountable.Assets.Embedded,
       css: "test/support/assets/app.css",
       js: "test/support/assets/app.js",
       prepend: [:phoenix, :phoenix_live_view, :phoenix_mountable]}

  options(
    resolver: [
      type: :atom,
      default: SampleLib.Resolver,
      verify: {:behaviour, SampleLib.Resolver},
      doc: "Resolves the current user."
    ],
    greeting: [type: :string, default: "Hello"],
    theme: [type: {:in, [:light, :dark, :system]}],
    themes: [type: {:list, :atom}, default: [:light, :dark]]
  )

  pipeline :api do
    plug :accepts, ["json"]
  end

  routes do
    get "/export", SampleLib.ExportController, :csv
    forward "/plug", SampleLib.ForwardedPlug, greeting: "forwarded"

    scope "/api" do
      pipe_through :api
      get "/status", SampleLib.ExportController, :status, as: :api
    end

    live_session :public, host_on_mount: false do
      live "/public/:token", SampleLib.PublicLive, :show
    end

    live_session :default, on_mount: [SampleLib.SessionHook] do
      live "/", SampleLib.HomeLive, :home
      live "/items/:id", SampleLib.ItemLive, :show
    end
  end

  @impl PhoenixMountable
  def normalize_options(opts) do
    opts = Keyword.put_new_lazy(opts, :theme, fn -> hd(opts[:themes]) end)
    opts = if opts[:theme] == nil, do: Keyword.put(opts, :theme, hd(opts[:themes])), else: opts

    if opts[:theme] not in opts[:themes] do
      raise ArgumentError,
            "theme #{inspect(opts[:theme])} is not one of #{inspect(opts[:themes])}"
    end

    opts
  end

  @impl PhoenixMountable
  def session(conn, mount, session_name) do
    %{"user" => mount.options.resolver.resolve_user(conn), "session_name" => session_name}
  end

  @impl PhoenixMountable
  def children(mount) do
    [{SampleLib.Counter, name: PhoenixMountable.via(mount, :counter)}]
  end
end

defmodule SampleLib.Counter do
  @moduledoc false
  use Agent
  def start_link(opts), do: Agent.start_link(fn -> 0 end, name: Keyword.fetch!(opts, :name))
  def bump(name), do: Agent.get_and_update(name, &{&1 + 1, &1 + 1})
end

defmodule SampleLib.LibraryHook do
  @moduledoc false
  def on_mount(:default, _params, _session, socket) do
    {:cont,
     Phoenix.Component.assign(socket, :hooks, (socket.assigns[:hooks] || []) ++ [:library])}
  end
end

defmodule SampleLib.SessionHook do
  @moduledoc false
  def on_mount(:default, _params, _session, socket) do
    {:cont,
     Phoenix.Component.assign(socket, :hooks, (socket.assigns[:hooks] || []) ++ [:session])}
  end
end

defmodule SampleLib.HostHook do
  @moduledoc false
  def on_mount(:default, _params, _session, socket) do
    {:cont, Phoenix.Component.assign(socket, :hooks, (socket.assigns[:hooks] || []) ++ [:host])}
  end
end

defmodule SampleLib.Layouts do
  @moduledoc false
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html>
      <head>
        <PhoenixMountable.Layout.meta mount={@mount} />
        <PhoenixMountable.Layout.assets mount={@mount} />
      </head>
      <body data-layout="sample">{@inner_content}</body>
    </html>
    """
  end
end

defmodule SampleLib.HomeLive do
  @moduledoc false
  use Phoenix.LiveView
  use PhoenixMountable.Path, mountable: SampleLib.Router

  def mount(_params, session, socket) do
    {:ok, assign(socket, user: session["user"], session_name: session["session_name"])}
  end

  def render(assigns) do
    ~H"""
    <p id="greeting">{@mount.options.greeting} {@user}</p>
    <p id="hooks">{inspect(@hooks)}</p>
    <p id="session">{inspect(@session_name)}</p>
    <a id="item" href={~m"/items/#{42}"}>item</a>
    <a id="query" href={~m"/items/#{"a b"}?#{[page: 2]}"}>query</a>
    <.item_link />
    """
  end

  defp item_link(assigns) do
    ~H"""
    <a id="component" href={~m"/items/7"}>component</a>
    """
  end

  def handle_event("go", _params, socket) do
    {:noreply, push_navigate(socket, to: ~m"/items/9")}
  end
end

defmodule SampleLib.ItemLive do
  @moduledoc false
  use Phoenix.LiveView

  def mount(%{"id" => id}, _session, socket), do: {:ok, assign(socket, :id, id)}
  def render(assigns), do: ~H|<p id="item">{@id}</p>|
end

defmodule SampleLib.PublicLive do
  @moduledoc false
  use Phoenix.LiveView

  def mount(%{"token" => token}, _session, socket), do: {:ok, assign(socket, :token, token)}

  def render(assigns) do
    ~H"""
    <p id="token">{@token}</p>
    <p id="hooks">{inspect(@hooks)}</p>
    """
  end
end

defmodule SampleLib.ExportController do
  @moduledoc false
  use Phoenix.Controller, formats: [:html, :json]
  use PhoenixMountable.Path, mountable: SampleLib.Router

  def csv(conn, _params) do
    mount = PhoenixMountable.Mount.fetch!(conn)

    conn
    |> put_resp_content_type("text/csv")
    |> send_resp(
      200,
      "mount,#{mount.name},#{~m"/items/#{1}"},#{inspect(mount.csp_nonces[:script])}"
    )
  end

  def status(conn, _params), do: json(conn, %{mount: conn.assigns.mount.name})
end

defmodule SampleLib.ForwardedPlug do
  @moduledoc false
  @behaviour Plug
  def init(opts), do: opts

  def call(conn, opts) do
    Plug.Conn.send_resp(conn, 200, "#{opts[:greeting]} #{conn.assigns.mount.name}")
  end
end

defmodule PlainLib.Router do
  @moduledoc false
  # A library without LiveView routes: controllers and a host layout.
  use PhoenixMountable,
    otp_app: :phoenix_mountable,
    macro: :plain_lib,
    layout: :host,
    assets: {PhoenixMountable.Assets.Host, entries: [css: "/assets/app.css"]}

  routes do
    get "/", PlainLib.PageController, :index
    post "/echo", PlainLib.PageController, :echo
  end
end

defmodule PlainLib.PageController do
  @moduledoc false
  use Phoenix.Controller, formats: [:html]
  use PhoenixMountable.Path, mountable: PlainLib.Router

  def index(conn, _params) do
    html(
      conn,
      ~s(<a href="#{~m"/echo"}">echo</a> #{PhoenixMountable.HTML.asset_tags(conn.assigns.mount) |> Phoenix.HTML.safe_to_string()})
    )
  end

  def echo(conn, params), do: text(conn, params["value"])
end

defmodule StaticLib.Router do
  @moduledoc false
  use PhoenixMountable,
    otp_app: :phoenix_mountable,
    macro: :static_lib,
    layout: {PhoenixMountable.Layout, :root},
    assets:
      {PhoenixMountable.Assets.Static,
       from: "priv/test_fixtures/static", entries: [css: "app.css", js: "js/app.js"]}

  routes do
    live "/", StaticLib.PageLive, :index
  end
end

defmodule StaticLib.PageLive do
  @moduledoc false
  use Phoenix.LiveView
  def mount(_params, _session, socket), do: {:ok, socket}
  def render(assigns), do: ~H|<p id="static">static</p>|
end

defmodule ViteLib.Router do
  @moduledoc false
  use PhoenixMountable,
    otp_app: :phoenix_mountable,
    macro: :vite_lib,
    layout: {PhoenixMountable.Layout, :root},
    title: "Vite Lib",
    assets:
      {PhoenixMountable.Assets.Static,
       from: "priv/test_fixtures/vite",
       at: "/static",
       manifest: ".vite/manifest.json",
       entries: [app: {"src/main.tsx", :module}]}

  routes do
    live "/", StaticLib.PageLive, :index
  end
end

defmodule SampleLib.TestHost do
  @moduledoc false
  use PhoenixMountable.TestHost,
    mounts: [
      {SampleLib.Router, "/sample",
       resolver: SampleLib.TestResolver,
       greeting: "Hi",
       on_mount: [SampleLib.HostHook],
       csp_nonce_assign_key: %{script: :script_nonce, style: :style_nonce}},
      {SampleLib.Router, "/other", as: :other_sample, theme: :dark},
      {PlainLib.Router, "/plain"},
      {StaticLib.Router, "/static_lib"},
      {ViteLib.Router, "/vite", asset_host: nil}
    ],
    routes:
      (quote do
         scope "/admin" do
           pipe_through :browser
           require SampleLib.Router
           SampleLib.Router.sample_lib("/nested", as: :nested_sample)
         end
       end)
end
