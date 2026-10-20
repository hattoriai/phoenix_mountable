defmodule PhoenixMountable.LoadingTest do
  # Not async: it unloads a module the other tests use.
  use ExUnit.Case, async: false
  use PhoenixMountable.Test, host: SampleLib.TestHost

  # In development and tests, modules load when first called. A library's
  # definition may not be loaded yet when its first request comes: its
  # callbacks must still be found.
  test "a library's session, from a definition not loaded yet", %{conn: conn} do
    unload(SampleLib.Router)

    {:ok, view, _html} = live(conn, "/sample")
    assert view |> element("#greeting") |> render() =~ "Hi test-user"
  end

  defp unload(module) do
    :code.purge(module)
    :code.delete(module)
    :code.purge(module)
    refute :code.is_loaded(module)
  end
end
