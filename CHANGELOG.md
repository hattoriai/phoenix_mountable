# Changelog

## Unreleased

* Fix a compile warning on Elixir 1.19 in `mix phoenix_mountable.gen.migration`.

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
