# Testing

A mountable library has no router or endpoint of its own. Its tests
mount it in a host defined in `test/support`:

```elixir
defmodule MyLib.TestHost do
  use PhoenixMountable.TestHost,
    otp_app: :my_lib,
    mounts: [
      {MyLib.Router, "/my_lib", resolver: MyLib.TestResolver},
      {MyLib.Router, "/public", as: :public_lib}
    ]
end
```

```elixir
# test/test_helper.exs
MyLib.TestHost.start()
ExUnit.start()
```

```elixir
defmodule MyLib.HomeLiveTest do
  use ExUnit.Case, async: true
  use PhoenixMountable.Test, host: MyLib.TestHost

  test "renders", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/my_lib")
    assert html =~ "Welcome"
  end
end
```

The host's router pipes the mounts through a `:browser` pipeline like a
generated Phoenix app's, and its endpoint has a LiveView socket.

## Options and sessions

`PhoenixMountable.Test.build_mount/3` builds a mount as the macro does,
without a router, to test options, `normalize_options/1` and
`session/3`:

```elixir
mount = PhoenixMountable.Test.build_mount(MyLib.Router, "/my_lib", theme: :dark)
assert MyLib.Router.session(conn, mount, :default)["theme"] == :dark
```

## Migrations

See the [Migrations guide](migrations.md):
`PhoenixMountable.Migrations.Test.run_suite/3` checks the library's
migrations against a real database.
