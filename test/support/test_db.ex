defmodule PhoenixMountable.TestDB do
  @moduledoc false
  # Which databases the migration tests run against: PM_DBS (default: all),
  # minus the ones that cannot be reached.

  @repos %{
    postgres: PhoenixMountable.TestRepo.Postgres,
    mysql: PhoenixMountable.TestRepo.MySQL,
    sqlite: PhoenixMountable.TestRepo.SQLite
  }

  def repo(db), do: Map.fetch!(@repos, db)

  def excluded do
    enabled = System.get_env("PM_DBS", "postgres,mysql,sqlite") |> String.split(",", trim: true)
    for db <- ~w(postgres mysql sqlite), db not in enabled, do: {:db, String.to_atom(db)}
  end

  def start_repos(excluded) do
    for {db, repo} <- @repos, {:db, db} not in excluded, reduce: [] do
      acc ->
        config = repo.config()
        if db == :sqlite, do: File.mkdir_p!(Path.dirname(config[:database]))

        with result when result in [:ok, {:error, :already_up}] <-
               repo.__adapter__().storage_up(config),
             {:ok, _} <- repo.start_link() do
          acc
        else
          error ->
            IO.puts(:stderr, "skipping #{db} tests: #{inspect(error)}")
            [{:db, db} | acc]
        end
    end
  end
end
