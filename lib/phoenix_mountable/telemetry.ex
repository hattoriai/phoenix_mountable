defmodule PhoenixMountable.Telemetry do
  @moduledoc """
  Telemetry events emitted by PhoenixMountable.

  All events start with `:phoenix_mountable`.

    * `[:phoenix_mountable, :mount, :live]` — a library LiveView mounted.
      Measurements: `:system_time`. Metadata: `:mount`, `:handler` (the
      LiveView module).
    * `[:phoenix_mountable, :mount, :request]` — a request reached a library
      controller or plug route. Measurements: `:system_time`. Metadata:
      `:mount`, `:handler`.
    * `[:phoenix_mountable, :children, :start]` — the processes of a mount
      started. Measurements: `:count`. Metadata: `:mount`.
    * `[:phoenix_mountable, :assets, :stale]` — a page with assets of a
      previous build reconnected and is being reloaded. Metadata: `:mount`.
    * `[:phoenix_mountable, :migration, :start | :stop]` — a library's
      migrations ran. Measurements: `:system_time` / `:duration`. Metadata:
      `:library`, `:direction`, `:from`, `:to`, `:repo`, `:prefix`.
    * `[:phoenix_mountable, :backfill, :batch]` — a backfill processed a batch.
      Measurements: `:count`, `:duration`. Metadata: `:library`, `:backfill`.
    * `[:phoenix_mountable, :backfill, :stop]` — a backfill finished.
      Metadata: `:library`, `:backfill`, `:status`.
  """

  @doc false
  def execute(event, measurements, metadata) do
    :telemetry.execute([:phoenix_mountable | event], measurements, metadata)
  end
end
