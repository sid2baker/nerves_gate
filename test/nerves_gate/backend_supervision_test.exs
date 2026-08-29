defmodule NervesGate.BackendSupervisionTest do
  use ExUnit.Case, async: false

  alias NervesGate.Alarms
  alias NervesGate.DeviceState.Server

  @owners [
    :firmware,
    :commissioning,
    :internet,
    :tailnet,
    :ssh,
    :subnet_router,
    :cluster,
    :configuration,
    :alarms
  ]

  test "stateful owners rebuild their payload on every supervised start" do
    assert %{start: {NervesGate.Gateway.Configuration, :start_supervised, [[]]}} =
             NervesGate.Gateway.Configuration.child_spec([])
  end

  test "DeviceState failure rebuilds owners and fleet under a new stream" do
    old = snapshot([:server, :owners, :fleet | @owners])
    assert Enum.all?(old, fn {_name, pid} -> is_pid(pid) end)

    Process.exit(old.server, :kill)

    assert_eventually(fn ->
      Enum.all?(old, fn {name, previous} -> replaced?(name, previous) end)
    end)

    assert_eventually(fn -> Server.snapshot().hydrated end, 300)
    assert Server.snapshot().revision > 0
  end

  test "firmware failure is isolated from every other owner and Fleet" do
    old = snapshot([:firmware, :configuration, :internet, :alarms, :fleet])
    Process.exit(old.firmware, :kill)

    assert_eventually(fn -> replaced?(:firmware, old.firmware) end)

    assert current_pid(:configuration) == old.configuration
    assert current_pid(:internet) == old.internet
    assert current_pid(:alarms) == old.alarms
    assert current_pid(:fleet) == old.fleet
  end

  test "SSH failure restores accepted intent without restarting Configuration" do
    old = snapshot([:ssh, :configuration, :owners, :fleet])
    Process.exit(old.ssh, :kill)

    assert_eventually(fn -> replaced?(:ssh, old.ssh) end)
    assert current_pid(:configuration) == old.configuration
    assert current_pid(:owners) == old.owners
    assert current_pid(:fleet) == old.fleet
  end

  test "alarm projection failure does not restart owners or Fleet" do
    old = snapshot([:alarms, :owners, :fleet])
    Process.exit(old.alarms, :kill)

    assert_eventually(fn -> replaced?(:alarms, old.alarms) end)
    assert current_pid(:owners) == old.owners
    assert current_pid(:fleet) == old.fleet
  end

  test "storage failure evidence survives an alarm owner restart" do
    on_exit(fn -> Alarms.storage_failure(false) end)
    assert :ok = Alarms.storage_failure(true)
    assert_eventually(fn -> Enum.any?(Alarms.active(), &(&1.id == "storage_failure")) end)

    previous = current_pid(:alarms)
    Process.exit(previous, :kill)

    assert_eventually(fn -> replaced?(:alarms, previous) end)
    assert_eventually(fn -> Enum.any?(Alarms.active(), &(&1.id == "storage_failure")) end)
  end

  defp snapshot(names), do: Map.new(names, &{&1, current_pid(&1)})

  defp replaced?(name, previous) do
    current = current_pid(name)
    is_pid(current) and current != previous and Process.alive?(current)
  end

  defp current_pid(:server), do: Process.whereis(Server)
  defp current_pid(:owners), do: Process.whereis(NervesGate.Backend.Owners)
  defp current_pid(:firmware), do: Process.whereis(NervesGate.Firmware)
  defp current_pid(:commissioning), do: Process.whereis(NervesGate.Commissioning)
  defp current_pid(:internet), do: Process.whereis(NervesGate.Internet)
  defp current_pid(:tailnet), do: Process.whereis(NervesGate.Tailnet)
  defp current_pid(:ssh), do: Process.whereis(NervesGate.SSH)
  defp current_pid(:subnet_router), do: Process.whereis(NervesGate.SubnetRouter)
  defp current_pid(:cluster), do: Process.whereis(NervesGate.Cluster)
  defp current_pid(:configuration), do: Process.whereis(NervesGate.Gateway.Configuration)
  defp current_pid(:alarms), do: Process.whereis(NervesGate.Alarms)
  defp current_pid(:fleet), do: Process.whereis(NervesGate.Fleet)

  defp assert_eventually(predicate, attempts \\ 100) do
    cond do
      predicate.() ->
        :ok

      attempts == 0 ->
        flunk("condition did not converge")

      true ->
        Process.sleep(10)
        assert_eventually(predicate, attempts - 1)
    end
  end
end
