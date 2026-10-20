import Config

config :phoenix_mountable, PhoenixMountable.TestRepo.Postgres,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  database: "phoenix_mountable_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  priv: "test/support/postgres",
  log: false

config :phoenix_mountable, PhoenixMountable.TestRepo.MySQL,
  username: System.get_env("MYSQL_USER", "root"),
  password: System.get_env("MYSQL_PASSWORD", "mysql"),
  hostname: System.get_env("MYSQL_HOST", "localhost"),
  database: "phoenix_mountable_test",
  log: false

config :phoenix_mountable, PhoenixMountable.TestRepo.SQLite,
  database: Path.expand("../tmp/phoenix_mountable_test.db", __DIR__),
  log: false

# Pending library migrations raise in tests.
config :phoenix_mountable, pending_migrations: :raise
