defmodule PhoenixMountable.Migrations.OutdatedError do
  @moduledoc """
  Raised when a host's database is behind the schema a mountable library needs.

  The message names the library, the versions and the command that fixes it.
  """
  defexception [:message]
end

defmodule PhoenixMountable.MigrationError do
  @moduledoc """
  Raised when a library's migration cannot run in the database's current
  state: a backfill it needs has not finished, it must run outside a
  transaction, or a version cannot be rolled back.
  """
  defexception [:message]
end
