if Code.ensure_loaded?(Phoenix.HTML) and Code.ensure_loaded?(Phoenix.Router) do
  defmodule PhoenixMountable.HTML do
    @moduledoc """
    Tags for a library's own root layout, usable from any template engine.

    These functions return safe HTML, so they work in EEx templates of a
    library that does not use LiveView as well as in HEEx. LiveView libraries
    can use the components in `PhoenixMountable.Layout` instead.

        <%= PhoenixMountable.HTML.meta_tags(@mount) %>
        <%= PhoenixMountable.HTML.asset_tags(@mount) %>
    """

    alias PhoenixMountable.{Assets, Mount}

    @doc """
    The `<meta>` tags a library's JavaScript reads: the CSRF token, the LiveView
    socket path and transport, and the mount path (`phoenix-mountable-prefix`).

    The browser helper (`PhoenixMountable.connect()` in JavaScript) reads them.
    """
    @spec meta_tags(Mount.t()) :: Phoenix.HTML.safe()
    def meta_tags(%Mount{} = mount) do
      [
        meta("csrf-token", Plug.CSRFProtection.get_csrf_token()),
        meta("live-path", mount.socket_path),
        meta("live-transport", to_string(mount.transport)),
        meta("phoenix-mountable-prefix", PhoenixMountable.Path.path(mount, "/"))
      ]
      |> Enum.intersperse("\n")
      |> Phoenix.HTML.raw()
    end

    @doc """
    `<link>` and `<script>` tags for the mount's asset entries, with the
    request's CSP nonces and `phx-track-static`.

    ## Options

      * `:only` — the entry names to render. Defaults to all.
      * `:track_static` — add `phx-track-static`. Defaults to `true`.
    """
    @spec asset_tags(Mount.t(), keyword) :: Phoenix.HTML.safe()
    def asset_tags(%Mount{} = mount, opts \\ []) do
      only = Keyword.get(opts, :only)
      track = Keyword.get(opts, :track_static, true)

      mount
      |> Assets.entries()
      |> Enum.filter(&(only == nil or &1.name in only))
      |> Enum.map(&asset_tag(&1, mount.csp_nonces, track))
      |> Enum.intersperse("\n")
      |> Phoenix.HTML.raw()
    end

    defp asset_tag(%{kind: :css, url: url}, nonces, track) do
      tag("link", [rel: "stylesheet", href: url, nonce: nonces[:style]] ++ track(track), false)
    end

    defp asset_tag(%{kind: :module, url: url}, nonces, track) do
      tag("script", [type: "module", src: url, nonce: nonces[:script]] ++ track(track), true)
    end

    defp asset_tag(%{kind: _, url: url}, nonces, track) do
      tag("script", [src: url, defer: true, nonce: nonces[:script]] ++ track(track), true)
    end

    defp track(true), do: ["phx-track-static": true]
    defp track(false), do: []

    defp meta(name, content), do: tag("meta", [name: name, content: content], false)

    defp tag(name, attrs, close?) do
      attrs =
        attrs
        |> Enum.reject(fn {_k, v} -> v in [nil, false] end)
        |> Phoenix.HTML.attributes_escape()

      attrs = Phoenix.HTML.safe_to_string(attrs)
      if close?, do: "<#{name}#{attrs}></#{name}>", else: "<#{name}#{attrs}>"
    end
  end
end
