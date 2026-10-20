# Changelog

## Unreleased

* A library's callbacks are found while its modules are not loaded yet,
  as in development and tests, where a module loads when first called:
  the definition's `session/3` (until then, the first library page after
  boot had no session, and an admin could get a 404), `repo/1` of the
  schema check, an assets strategy's `inject/2`, a migration's `down/1`,
  a host router's mounts and an installer's `install/1`.

## v0.2.1

* `PhoenixMountable.Path.path/3` and `PhoenixMountable.Mount.sibling/2`:
  paths under another mount of the same router, by its name, for a
  library whose definitions link to each other (an admin to its public
  page).

## v0.2.0

* `use PhoenixMountable.Install` declares a library's installer in one
  `use`: mounts, the migration, a LiveView hook, style sheets, Tailwind
  sources and the supervisor, then the library's own `install/1`. It is
  an Igniter task (`mix igniter.install my_lib`) and, in a host without
  Igniter, says how to get it.
* `PhoenixMountable.Igniter.mount/4` mounts in any scope, with its
  pipelines, options (`{web}` is the host's web module) and a re-exported
  macro (`:import`), and imports the library's formatter, so the host
  writes the mount without parentheses.
* `PhoenixMountable.Igniter.add_hook/4` and `add_css_imports/4` edit the
  host's `app.js` and `app.css` (`PhoenixMountable.Igniter.HostAssets`),
  or give the lines to add where they cannot.
* TypeScript types for the browser helper.
* A pending upgrade under `pending_migrations: :raise` is checked again
  on each use, so running the migration takes effect without a restart.
* The migration generator compiles without warnings on Elixir 1.19 and
  1.20.

## v0.1.0

The first release.

* Definition modules (`use PhoenixMountable`) and generated mount macros
  that insert routes, live sessions, controllers and plugs into a host
  router, with or without LiveView.
* Options validated with NimbleOptions when the host compiles, `:verify`
  checks after the host router compiles, and `normalize_options/1`.
* `PhoenixMountable.Mount` in LiveViews, controllers and plugs, with the
  request's CSP nonces.
* Assets: `Embedded`, `Static` (with Vite manifests) and `Host`
  strategies, layout components, a browser helper, and reloads of pages
  running a previous build.
* `~m`, paths relative to the mount, verified after compilation.
* Processes per mount (lazy or with `PhoenixMountable.Supervisor`),
  `PhoenixMountable.Singleton`, `PhoenixMountable.PubSub` and telemetry.
* `PhoenixMountable.Migrations`: versioned migrations on PostgreSQL,
  MySQL and SQLite with a tracking table, install options, legacy
  adoption, baselines, expand and contract versions, concurrent index
  builds, lock timeouts, SQLite table rebuilds that keep the host's
  columns, batched backfills, schema checks and a test kit.
* `mix phoenix_mountable.gen.migration`, `mix phoenix_mountable.check`,
  `mix phoenix_mountable.backfill`, and `PhoenixMountable.Igniter`.
* `PhoenixMountable.TestHost` and `PhoenixMountable.Test`.
