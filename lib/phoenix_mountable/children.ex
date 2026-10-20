defmodule PhoenixMountable.Children do
  @moduledoc false
  # The processes of each mount (`c:PhoenixMountable.children/1`).
  #
  # Each mount gets a supervisor of its own, registered under the mount's key.
  # Lazily, it starts under PhoenixMountable's DynamicSupervisor the first time
  # the mount is used, as `:temporary`: a mount whose processes keep crashing
  # stops on its own and starts again on the next use, instead of taking
  # PhoenixMountable (and every other library's mounts) down with it. Eagerly,
  # the host starts it in its own tree with `PhoenixMountable.Supervisor`.

  require Logger

  alias PhoenixMountable.Mount

  @doc false
  def ensure_started(%Mount{definition: definition} = mount) do
    if has_children?(definition) do
      case whereis(mount) do
        nil -> start_lazily(mount)
        pid -> {:ok, pid}
      end
    else
      :ignore
    end
  end

  @doc false
  def has_children?(definition) do
    Code.ensure_loaded?(definition) and function_exported?(definition, :children, 1)
  end

  @doc false
  def whereis(%Mount{} = mount) do
    # Registry removes the entry of a stopped process asynchronously.
    case Registry.lookup(PhoenixMountable.Registry, tree_key(mount)) do
      [{pid, _}] -> if Process.alive?(pid), do: pid
      [] -> nil
    end
  end

  defp start_lazily(mount, attempts \\ 10) do
    spec = Supervisor.child_spec({__MODULE__.Tree, mount}, restart: :temporary)

    case DynamicSupervisor.start_child(PhoenixMountable.MountSupervisor, spec) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        if Process.alive?(pid) or attempts == 0 do
          {:ok, pid}
        else
          Process.sleep(1)
          start_lazily(mount, attempts - 1)
        end

      {:error, reason} = error ->
        Logger.error(
          "could not start the processes of mount #{inspect(mount.name)} " <>
            "(#{inspect(mount.definition)}): #{inspect(reason)}"
        )

        error
    end
  end

  @doc false
  def tree_key(mount), do: {:mount_tree, Mount.key(mount)}

  @doc false
  # The mount the processes see: the static mount, without the values of the
  # request that happened to start them.
  def clean(%Mount{} = mount), do: %{mount | csp_nonces: %{}, session: nil}

  defmodule Tree do
    @moduledoc false
    use Supervisor

    alias PhoenixMountable.Children

    def start_link(mount) do
      mount = Children.clean(mount)
      name = {:via, Registry, {PhoenixMountable.Registry, Children.tree_key(mount)}}
      Supervisor.start_link(__MODULE__, mount, name: name)
    end

    @impl true
    def init(mount) do
      children = mount.definition.children(mount)

      PhoenixMountable.Telemetry.execute([:children, :start], %{count: length(children)}, %{
        mount: mount
      })

      Supervisor.init(children, strategy: :one_for_one)
    end
  end
end
