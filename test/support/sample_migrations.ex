defmodule PhoenixMountable.TestRepo.Postgres do
  @moduledoc false
  use Ecto.Repo, otp_app: :phoenix_mountable, adapter: Ecto.Adapters.Postgres
end

defmodule PhoenixMountable.TestRepo.MySQL do
  @moduledoc false
  use Ecto.Repo, otp_app: :phoenix_mountable, adapter: Ecto.Adapters.MyXQL
end

defmodule PhoenixMountable.TestRepo.SQLite do
  @moduledoc false
  use Ecto.Repo, otp_app: :phoenix_mountable, adapter: Ecto.Adapters.SQLite3
end

defmodule SampleLib.Backfills.Slugs do
  @moduledoc false
  use PhoenixMountable.Backfill,
    table: "sample_items",
    where: "slug IS NULL",
    set: "slug = LOWER(title)",
    batch_size: 2
end

defmodule SampleLib.Migrations.V1 do
  @moduledoc false
  use PhoenixMountable.Migration, description: "Items"

  def up(ctx) do
    create table(:sample_items, primary_key: primary_key(ctx), prefix: ctx.prefix) do
      add :title, :string
      add :legacy_flag, :boolean, default: false
    end

    create index(:sample_items, [:title], prefix: ctx.prefix)
  end

  def down(ctx) do
    drop table(:sample_items, prefix: ctx.prefix)
  end
end

defmodule SampleLib.Migrations.V2 do
  @moduledoc false
  use PhoenixMountable.Migration, description: "Item slugs"

  def up(ctx) do
    alter table(:sample_items, prefix: ctx.prefix) do
      add :slug, :string
    end

    backfill(ctx, SampleLib.Backfills.Slugs)
  end

  def down(%{adapter: :sqlite} = ctx) do
    rebuild_table(ctx, :sample_items, remove: [:slug])
  end

  def down(ctx) do
    alter table(:sample_items, prefix: ctx.prefix) do
      remove :slug
    end
  end
end

defmodule SampleLib.Migrations.V3 do
  @moduledoc false
  use PhoenixMountable.Migration, description: "Find items by slug"

  def up(ctx), do: create_concurrently(index(:sample_items, [:slug], prefix: ctx.prefix))
  def down(ctx), do: drop_concurrently(index(:sample_items, [:slug], prefix: ctx.prefix))
end

defmodule SampleLib.Migrations.V4 do
  @moduledoc false
  use PhoenixMountable.Migration,
    safety: :contract,
    description: "Require titles, drop the legacy flag",
    requires_backfills: [SampleLib.Backfills.Slugs]

  def up(%{adapter: :sqlite} = ctx) do
    rebuild_table(ctx, :sample_items, modify: [title: [null: false]], remove: [:legacy_flag])
  end

  def up(ctx) do
    alter table(:sample_items, prefix: ctx.prefix) do
      modify :title, :string, null: false
      remove :legacy_flag
    end
  end

  def down(%{adapter: :sqlite} = ctx) do
    rebuild_table(ctx, :sample_items, modify: [title: [null: true]])

    alter table(:sample_items, prefix: ctx.prefix) do
      add :legacy_flag, :boolean, default: false
    end
  end

  def down(ctx) do
    alter table(:sample_items, prefix: ctx.prefix) do
      modify :title, :string, null: true
      add :legacy_flag, :boolean, default: false
    end
  end
end

defmodule SampleLib.Migrations.Baseline do
  @moduledoc false
  use PhoenixMountable.Migration, baseline: 4

  def up(ctx) do
    create table(:sample_items, primary_key: primary_key(ctx), prefix: ctx.prefix) do
      add :title, :string, null: false
      add :slug, :string
    end

    create index(:sample_items, [:title], prefix: ctx.prefix)
    create index(:sample_items, [:slug], prefix: ctx.prefix)
  end
end

defmodule SampleLib.Migrations.Legacy do
  @moduledoc false
  # Before PhoenixMountable, the library created sample_items itself.
  alias PhoenixMountable.Migrations.SQL

  def detect(ctx) do
    cond do
      not SQL.table_exists?(ctx.repo, ctx.adapter, ctx.prefix, "sample_items") ->
        nil

      Enum.any?(
        SQL.columns(ctx.repo, ctx.adapter, ctx.prefix, "sample_items"),
        &(&1.name == "slug")
      ) ->
        2

      true ->
        1
    end
  end
end

defmodule SampleLib.Migrations do
  @moduledoc false
  use PhoenixMountable.Migrations,
    otp_app: :phoenix_mountable,
    library: :sample_lib,
    versions: [
      SampleLib.Migrations.V1,
      SampleLib.Migrations.V2,
      SampleLib.Migrations.V3,
      SampleLib.Migrations.V4
    ],
    baseline: SampleLib.Migrations.Baseline,
    compatible_with: 3,
    legacy: SampleLib.Migrations.Legacy,
    install_options: [primary_key: [type: {:in, [:id, :binary_id]}, default: :id]]
end

defmodule TinyLib.Migrations.V1 do
  @moduledoc false
  use PhoenixMountable.Migration

  def up(ctx) do
    create_if_not_exists table(:tiny_notes, prefix: ctx.prefix) do
      add :body, :string
    end
  end

  def down(ctx), do: drop_if_exists(table(:tiny_notes, prefix: ctx.prefix))
end

defmodule TinyLib.Migrations.V2 do
  @moduledoc false
  use PhoenixMountable.Migration, irreversible: "the notes' history is discarded"

  def up(ctx), do: create_index_if_missing(index(:tiny_notes, [:body], prefix: ctx.prefix))
end

defmodule TinyLib.Migrations do
  @moduledoc false
  use PhoenixMountable.Migrations,
    otp_app: :phoenix_mountable,
    library: :tiny_lib,
    versions: [TinyLib.Migrations.V1, TinyLib.Migrations.V2],
    lock_timeout: false
end

defmodule CompatLib.Migrations do
  @moduledoc false
  # TinyLib's versions, under another name, whose code runs on version 1.
  use PhoenixMountable.Migrations,
    otp_app: :phoenix_mountable,
    library: :compat_lib,
    versions: [TinyLib.Migrations.V1, TinyLib.Migrations.V2],
    compatible_with: 1,
    lock_timeout: false
end

defmodule CompatLib.Router do
  @moduledoc false
  use PhoenixMountable,
    otp_app: :phoenix_mountable,
    macro: :compat_lib,
    schema: CompatLib.Migrations

  routes do
    get "/", SchemaLib.PageController, :index
  end

  @impl PhoenixMountable
  def repo(_mount), do: PhoenixMountable.TestRepo.SQLite
end

defmodule SchemaLib.Router do
  @moduledoc false
  # A library whose mounts check the host's schema on first use.
  use PhoenixMountable,
    otp_app: :phoenix_mountable,
    macro: :schema_lib,
    schema: TinyLib.Migrations

  routes do
    get "/", SchemaLib.PageController, :index
  end

  @impl PhoenixMountable
  def repo(_mount), do: PhoenixMountable.TestRepo.SQLite
end

defmodule SchemaLib.PageController do
  @moduledoc false
  use Phoenix.Controller, formats: [:html]
  def index(conn, _params), do: text(conn, "ok")
end

defmodule SchemaLib.TestHost do
  @moduledoc false
  use PhoenixMountable.TestHost,
    mounts: [{SchemaLib.Router, "/schema"}, {CompatLib.Router, "/compat"}]
end
