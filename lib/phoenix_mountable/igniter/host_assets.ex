if Code.ensure_loaded?(Igniter) do
  defmodule PhoenixMountable.Igniter.HostAssets do
    @moduledoc """
    Edits of the host's `assets/js/app.js` and `assets/css/app.css`, for a
    library whose components render in the host's own pages (a button in
    its header, a palette, a picker) and need a LiveView hook and a style
    sheet there. `PhoenixMountable.Igniter.add_hook/4` and
    `PhoenixMountable.Igniter.add_css_imports/3` apply them.

    They are pure functions on the source of each file. Each returns:

      * `{:changed, source}` - the new source;
      * `:unchanged` - the file already has everything;
      * `{:manual, text}` - the edit cannot be made safely; `text` tells the
        person what to add.

    The `app.js` edit understands the `new LiveSocket(...)` of a generated
    Phoenix app and the usual variations: an options object with or without
    `hooks`, hooks as an object (with spreads, such as `colocatedHooks`) or
    as a variable. It ignores strings and comments. Anything else (hooks
    computed by a function, a quoted `"hooks"` key) is left to the person.
    """

    @type result :: {:changed, String.t()} | :unchanged | {:manual, String.t()}

    ## assets/js/app.js

    @doc """
    Adds `import { hook } from "package"` to the source of `app.js`, and
    `hook` to the hooks of its `new LiveSocket(...)`.

    Returns `{:changed, source}`, `:unchanged` when both are there, or
    `{:manual, text}` when the hooks cannot be edited safely (they are a
    computed value, or the call is not found): `text` tells the person what
    to add.
    """
    @spec app_js(String.t(), String.t(), String.t()) :: result()
    def app_js(source, hook, package) when is_binary(source) do
      # Any import that binds the hook, from the package or from another path.
      name = Regex.escape(hook)

      import? =
        Regex.match?(
          ~r/^import\s*(?:\{[^}]*\b#{name}\b[^}]*\}|#{name}\b[^\n]*?)\s*from\s*["']/m,
          source
        )

      case hooks(source, hook) do
        :error ->
          {:manual, app_js_manual(hook, package, import?)}

        {:ok, with_hooks} ->
          new =
            if import?, do: with_hooks, else: add_js_import(with_hooks, js_import(hook, package))

          if new == source, do: :unchanged, else: {:changed, new}
      end
    end

    defp js_import(hook, package), do: ~s(import { #{hook} } from "#{package}")

    @doc "The lines to add to `app.js` by hand."
    @spec app_js_manual(String.t(), String.t(), boolean()) :: String.t()
    def app_js_manual(hook, package, import? \\ false) do
      import_text =
        if import?,
          do: "",
          else: "Add the import to assets/js/app.js:\n\n    #{js_import(hook, package)}\n\n"

      import_text <>
        """
        Add #{hook} to the hooks of the LiveSocket in assets/js/app.js:

            const liveSocket = new LiveSocket("/live", Socket, {
              params: {_csrf_token: csrfToken},
              hooks: {...colocatedHooks, #{hook}},
            })
        """
    end

    # After the line where the last top-level import statement ends (an
    # import can span several lines), else at the top.
    defp add_js_import(source, line) do
      code = mask(source)

      case Regex.scan(~r/^import(?=[\s{*"'])/m, code, return: :index) |> List.last() do
        nil ->
          line <> "\n" <> source

        [{at, _length}] ->
          at = import_end(code, at)

          line_end =
            if newline = first_match(~r/\n/, rest(code, at)),
              do: at + elem(newline, 0),
              else: byte_size(code)

          splice(source, line_end, 0, "\n" <> line)
      end
    end

    # The index after the module specifier of the import at `at`: its first
    # string, whose text the mask keeps as spaces between the quotes.
    defp import_end(code, at) do
      case Regex.run(~r/["']/, rest(code, at), return: :index) do
        [{open, 1}] ->
          quote_char = binary_part(code, at + open, 1)
          from = at + open + 1

          case :binary.match(code, quote_char, scope: {from, byte_size(code) - from}) do
            {close, 1} -> close + 1
            :nomatch -> byte_size(code)
          end

        nil ->
          byte_size(code)
      end
    end

    defp rest(code, at), do: binary_part(code, at, byte_size(code) - at)

    # Finds the `hooks` of the options of `new LiveSocket(...)`, and adds
    # the hook to them. Returns `{:ok, source}` (the same source when the hook
    # is already there) or `:error`.
    defp hooks(source, hook) do
      code = mask(source)

      with {call, call_length} <- first_match(~r/\bnew\s+LiveSocket\s*\(/, code),
           open when is_integer(open) <- options_open(code, call + call_length),
           close when is_integer(close) <- close(code, open) do
        options = binary_part(code, open + 1, close - open - 1)

        top = top_level(options)

        cond do
          other_hooks_key?(source, open + 1, top) ->
            :error

          match = first_match(~r/(?<![\w$.])hooks\s*:\s*/, top) ->
            hooks_at(source, code, open, match, hook)

          true ->
            {:ok, insert_hooks_key(source, open, options, hook)}
        end
      else
        _other -> :error
      end
    end

    defp hooks_at(source, code, open, {at, length}, hook),
      do: hooks_value(source, code, open + 1 + at + length, hook)

    # A quoted `"hooks":` key, or the `hooks` shorthand, at the top level of
    # the options: the edit cannot see through it, so the person adds the hook.
    defp other_hooks_key?(source, offset, top) do
      quoted =
        ~r/(["'])\s{5}\1\s*:/
        |> Regex.scan(top, return: :index)
        |> Enum.any?(fn [{at, _length} | _group] ->
          Regex.match?(~r/^["']hooks["']/, binary_part(source, offset + at, 7))
        end)

      quoted or Regex.match?(~r/(?:^|,)\s*hooks\s*(?:,|$)/, top)
    end

    # The first `{` among the arguments of the call, before its `)`.
    defp options_open(code, from), do: scan_to_brace(code, from, 0)

    defp scan_to_brace(code, at, _depth) when at >= byte_size(code), do: nil

    defp scan_to_brace(code, at, depth) do
      case :binary.at(code, at) do
        ?{ when depth == 0 -> at
        char when char in [?(, ?[, ?{] -> scan_to_brace(code, at + 1, depth + 1)
        ?) when depth == 0 -> nil
        char when char in [?), ?], ?}] -> scan_to_brace(code, at + 1, depth - 1)
        _char -> scan_to_brace(code, at + 1, depth)
      end
    end

    defp insert_hooks_key(source, open, options, hook) do
      {text, replaced} =
        cond do
          String.trim(options) == "" ->
            {"hooks: {#{hook}}", byte_size(options)}

          String.contains?(options, "\n") ->
            [_first, line | _rest] = String.split(options, "\n")
            [indent] = Regex.run(~r/^[ \t]*/, line)
            {"\n" <> indent <> "hooks: {#{hook}},", 0}

          true ->
            {"hooks: {#{hook}}, ", 0}
        end

      splice(source, open + 1, replaced, text)
    end

    defp hooks_value(source, code, at, hook) do
      name = Regex.escape(hook)
      rest = binary_part(code, at, byte_size(code) - at)

      cond do
        String.starts_with?(rest, "{") ->
          close = close(code, at)
          inner = binary_part(source, at + 1, close - at - 1)

          if Regex.match?(~r/(?<![\w$.])#{name}\b/, binary_part(code, at + 1, close - at - 1)),
            do: {:ok, source},
            else: {:ok, splice(source, at + 1, close - at - 1, add_to_object(inner, hook))}

        match = Regex.run(~r/^([A-Za-z_$][\w$]*)\s*(?=[,}\n])/, rest) ->
          [whole, object] = match

          if Regex.match?(
               ~r/\b#{Regex.escape(object)}\s*(\.\s*#{name}|\[\s*["']#{name}["']\s*\])\s*=/,
               code
             ),
             do: {:ok, source},
             else:
               {:ok,
                splice(
                  source,
                  at,
                  byte_size(String.trim_trailing(whole)),
                  "{...#{object}, #{hook}}"
                )}

        true ->
          :error
      end
    end

    defp add_to_object(inner, hook) do
      trimmed = String.trim_trailing(inner)
      trailing = binary_part(inner, byte_size(trimmed), byte_size(inner) - byte_size(trimmed))

      cond do
        String.trim(inner) == "" ->
          hook

        String.contains?(inner, "\n") ->
          last = trimmed |> String.split("\n") |> List.last()
          [indent] = Regex.run(~r/^[ \t]*/, last)
          comma = if String.ends_with?(trimmed, ","), do: "", else: ","
          trimmed <> comma <> "\n" <> indent <> hook <> "," <> trailing

        String.ends_with?(trimmed, ",") ->
          trimmed <> " " <> hook <> trailing

        true ->
          trimmed <> ", " <> hook <> trailing
      end
    end

    defp splice(source, at, length, text) do
      binary_part(source, 0, at) <>
        text <>
        binary_part(source, at + length, byte_size(source) - at - length)
    end

    # Replaces the text of strings and comments with spaces, byte for byte,
    # so that the positions stay the same and brackets in them do not count.
    defp mask(source), do: source |> mask(:code, []) |> IO.iodata_to_binary()

    defp mask(<<>>, _state, acc), do: Enum.reverse(acc)
    defp mask(<<"//", rest::binary>>, :code, acc), do: mask(rest, :line, ["  " | acc])
    defp mask(<<"/*", rest::binary>>, :code, acc), do: mask(rest, :block, ["  " | acc])

    defp mask(<<q, rest::binary>>, :code, acc) when q in [?", ?', ?`],
      do: mask(rest, {:string, q}, [q | acc])

    defp mask(<<c, rest::binary>>, :code, acc), do: mask(rest, :code, [c | acc])
    defp mask(<<?\n, rest::binary>>, :line, acc), do: mask(rest, :code, [?\n | acc])
    defp mask(<<"*/", rest::binary>>, :block, acc), do: mask(rest, :code, ["  " | acc])
    defp mask(<<?\n, rest::binary>>, :block, acc), do: mask(rest, :block, [?\n | acc])

    defp mask(<<_c, rest::binary>>, state, acc) when state in [:line, :block],
      do: mask(rest, state, [?\s | acc])

    defp mask(<<?\\, _c, rest::binary>>, {:string, _q} = state, acc),
      do: mask(rest, state, ["  " | acc])

    defp mask(<<q, rest::binary>>, {:string, q}, acc), do: mask(rest, :code, [q | acc])

    defp mask(<<?\n, rest::binary>>, {:string, _q} = state, acc),
      do: mask(rest, state, [?\n | acc])

    defp mask(<<_c, rest::binary>>, {:string, _q} = state, acc),
      do: mask(rest, state, [?\s | acc])

    # The index of the bracket that closes the one at `open`, in masked code.
    defp close(code, open), do: close(code, open + 1, 1)
    defp close(code, at, _depth) when at >= byte_size(code), do: nil

    defp close(code, at, depth) do
      case :binary.at(code, at) do
        char when char in [?(, ?[, ?{] -> close(code, at + 1, depth + 1)
        char when char in [?), ?], ?}] and depth == 1 -> at
        char when char in [?), ?], ?}] -> close(code, at + 1, depth - 1)
        _char -> close(code, at + 1, depth)
      end
    end

    # Masked code with the text inside nested brackets replaced by spaces.
    defp top_level(code) do
      {chars, _depth} =
        code
        |> :binary.bin_to_list()
        |> Enum.map_reduce(0, fn
          char, depth when char in [?(, ?[, ?{] ->
            {if(depth == 0, do: char, else: ?\s), depth + 1}

          char, depth when char in [?), ?], ?}] ->
            {if(depth == 1, do: char, else: ?\s), depth - 1}

          ?\n, depth ->
            {?\n, depth}

          char, 0 ->
            {char, 0}

          _char, depth ->
            {?\s, depth}
        end)

      :binary.list_to_bin(chars)
    end

    defp first_match(regex, text) do
      case Regex.run(regex, text, return: :index) do
        [{at, length} | _groups] -> {at, length}
        nil -> nil
      end
    end

    ## assets/css/app.css

    @doc """
    Adds `@import` lines to the source of `app.css`, after its last
    top-level `@import` (else after a `@charset`, else at the top).

    `imports` are `{path, :import}` or `{path, :comment}`: a commented import
    is an option the person turns on (a theme), added only with the first
    import of the list, so that a person who removed it does not get it back.
    An import already in the source, commented or not, is not added again.
    """
    @spec app_css(String.t(), [{String.t(), :import | :comment}]) :: result()
    def app_css(source, [{first, _kind} | _rest] = imports) when is_binary(source) do
      if String.contains?(source, first) do
        :unchanged
      else
        added =
          for {path, kind} <- imports, not String.contains?(source, path) do
            css_line(path, kind)
          end

        lines = String.split(source, "\n")
        {head, tail} = Enum.split(lines, css_insert_at(lines))
        {:changed, Enum.join(head ++ added ++ tail, "\n")}
      end
    end

    @doc "The lines to add to `app.css` by hand."
    @spec app_css_manual([{String.t(), :import | :comment}]) :: String.t()
    def app_css_manual(imports) do
      """
      Add these lines to assets/css/app.css, below its other @import lines:

      #{Enum.map_join(imports, "\n", fn {path, kind} -> "    " <> css_line(path, kind) end)}
      """
    end

    defp css_line(path, :import), do: ~s(@import "#{path}";)
    defp css_line(path, :comment), do: ~s(/* @import "#{path}"; */)

    # After the last top-level @import, else after a @charset, else at the top.
    defp css_insert_at(lines) do
      case last_index(lines, &Regex.match?(~r/^@import\b/, &1)) do
        nil ->
          case last_index(lines, &Regex.match?(~r/^@charset\b/, &1)) do
            nil -> 0
            index -> index + 1
          end

        index ->
          index + 1
      end
    end

    defp last_index(list, fun) do
      list
      |> Enum.with_index()
      |> Enum.filter(fn {item, _index} -> fun.(item) end)
      |> List.last()
      |> case do
        nil -> nil
        {_item, index} -> index
      end
    end

    ## Paths

    @doc """
    The path from the directory `from` to `path`, with `..` where it must go
    up: the form an `@import` of `assets/css/app.css` needs.

        iex> PhoenixMountable.Igniter.HostAssets.relative("deps/my_lib", "assets/css")
        "../../deps/my_lib"

    """
    @spec relative(Path.t(), Path.t()) :: String.t()
    def relative(path, from),
      do: Path.relative_to(Path.expand(path), Path.expand(from), force: true)

    @doc """
    Whether the esbuild config of the host resolves packages from `deps/`
    (`"NODE_PATH" => [... "../deps" ...]`), as a generated Phoenix app does.
    """
    @spec node_path?(String.t()) :: boolean()
    def node_path?(config_source) do
      Regex.match?(~r/"NODE_PATH"\s*=>[^\n]*deps/, config_source)
    end
  end
end
