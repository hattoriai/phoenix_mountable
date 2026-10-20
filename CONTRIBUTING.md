# Contributing to PhoenixMountable

Thank you for helping. This page says what to open (an issue, a pull
request, or a security report), what a pull request needs, how to run the
checks, and what the maintainers keep for themselves.

## Questions, bugs and ideas

- **A bug.** Open an issue with the bug report form. The smallest
  definition module that shows it, with the host router's mount line, is
  the most useful thing you can give.
- **An idea or a change of behaviour.** Open an issue with the feature
  request form, and say the problem before the solution.
- **A security problem.** Do not open an issue. See
  [SECURITY.md](SECURITY.md).

Search the open and closed issues first: the idea may already be planned,
or turned down for a reason given there.

## When a pull request needs an issue first

Open an issue, and agree on the change there, before a pull request that:

- adds a feature, an option, a callback, a Mix task or an assets
  strategy;
- changes what a definition, a mount macro, the migrations or the
  installer do, or the public API (of the Elixir modules or of the
  browser helper);
- changes the routes, live sessions or code generated in a host app, or
  the tracking table of the migrations;
- adds a dependency;
- touches many files, or needs a design decision.

A pull request does not need an issue when it is small and its reason is
plain from the diff: a typo, a broken link, a wrong sentence in a guide,
or a bug fix with a test that fails without it. When in doubt, open the
issue: a short discussion costs less than a pull request that is not
merged.

A pull request with an issue says so: `Fixes #123` or `Closes #123`.

## A pull request

- **One change.** A fix, the guides for an unrelated case and a README
  edit are three pull requests. Each is reviewed, reverted and released
  on its own.
- **Why, not only what.** The description says the problem the change
  solves, for whom (a library author, or a host app), and what happened
  before it: a compile error, a 404, a failed migration. Say why a number
  was chosen when the change adds one.
- **Tests.** A bug fix has a test that fails on `main` and passes with
  the fix. A feature has tests of what it does, and of its errors. A
  change to the migrations is tested on PostgreSQL, MySQL and SQLite.
- **Docs.** A change a user can see updates the guide it belongs to and
  the `Unreleased` section of [CHANGELOG.md](CHANGELOG.md).
- **The browser helper.** `priv/static/phoenix_mountable.js`,
  `phoenix_mountable.esm.js` and `phoenix_mountable.d.ts` are written by
  hand, with no build step: a change to one is made to the others.
- **The checks pass.** See below.

The pull request template has these as a checklist.

## Running the checks

CI runs these; run them first:

```sh
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix test
MIX_ENV=dev mix docs --warnings-as-errors
mix dialyzer
```

`mix lint` runs the first three checks at once. CI also builds the
package as a Hex user without Phoenix, LiveView or Igniter does; to run
it yourself:

```sh
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix compile --no-optional-deps --warnings-as-errors
```

The migration tests run against PostgreSQL, MySQL and SQLite. A database
that cannot be reached is skipped, with a line that says so, so check the
output before you trust a green run. `PM_DBS` picks the databases
(`PM_DBS=sqlite mix test`), and `PGHOST`, `PGUSER`, `PGPASSWORD`,
`MYSQL_HOST`, `MYSQL_USER` and `MYSQL_PASSWORD` say where they are (the
defaults are in `config/test.exs`). CI runs PostgreSQL 16 and MySQL 8.4,
on Elixir 1.18 / OTP 27 and Elixir 1.19 / OTP 28.

## What the maintainers keep

- **Releases.** The version in `mix.exs` and `package.json`, the release
  headings of the changelog and the tags are changed by the maintainers,
  at a release.

## Style

Match the code around your change: its naming, its comments and the way
its guides are written. `mix format` and `mix credo --strict` settle the
rest.

## License

By contributing, you agree that your contribution is released under the
MIT License of the project (see [LICENSE](LICENSE)).
