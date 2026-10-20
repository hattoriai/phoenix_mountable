# Migrations

A library's tables live in a database the library does not control.
The host may have added columns, indexes, triggers or foreign keys to
them; it may use `binary_id` keys, a schema prefix, several prefixes,
MySQL or SQLite, a table of fifty million rows, and rolling deploys
where old and new code run against the same schema.
`PhoenixMountable.Migrations` is built for that.

It needs `ecto_sql`, and no Phoenix: a core package uses it on its own.

## The library side

```elixir
defmodule MyLib.Migrations do
  use PhoenixMountable.Migrations,
    otp_app: :my_lib,
    versions: [MyLib.Migrations.V1, MyLib.Migrations.V2, MyLib.Migrations.V3],
    install_options: [primary_key: [type: {:in, [:id, :binary_id]}, default: :id]]
end

defmodule MyLib.Migrations.V1 do
  use PhoenixMountable.Migration, description: "Items"

  def up(ctx) do
    create table(:my_lib_items, primary_key: primary_key(ctx), prefix: ctx.prefix) do
      add :title, :string
    end

    create index(:my_lib_items, [:title], prefix: ctx.prefix)
  end

  def down(ctx), do: drop(table(:my_lib_items, prefix: ctx.prefix))
end
```

Each version is a `PhoenixMountable.Migration`, with the `Ecto.Migration`
DSL. It receives a `PhoenixMountable.Migrations.Context`: the repo, the
adapter (`:postgres`, `:mysql`, `:sqlite`), the prefix, and the install
options. Match on the adapter where the SQL differs:

```elixir
def up(%{adapter: :sqlite} = ctx), do: ...
def up(ctx), do: ...
```

## The host side

The host owns one pinned line per upgrade:

```elixir
defmodule MyApp.Repo.Migrations.AddMyLib do
  use Ecto.Migration

  def up, do: MyLib.Migrations.up(version: 3)
  def down, do: MyLib.Migrations.down(to: 0)
end
```

`mix phoenix_mountable.gen.migration MyLib.Migrations` writes it (or a
library's own `mix my_lib.gen.migration`): it reads the version the
host's migrations pin, and writes the next migration with the latest
version, the attributes it needs, and notes about the versions. The
file is created by `mix ecto.gen.migration`, so it follows the host's
conventions.

Pinning keeps history reproducible: a developer or CI running every
migration on an empty database gets the same sequence production did.
An unpinned `up()` changes meaning when the dependency updates.

## Tracking

The version is kept in a `phoenix_mountable_schema` table in the
library's prefix, written in the transaction of each version. It works
on every database (table comments do not exist on SQLite and are lost by
`pg_dump --no-comments`), per prefix (two instances in two schemas track
separately), and records the install options.

## Install options

Options chosen once, at install, that later versions need:

```elixir
MyLib.Migrations.up(version: 3, primary_key: :binary_id)
```

They are stored, and every later version sees them in `ctx`, so a
version written years later adds a foreign key of the right type
(`key_type(ctx)`). A `:primary_key` option defaults to the repo's
`:migration_primary_key`.

## Existing installs

A library moving onto PhoenixMountable declares how to read the version
of a database migrated before:

```elixir
use PhoenixMountable.Migrations, ..., legacy: MyLib.Migrations.Legacy

defmodule MyLib.Migrations.Legacy do
  alias PhoenixMountable.Migrations.SQL

  # From Oban-style table comments, or from the columns present.
  def detect(ctx) do
    if SQL.table_exists?(ctx.repo, ctx.adapter, ctx.prefix, "my_lib_items"), do: 2
  end
end
```

On the first run the detected version is recorded and only later
versions run.

## Baselines

A library with many versions can ship a baseline creating the latest
schema in one step, for fresh installs:

```elixir
defmodule MyLib.Migrations.Baseline do
  use PhoenixMountable.Migration, baseline: 12
  def up(ctx), do: ...
end
```

`PhoenixMountable.Migrations.Test.assert_baseline_matches/3` proves it
gives the same schema as running every version.

## Rolling deploys

Each version is `safety: :expand` (the default: new tables, nullable
columns, new indexes) or `safety: :contract` (dropping, renaming,
changing types). A compile-time lint warns about destructive operations
in an expand version.

`compatible_with: n` is the oldest schema version the library's code
still runs against. A rename is three releases: add the new column and
write both, backfill, then drop the old one in a contract version. The
generator notes contract versions, so hosts deploy the code first.

## Large tables

* `create_concurrently(index(...))` builds an index without locking
  writes on Postgres (and normally elsewhere). Such a version cannot run
  in a transaction; the generator adds `@disable_ddl_transaction true`
  and `@disable_migration_lock true` to the host migration, and running
  it in a transaction fails with those lines.
* `lock_timeout` (`"5s"` by default) makes a version fail fast rather
  than queue behind a long transaction and block the app.
* Backfills move data in batches, apart from the schema change:

```elixir
defmodule MyLib.Backfills.Slugs do
  use PhoenixMountable.Backfill,
    table: "my_lib_items",
    where: "slug IS NULL",
    set: "slug = LOWER(title)",
    batch_size: 1_000
end

def up(ctx) do
  alter table(:my_lib_items, prefix: ctx.prefix), do: add(:slug, :string)
  backfill(ctx, MyLib.Backfills.Slugs)
end
```

Backfills run inline by default. With `mode: :deferred`, or
`up(version: n, backfills: :deferred)` from the host, they run after the
deploy in `PhoenixMountable.Backfill.Runner` (or
`mix phoenix_mountable.backfill`), batch by batch, recording a cursor
after each, so they resume after a restart. A version that needs the
data declares `requires_backfills: [MyLib.Backfills.Slugs]` and refuses
to run before the backfill finishes.

## Host changes

* Indexes have deterministic names; `create_index_if_missing/1`,
  `drop_index_if_present/1` and `add_column_if_missing/5` work on every
  adapter (MySQL has no `IF NOT EXISTS` for them), so a version runs
  again after a partial failure (MySQL DDL is not transactional).
* SQLite cannot alter a column, so `rebuild_table/3` recreates the table,
  copying every column, index and trigger, including the host's, and
  refusing tables with `CHECK` constraints rather than losing them.
* `verify/1` compares the tables with a snapshot written by the test
  kit, ignoring what the host added.

## Checks

With `schema: MyLib.Migrations` in the definition module, the first use
of each mount compares the database with the library:

* below `compatible_with`: raises `PhoenixMountable.Migrations.OutdatedError`
  with the command to run;
* between: logs a warning once, or raises with
  `config :phoenix_mountable, pending_migrations: :raise` (set it in the
  host's test config so CI catches a forgotten upgrade).

`mix phoenix_mountable.check` checks every library in CI.

## Testing

```elixir
test "migrations" do
  PhoenixMountable.Migrations.Test.run_suite(MyLib.Repo, MyLib.Migrations, prefix: "my_lib_test")
end
```

runs every version up, down and up again, checks the baseline, upgrades
from each version, and adds a column and an index to every table after
each version (as a host might) to check that later versions keep them.
Run it against each database the library supports.
