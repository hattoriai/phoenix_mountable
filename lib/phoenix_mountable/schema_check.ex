defmodule PhoenixMountable.SchemaCheck do
  @moduledoc false
  # Checks, the first time a mount is used on a node, that the host has run
  # the library's migrations (the `:schema` option of `use PhoenixMountable`).
  #
  # An outdated schema, older than the library can run against, raises with
  # the command that fixes it. A pending upgrade logs a warning once, or
  # raises with `config :phoenix_mountable, pending_migrations: :raise`, which
  # hosts set in their test config so CI catches a forgotten upgrade.

  require Logger

  alias PhoenixMountable.Mount

  @doc false
  def ensure_checked(%Mount{definition: definition} = mount) do
    with schema when schema != nil <- definition.__phoenix_mountable__(:schema),
         repo when repo != nil <- repo(definition, mount) do
      prefix = Mount.option(mount, :prefix)
      key = {__MODULE__, schema, repo, prefix}

      # A healthy or pending schema is checked once per node. An outdated one
      # is checked again on every use, so running the migration while the app
      # runs (in development) takes effect without a restart.
      case :persistent_term.get(key, nil) do
        nil ->
          result = check(schema, repo, prefix)
          if result == :ok or match?({:pending, _}, result), do: :persistent_term.put(key, result)
          act(result, key)

        result ->
          act(result, key)
      end
    end

    :ok
  end

  defp repo(definition, mount) do
    if function_exported?(definition, :repo, 1) do
      definition.repo(mount)
    else
      Mount.option(mount, :repo)
    end
  end

  defp check(schema, repo, prefix) do
    schema.check(repo: repo, prefix: prefix)
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp act(:ok, _key), do: :ok

  defp act({:outdated, message}, _key),
    do: raise(PhoenixMountable.Migrations.OutdatedError, message)

  defp act({:pending, message}, key) do
    case Application.get_env(:phoenix_mountable, :pending_migrations, :warn) do
      :raise -> raise PhoenixMountable.Migrations.OutdatedError, message
      :warn -> once(key, fn -> Logger.warning(message) end)
      false -> :ok
    end
  end

  defp act({:error, message}, key) do
    once(key, fn ->
      Logger.error("could not check the schema of a PhoenixMountable library: " <> message)
    end)
  end

  defp once(key, fun) do
    if not :persistent_term.get({key, :reported}, false) do
      :persistent_term.put({key, :reported}, true)
      fun.()
    end

    :ok
  end
end
