defmodule NervesGate.BackendSupervisionTest do
  use ExUnit.Case, async: false

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

  test "DeviceState failure restarts every publisher and downstream cache" do
    old = snapshot([:server, :publishers, :connection, :replicas, :sessions | @owners])
    assert Enum.all?(old, fn {_name, pid} -> is_pid(pid) end)

    Process.exit(old.server, :kill)

    assert_eventually(fn ->
      Enum.all?(old, fn {name, previous} -> replaced?(name, previous) end)
    end)

    assert_eventually(fn -> Server.snapshot().hydrated end, 300)
    assert Server.snapshot().revision > 0
  end

  test "firmware failure stays inside the firmware publisher" do
    old = snapshot([:firmware, :connection, :alarms, :replicas, :sessions])
    Process.exit(old.firmware, :kill)

    assert_eventually(fn -> replaced?(:firmware, old.firmware) end)

    assert current_pid(:connection) == old.connection
    assert current_pid(:alarms) == old.alarms
    assert current_pid(:replicas) == old.replicas
    assert current_pid(:sessions) == old.sessions
  end

  test "SSH owner failure restores in place without restarting configuration" do
    old = snapshot([:ssh, :configuration, :connection, :replicas, :sessions])
    Process.exit(old.ssh, :kill)

    assert_eventually(fn -> replaced?(:ssh, old.ssh) end)
    assert current_pid(:configuration) == old.configuration
    assert current_pid(:connection) == old.connection
    assert current_pid(:replicas) == old.replicas
    assert current_pid(:sessions) == old.sessions
  end

  test "alarm projection failure does not disconnect replicas or sessions" do
    old = snapshot([:alarms, :replicas, :sessions])
    Process.exit(old.alarms, :kill)

    assert_eventually(fn -> replaced?(:alarms, old.alarms) end)
    assert current_pid(:replicas) == old.replicas
    assert current_pid(:sessions) == old.sessions
  end

  defp snapshot(names), do: Map.new(names, &{&1, current_pid(&1)})

  defp replaced?(name, previous) do
    current = current_pid(name)
    is_pid(current) and current != previous and Process.alive?(current)
  end

  defp current_pid(:server), do: Process.whereis(Server)
  defp current_pid(:publishers), do: Process.whereis(NervesGate.Backend.Publishers)
  defp current_pid(:connection), do: Process.whereis(NervesGate.Backend.Connection)
  defp current_pid(:firmware), do: Process.whereis(NervesGate.Firmware)
  defp current_pid(:commissioning), do: Process.whereis(NervesGate.Commissioning)
  defp current_pid(:internet), do: Process.whereis(NervesGate.Internet)
  defp current_pid(:tailnet), do: Process.whereis(NervesGate.Tailnet)
  defp current_pid(:ssh), do: Process.whereis(NervesGate.SSH)
  defp current_pid(:subnet_router), do: Process.whereis(NervesGate.SubnetRouter)
  defp current_pid(:cluster), do: Process.whereis(NervesGate.Cluster)
  defp current_pid(:configuration), do: Process.whereis(NervesGate.Gateway.Configuration)
  defp current_pid(:alarms), do: Process.whereis(NervesGate.Alarms.Runtime)

  defp current_pid(:replicas),
    do: Process.whereis(NervesGate.DeviceState.Replica.Supervisor)

  defp current_pid(:sessions), do: Process.whereis(NervesGate.Session.DynamicSupervisor)

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
