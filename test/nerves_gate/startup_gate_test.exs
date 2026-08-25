defmodule NervesGate.StartupGateTest do
  use ExUnit.Case, async: true

  alias NervesGate.DeviceState
  alias NervesGate.DeviceState.{Server, State}
  alias NervesGate.StartupGate

  test "boot handshake completes once after every essential owner hydrates" do
    owner = self()
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    {:ok, server} =
      Server.start_link(
        name: nil,
        initial_state: State.new(),
        device: device(),
        owners: Map.new(State.sources() -- [:device], &{&1, owner})
      )

    {:ok, gate} =
      StartupGate.start_link(
        name: nil,
        enabled: true,
        device_state: server,
        callback: fn -> Agent.update(calls, &(&1 + 1)) end
      )

    refute :sys.get_state(gate).completed

    Enum.each(State.essential_sources() -- [:device, :alarms], fn source ->
      assert :ok = DeviceState.publish({:state_reported, source, disabled(source)}, server)
    end)

    assert :ok = DeviceState.publish({:state_reported, :alarms, []}, server)
    assert_eventually(fn -> :sys.get_state(gate).completed end)
    assert Agent.get(calls, & &1) == 1

    assert :ok = DeviceState.publish({:state_reported, :internet, internet(true)}, server)
    Process.sleep(10)
    assert Agent.get(calls, & &1) == 1
  end

  defp device,
    do: %{device_id: "gate-a", name: "Gate A", firmware_version: "1.0.0"}

  defp disabled(:configuration), do: %{configured: false}

  defp disabled(:commissioning),
    do: %NervesGate.Commissioning.Status{state: :disabled, active: [], mode: :disabled}

  defp disabled(:internet), do: internet(false)

  defp disabled(:tailnet) do
    %NervesGate.Tailnet.Status{
      state: :disabled,
      online: false,
      authenticated: false,
      hostname: nil,
      ipv4: nil,
      peers: [],
      nodes: [],
      subnet_router: %{},
      health: %{},
      error: :disabled
    }
  end

  defp disabled(:subnet_router) do
    %NervesGate.SubnetRouter.Status{
      enabled: false,
      routes: [],
      state: :disabled,
      observed: %{},
      applied_change_id: nil,
      failed_change_id: nil
    }
  end

  defp disabled(:ssh) do
    %NervesGate.SSH.Status{
      enabled: false,
      state: :disabled,
      address: nil,
      port: 22,
      applied_change_id: nil,
      failed_change_id: nil
    }
  end

  defp disabled(:cluster) do
    %NervesGate.Cluster.Status{
      state: :disabled,
      enabled: false,
      group: nil,
      online: false,
      node: nil,
      connected: [],
      candidates: [],
      groups: []
    }
  end

  defp internet(online) do
    %NervesGate.Internet.Status{
      state: if(online, do: :online, else: :offline),
      interface: if(online, do: "eth0"),
      online: online,
      ready: online,
      reason: if(online, do: nil, else: :disabled),
      checks: %{}
    }
  end

  defp assert_eventually(predicate, attempts \\ 50) do
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
