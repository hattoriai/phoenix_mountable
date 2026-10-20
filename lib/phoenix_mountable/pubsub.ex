if Code.ensure_loaded?(Phoenix.PubSub) do
  defmodule PhoenixMountable.PubSub do
    @moduledoc """
    PubSub topics scoped to a mount.

    Users of the same mount see each other's changes live; two mounts of the
    same library (or two libraries) never share a topic. Messages travel across
    the cluster like any `Phoenix.PubSub` message.

        # in a LiveView of the library
        PhoenixMountable.PubSub.subscribe(socket.assigns.mount, "items")

        # anywhere, after a change
        PhoenixMountable.PubSub.broadcast(mount, "items", {:item_updated, item})

    The PubSub server is the mount's `:pubsub` option, or the host endpoint's
    `:pubsub_server`.
    """

    alias PhoenixMountable.Mount

    @doc """
    The full topic name for `topic` in the mount.
    """
    @spec topic(Mount.t(), String.t()) :: String.t()
    def topic(%Mount{} = mount, topic) when is_binary(topic) do
      "phoenix_mountable:#{inspect(mount.router)}:#{mount.name}:#{topic}"
    end

    @doc "Subscribes the caller to `topic` in the mount."
    @spec subscribe(Mount.t(), String.t()) :: :ok | {:error, term}
    def subscribe(mount, topic), do: Phoenix.PubSub.subscribe(server!(mount), topic(mount, topic))

    @doc "Unsubscribes the caller from `topic` in the mount."
    @spec unsubscribe(Mount.t(), String.t()) :: :ok
    def unsubscribe(mount, topic),
      do: Phoenix.PubSub.unsubscribe(server!(mount), topic(mount, topic))

    @doc "Broadcasts `message` to the subscribers of `topic` in the mount, on all nodes."
    @spec broadcast(Mount.t(), String.t(), term) :: :ok | {:error, term}
    def broadcast(mount, topic, message),
      do: Phoenix.PubSub.broadcast(server!(mount), topic(mount, topic), message)

    @doc "Like `broadcast/3`, but not to the caller."
    @spec broadcast_from(Mount.t(), String.t(), term) :: :ok | {:error, term}
    def broadcast_from(mount, topic, message),
      do: Phoenix.PubSub.broadcast_from(server!(mount), self(), topic(mount, topic), message)

    @doc "Like `broadcast/3`, but only on this node."
    @spec local_broadcast(Mount.t(), String.t(), term) :: :ok
    def local_broadcast(mount, topic, message),
      do: Phoenix.PubSub.local_broadcast(server!(mount), topic(mount, topic), message)

    @doc """
    The PubSub server of the mount.
    """
    @spec server!(Mount.t()) :: atom
    def server!(%Mount{pubsub: pubsub}) when pubsub != nil, do: pubsub

    def server!(%Mount{endpoint: endpoint} = mount) when endpoint != nil do
      endpoint.config(:pubsub_server) ||
        raise ArgumentError,
              "#{inspect(endpoint)} has no :pubsub_server; pass :pubsub to the mount #{inspect(mount.name)}"
    end

    def server!(%Mount{name: name}) do
      raise ArgumentError,
            "mount #{inspect(name)} has no endpoint or :pubsub option. Pass :pubsub to the mount, " <>
              "or :endpoint to PhoenixMountable.Supervisor for processes started at boot."
    end
  end
end
