for db <- [:postgres, :mysql, :sqlite] do
  defmodule Module.concat(
              PhoenixMountable.MigrationsDynamicRepoTest,
              db |> Atom.to_string() |> Macro.camelize()
            ) do
    use ExUnit.Case, async: false

    alias PhoenixMountable.Migrations.SQL

    @db db
    @moduletag db: db

    test "plain SQL uses the selected pool and its transaction" do
      repo = PhoenixMountable.TestDB.repo(@db)
      config = repo.config()
      suffix = System.unique_integer([:positive]) |> Integer.to_string()
      database = config[:database] <> "_dynamic_" <> suffix
      config = Keyword.merge(config, database: database, pool: DBConnection.ConnectionPool)
      :ok = repo.__adapter__().storage_up(config)
      pool = start_supervised!({repo, Keyword.merge(config, name: nil)})

      on_exit(fn ->
        named(repo, fn -> repo.query!("DROP TABLE IF EXISTS pm_dynamic_probe") end)
        if Process.alive?(pool), do: Supervisor.stop(pool)
        :ok = repo.__adapter__().storage_down(config)
      end)

      named(repo, fn ->
        repo.query!("CREATE TABLE pm_dynamic_probe (value VARCHAR(40))")
        repo.query!("INSERT INTO pm_dynamic_probe VALUES ('named')")
      end)

      previous = repo.put_dynamic_repo(pool)

      try do
        repo.query!("CREATE TABLE pm_dynamic_probe (value VARCHAR(40))")
        repo.query!("INSERT INTO pm_dynamic_probe VALUES ('selected')")

        assert [["selected"]] = SQL.query!(repo, "SELECT value FROM pm_dynamic_probe").rows
        SQL.query!(repo, "UPDATE pm_dynamic_probe SET value='changed'")

        assert {:error, :proof} =
                 repo.transaction(fn ->
                   SQL.query!(repo, "UPDATE pm_dynamic_probe SET value='rolled-back'")
                   repo.rollback(:proof)
                 end)

        assert [["changed"]] = repo.query!("SELECT value FROM pm_dynamic_probe").rows

        assert [["named"]] =
                 named(repo, fn -> repo.query!("SELECT value FROM pm_dynamic_probe").rows end)
      after
        repo.put_dynamic_repo(previous)
      end
    end

    defp named(repo, fun) do
      previous = repo.put_dynamic_repo(repo)

      try do
        if repo.config()[:pool] == Ecto.Adapters.SQL.Sandbox,
          do: Ecto.Adapters.SQL.Sandbox.unboxed_run(repo, fun),
          else: fun.()
      after
        repo.put_dynamic_repo(previous)
      end
    end
  end
end
