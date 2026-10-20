defmodule PhoenixMountable.Supervisor do
  @moduledoc """
  Starts the processes of every mount of a host router when the host boots.

  By default, a mount's processes (`c:PhoenixMountable.children/1`) start the
  first time the mount is used: the first request or LiveView. That suits
  caches and per-user state, but a scheduler or a poller would not run until
  someone opens the library. A host that wants them running from boot adds
  this supervisor to its application, after its repo and endpoint:

      children = [
        MyApp.Repo,
        MyAppWeb.Endpoint,
        {PhoenixMountable.Supervisor, router: MyAppWeb.Router, endpoint: MyAppWeb.Endpoint}
      ]

  The router knows its mounts at compile time, so nothing else is listed. The
  processes then live in the host's supervision tree, under the host's restart
  rules.

  ## Options

    * `:router` (required) — the host router.
    * `:endpoint` — the host endpoint, set as `mount.endpoint` for the
      processes (needed by `PhoenixMountable.PubSub` without a `:pubsub`
      option).
    * `:name` — the supervisor name.
  """

  use Supervisor

  alias PhoenixMountable.Children

  @doc false
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    Supervisor.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @impl true
  def init(opts) do
    router = Keyword.fetch!(opts, :router)
    endpoint = Keyword.get(opts, :endpoint)

    if not function_exported?(Code.ensure_compiled!(router), :__phoenix_mountable_mounts__, 0) do
      raise ArgumentError, "#{inspect(router)} has no PhoenixMountable mounts"
    end

    children =
      for mount <- router.__phoenix_mountable_mounts__(),
          Children.has_children?(mount.definition) do
        mount = %{mount | endpoint: endpoint}

        %{
          id: {:mount, mount.name},
          start: {__MODULE__, :start_tree, [mount]},
          type: :supervisor
        }
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc false
  def start_tree(mount) do
    case Children.Tree.start_link(mount) do
      {:error, {:already_started, _pid}} -> :ignore
      other -> other
    end
  end
end
