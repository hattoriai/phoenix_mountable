defmodule PhoenixMountable.ProcessesTest do
  use ExUnit.Case, async: false

  alias PhoenixMountable.{Children, Singleton}
  alias SampleLib.TestHost.{Endpoint, Router}

  defp mount(name), do: %{Router.__phoenix_mountable_mount__(name) | endpoint: Endpoint}

  describe "lazy children" do
    test "start once per mount, and again after the mount's tree stopped" do
      mount = mount(:nested_sample)
      assert {:ok, pid} = Children.ensure_started(mount)
      assert {:ok, ^pid} = Children.ensure_started(mount)

      ref = Process.monitor(pid)
      Supervisor.stop(pid, :shutdown)
      assert_receive {:DOWN, ^ref, _, _, _}

      assert {:ok, new_pid} = Children.ensure_started(mount)
      assert new_pid != pid
    end

    test "a library without children starts nothing" do
      assert Children.ensure_started(mount(:plain_lib)) == :ignore
    end
  end

  describe "PhoenixMountable.Supervisor" do
    test "starts the children of every mount of a router at boot, without duplicates" do
      for mount <- PhoenixMountable.mounts(Router), pid = Children.whereis(mount) do
        Supervisor.stop(pid, :shutdown)
      end

      pid = start_supervised!({PhoenixMountable.Supervisor, router: Router, endpoint: Endpoint})

      started =
        Supervisor.which_children(pid) |> Enum.map(fn {{:mount, name}, _, _, _} -> name end)

      assert Enum.sort(started) == [:nested_sample, :other_sample, :sample_lib]

      mount = mount(:sample_lib)
      assert {:ok, tree} = Children.ensure_started(mount)

      assert {_, ^tree, _, _} =
               List.keyfind(Supervisor.which_children(pid), {:mount, :sample_lib}, 0)

      counter = PhoenixMountable.via(mount, :counter)
      assert SampleLib.Counter.bump(counter) >= 1
    end

    test "rejects a router without mounts" do
      assert {:error, {{%ArgumentError{message: message}, _}, _}} =
               start_supervised(
                 {PhoenixMountable.Supervisor, router: SampleLib.TestHost.Endpoint}
               )

      assert message =~ "has no PhoenixMountable mounts"
    end
  end

  describe "Singleton" do
    test "runs the child once, and the next instance takes over when it stops" do
      name = {:test_singleton, System.unique_integer()}
      child = {Agent, fn -> :value end}

      first = start_supervised!({Singleton, name: name, child: child}, id: :first)
      second = start_supervised!({Singleton, name: name, child: child}, id: :second)

      # Both have claimed or started watching once their state can be read.
      _ = :sys.get_state(first)
      _ = :sys.get_state(second)
      running = Singleton.whereis(name)
      assert is_pid(running)
      assert Agent.get(running, & &1) == :value

      owner = if :sys.get_state(first).pid == running, do: :first, else: :second
      assert :sys.get_state(if(owner == :first, do: second, else: first)).pid == nil

      ref = Process.monitor(running)
      stop_supervised!(owner)
      assert_receive {:DOWN, ^ref, _, _, _}

      new = wait_for(fn -> Singleton.whereis(name) end)
      assert new != running
      assert Agent.get(new, & &1) == :value
    end
  end

  describe "PubSub" do
    test "topics are scoped to the mount" do
      sample = mount(:sample_lib)
      other = mount(:other_sample)

      :ok = PhoenixMountable.PubSub.subscribe(sample, "items")
      :ok = PhoenixMountable.PubSub.broadcast(other, "items", :from_other)
      :ok = PhoenixMountable.PubSub.broadcast(sample, "items", :from_sample)

      assert_receive :from_sample
      refute_received :from_other

      assert PhoenixMountable.PubSub.topic(sample, "items") ==
               "phoenix_mountable:SampleLib.TestHost.Router:sample_lib:items"
    end

    test "explains a missing PubSub server" do
      mount = %{mount(:sample_lib) | endpoint: nil}

      assert_raise ArgumentError, ~r/no endpoint or :pubsub option/, fn ->
        PhoenixMountable.PubSub.server!(mount)
      end
    end
  end

  describe "telemetry" do
    test "emits mount events for requests and LiveViews" do
      ref = make_ref()
      parent = self()

      :telemetry.attach_many(
        "#{inspect(ref)}",
        [[:phoenix_mountable, :mount, :request], [:phoenix_mountable, :mount, :live]],
        fn event, _measurements, metadata, _ ->
          send(parent, {ref, event, metadata.mount.name})
        end,
        nil
      )

      Phoenix.ConnTest.dispatch(Phoenix.ConnTest.build_conn(), Endpoint, :get, "/other/export")
      Phoenix.ConnTest.dispatch(Phoenix.ConnTest.build_conn(), Endpoint, :get, "/other")

      assert_receive {^ref, [:phoenix_mountable, :mount, :request], :other_sample}
      assert_receive {^ref, [:phoenix_mountable, :mount, :live], :other_sample}
    after
      :telemetry.list_handlers([:phoenix_mountable])
      |> Enum.each(&:telemetry.detach(&1.id))
    end
  end

  defp wait_for(fun, attempts \\ 50) do
    case fun.() do
      nil when attempts > 0 ->
        Process.sleep(20)
        wait_for(fun, attempts - 1)

      value ->
        value
    end
  end
end
