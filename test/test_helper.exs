SampleLib.TestHost.start()

excluded = PhoenixMountable.TestDB.excluded()
excluded = excluded ++ PhoenixMountable.TestDB.start_repos(excluded)

ExUnit.start(exclude: excluded)
