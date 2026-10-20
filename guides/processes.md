# Processes

A Rails engine runs inside requests; a mountable library runs on the
BEAM, so it can keep state, schedule work and talk to other nodes
without Redis or a job queue.

## Children of a mount

```elixir
@impl PhoenixMountable
def children(mount) do
  [
    {MyLib.Cache, name: PhoenixMountable.via(mount, :cache)},
    {MyLib.Poller, mount: mount}
  ]
end
```

Each mount gets a supervisor of its own, so two mounts of the library
never share state, and a crash stays inside the library's subtree.

By default the processes start the first time the mount is used: a
request or a LiveView. That suits caches and per-user state. A host that
needs them from boot (a scheduler, a poller) adds the supervisor to its
application, after its endpoint:

```elixir
children = [
  MyApp.Repo,
  MyAppWeb.Endpoint,
  {PhoenixMountable.Supervisor, router: MyAppWeb.Router, endpoint: MyAppWeb.Endpoint}
]
```

The router knows its mounts at compile time, so nothing else is listed.

## PubSub

```elixir
PhoenixMountable.PubSub.subscribe(socket.assigns.mount, "items")
PhoenixMountable.PubSub.broadcast(mount, "items", {:item_updated, item})
```

Topics are scoped to the mount and travel across the cluster. The server
is the mount's `:pubsub` option, or the endpoint's.

## Once per cluster

```elixir
def children(mount) do
  [
    {PhoenixMountable.Singleton,
     name: {:scheduler, PhoenixMountable.Mount.key(mount)},
     child: {MyLib.Scheduler, mount: mount}}
  ]
end
```

Every node runs a `PhoenixMountable.Singleton`; the one that registers
the name globally starts the child, and the others take over when its
node goes down.

## Telemetry

PhoenixMountable emits events for mounts, processes, stale assets,
migrations and backfills. See `PhoenixMountable.Telemetry`.
