## Why

<!-- The problem this solves, for whom (a library author or a host app), and what happened before it (a compile error, a 404, a failed migration). -->

Fixes #<!-- the issue; see CONTRIBUTING.md for when a pull request needs one -->

## What

<!-- The change, in a few lines. -->

## How it was tested

<!-- The tests added, the databases they ran on, and what you ran by hand. -->

## Checklist

- [ ] One change: anything unrelated is in its own pull request.
- [ ] A bug fix has a test that fails on `main` and passes here.
- [ ] `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test`, `MIX_ENV=dev mix docs --warnings-as-errors` and `mix dialyzer` pass.
- [ ] `MIX_ENV=prod mix compile --no-optional-deps --warnings-as-errors` passes, for a change that touches Phoenix, LiveView, Ecto or Igniter.
- [ ] The migration tests ran on PostgreSQL, MySQL and SQLite (none skipped), for a change to the migrations.
- [ ] `phoenix_mountable.js`, `phoenix_mountable.esm.js` and `phoenix_mountable.d.ts` change together, for a change to the browser helper.
- [ ] The guides and the `Unreleased` section of `CHANGELOG.md` are updated, for a change a user can see.
- [ ] Says so here if it changes the public API, or what PhoenixMountable does or generates in a host today.
- [ ] No changes to the version in `mix.exs` or `package.json` (the maintainers keep it).
