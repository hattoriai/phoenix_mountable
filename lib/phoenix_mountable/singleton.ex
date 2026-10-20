defmodule PhoenixMountable.Singleton do
  @moduledoc """
  Runs a process once per cluster.

  Add it to a mount's children to run one instance of a process across all
  nodes, such as a scheduler that must not run twice:

      def children(mount) do
        [
          {PhoenixMountable.Singleton,
           name: {:refresh_scheduler, PhoenixMountable.Mount.key(mount)},
           child: {MyLib.RefreshScheduler, mount: mount}}
        ]
      end

  Every node runs a `Singleton`. The first to register `:name` globally owns
  it and starts the child; the others watch the owner. When the owner's node
  goes down, the next one registers and starts the child. A child that exits
  is restarted by its owner. On a single node it simply runs the child.

  `whereis/1` returns the child, on whichever node it runs.

  ## Options

    * `:name` (required) — a term naming the singleton across the cluster.
    * `:child` (required) — the child spec of the process.
    * `:retry` — milliseconds before restarting a child that failed to start
      or exited. Defaults to `1_000`.
  """

  use GenServer

  require Logger

  @doc false
  def child_spec(opts) do
    %{id: {__MODULE__, Keyword.fetch!(opts, :name)}, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  The pid of the singleton's child named `name`, on any node, or `nil`.
  """
  @spec whereis(term) :: pid | nil
  def whereis(name) do
    case :global.whereis_name({__MODULE__, name}) do
      :undefined -> nil
      owner -> GenServer.call(owner, :child)
    end
  catch
    :exit, _ -> nil
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      name: Keyword.fetch!(opts, :name),
      child: Supervisor.child_spec(Keyword.fetch!(opts, :child), []),
      retry: Keyword.get(opts, :retry, 1_000),
      pid: nil,
      owner_ref: nil
    }

    {:ok, state, {:continue, :claim}}
  end

  @impl true
  def handle_continue(:claim, state), do: {:noreply, claim(state)}

  @impl true
  def handle_call(:child, _from, state), do: {:reply, state.pid, state}

  @impl true
  def handle_info(:claim, state), do: {:noreply, claim(state)}
  def handle_info(:start_child, state), do: {:noreply, start_child(state)}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    {:noreply, claim(%{state | owner_ref: nil})}
  end

  def handle_info({:EXIT, pid, reason}, %{pid: pid} = state) do
    Logger.warning("singleton #{inspect(state.name)} exited: #{inspect(reason)}")
    Process.send_after(self(), :start_child, state.retry)
    {:noreply, %{state | pid: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{pid: pid}) when is_pid(pid), do: Process.exit(pid, :shutdown)
  def terminate(_reason, _state), do: :ok

  # Register the name first, then start the child: the child never runs on
  # two nodes at once. A node that loses the race watches the owner.
  defp claim(%{name: name} = state) do
    case :global.register_name({__MODULE__, name}, self()) do
      :yes ->
        start_child(state)

      :no ->
        case :global.whereis_name({__MODULE__, name}) do
          :undefined ->
            send(self(), :claim)
            state

          owner ->
            %{state | owner_ref: Process.monitor(owner)}
        end
    end
  end

  defp start_child(%{child: %{start: {mod, fun, args}}} = state) do
    case apply(mod, fun, args) do
      {:ok, pid} ->
        %{state | pid: pid}

      other ->
        Logger.error("could not start singleton #{inspect(state.name)}: #{inspect(other)}")
        Process.send_after(self(), :start_child, state.retry)
        state
    end
  end
end
