# Security

## Reporting a vulnerability

Do not open a public issue for a security problem. Report it privately
through GitHub: [Report a vulnerability](https://github.com/hattoriai/phoenix_mountable/security/advisories/new).

Say what an attacker can do, and how: the definition and the host's mount,
the request or the event, and the steps or the payload. We answer within
a week, agree on a fix and a date, and credit you in the advisory unless
you ask us not to.

## Supported versions

Security fixes are made to the latest release. PhoenixMountable is before
1.0, so a fix is not backported to an earlier minor version.

## What is in scope

PhoenixMountable puts a library's routes, live sessions and assets in a
host app, and runs its migrations in the host's database. A problem is
in scope when PhoenixMountable itself lets a request, an event, or the
options a host passes:

- reach a library's route without the host's scope, pipelines or
  `on_mount` hooks that the mount was placed under;
- read a file outside the directory of a library's built assets (the
  `Static` strategy), or any file under a URL the library did not
  declare;
- inject script into a page through the meta tags, the layout or the
  mount's path, or get around the request's CSP nonces;
- see or change another mount's session, options, processes or PubSub
  messages;
- run SQL of their own through the migrations, a backfill or the schema
  check;
- crash the host, or make the server or the database do unbounded work.

What a library does inside its routes is the library's: who may see a
page is decided by its resolver or its `on_mount` hooks, and by the
pipelines the host mounts it under. Report a problem in a library built
with PhoenixMountable to that library.
