if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule PhoenixMountable.Layout do
    @moduledoc """
    Components for a library's root layout, and a ready-made root layout.

    A library with a document of its own (`layout: {MyLib.Layouts, :root}`)
    renders the tags its page needs with these components:

        <!DOCTYPE html>
        <html lang="en">
          <head>
            <meta charset="utf-8" />
            <PhoenixMountable.Layout.meta mount={@mount} />
            <PhoenixMountable.Layout.assets mount={@mount} />
            <.live_title>{assigns[:page_title] || "My Lib"}</.live_title>
          </head>
          <body>{@inner_content}</body>
        </html>

    Or it uses `layout: {PhoenixMountable.Layout, :root}`, which renders that,
    titled after the `:title` option of `use PhoenixMountable`.

    Libraries without LiveView use `PhoenixMountable.HTML` in EEx templates.
    """

    use Phoenix.Component

    @doc """
    The `<meta>` tags the library's JavaScript reads: the CSRF token, the
    LiveView socket path and transport, and the mount path. The browser helper
    `PhoenixMountable.connect()` reads them.
    """
    attr :mount, PhoenixMountable.Mount, required: true

    def meta(assigns) do
      ~H"""
      <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
      <meta name="live-path" content={@mount.socket_path} />
      <meta name="live-transport" content={@mount.transport} />
      <meta name="phoenix-mountable-prefix" content={PhoenixMountable.Path.path(@mount, "/")} />
      """
    end

    @doc """
    Tags for the mount's asset entries, with the request's CSP nonces and
    `phx-track-static`.
    """
    attr :mount, PhoenixMountable.Mount, required: true
    attr :only, :list, default: nil, doc: "the entry names to render, all by default"

    def assets(assigns) do
      assigns =
        assign(
          assigns,
          :entries,
          for(
            entry <- PhoenixMountable.Assets.entries(assigns.mount),
            assigns.only == nil or entry.name in assigns.only,
            do: entry
          )
        )

      ~H"""
      <%= for entry <- @entries do %>
        <link
          :if={entry.kind == :css}
          rel="stylesheet"
          href={entry.url}
          nonce={@mount.csp_nonces[:style]}
          phx-track-static
        />
        <script
          :if={entry.kind == :js}
          src={entry.url}
          nonce={@mount.csp_nonces[:script]}
          defer
          phx-track-static
        >
        </script>
        <script
          :if={entry.kind == :module}
          type="module"
          src={entry.url}
          nonce={@mount.csp_nonces[:script]}
          phx-track-static
        >
        </script>
      <% end %>
      """
    end

    @doc """
    A complete root layout: meta tags, assets and a title.
    """
    def root(assigns) do
      ~H"""
      <!DOCTYPE html>
      <html lang="en">
        <head>
          <meta charset="utf-8" />
          <meta name="viewport" content="width=device-width, initial-scale=1" />
          <.meta mount={@mount} />
          <.assets mount={@mount} />
          <.live_title default={@mount.definition.__phoenix_mountable__(:title)}>
            {assigns[:page_title]}
          </.live_title>
        </head>
        <body>
          {@inner_content}
        </body>
      </html>
      """
    end
  end
end
