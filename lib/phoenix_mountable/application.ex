defmodule PhoenixMountable.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: PhoenixMountable.Registry},
      {DynamicSupervisor, name: PhoenixMountable.MountSupervisor, strategy: :one_for_one},
      {Task.Supervisor, name: PhoenixMountable.TaskSupervisor}
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: PhoenixMountable.ApplicationSupervisor
    )
  end
end
