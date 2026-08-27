defmodule NervesGate.DeviceState.StateTest do
  use ExUnit.Case, async: true

  alias NervesGate.DeviceState.State

  test "the same public event stream produces identical state" do
    events = [
      {:state_reported, :internet, internet(true)},
      {:state_reported, :tailnet, tailnet(true)},
      {:state_reported, :ssh, ssh(:listening)},
      {:state_reported, :cluster, cluster(true)},
      {:state_reported, :alarms,
       [%{id: "Internet.Alarm", description: "Internet unavailable", level: :warning}]}
    ]

    owner = Enum.reduce(events, State.new(), &apply!(&2, &1))
    replica = Enum.reduce(events, State.new(), &apply!(&2, &1))

    assert owner == replica
    assert owner.internet.online
    assert owner.tailnet.online
    assert owner.ssh.state == :listening
    assert owner.cluster.online
  end

  test "one event replaces only its owned public slice" do
    original =
      State.new()
      |> apply!({:state_reported, :internet, internet(false)})
      |> apply!({:state_reported, :ssh, ssh(:disabled)})

    updated = apply!(original, {:state_reported, :internet, internet(true)})

    assert updated.internet == internet(true)
    assert updated.ssh == original.ssh
  end

  test "nil distinguishes an unhydrated owner from explicit offline state" do
    state = State.new()
    assert state.internet == nil

    state = apply!(state, {:state_reported, :internet, internet(false)})
    assert state.internet == internet(false)
  end

  test "hydration requires every essential typed slice" do
    events = [
      {:state_reported, :device,
       %{device_id: "gate-a", name: "Gate A", firmware_version: "1.0.0"}},
      {:state_reported, :firmware, firmware()},
      {:state_reported, :configuration, %{configured: false}},
      {:state_reported, :commissioning,
       %NervesGate.Commissioning.Status{state: :disabled, active: [], mode: :disabled}},
      {:state_reported, :internet, internet(false)},
      {:state_reported, :tailnet, tailnet(false)},
      {:state_reported, :subnet_router,
       %NervesGate.SubnetRouter.Status{
         enabled: false,
         routes: [],
         state: :disabled,
         observed: %{}
       }},
      {:state_reported, :ssh, ssh(:disabled)},
      {:state_reported, :cluster, cluster(false)},
      {:state_reported, :alarms, []}
    ]

    state = Enum.reduce(events, State.new(), &apply!(&2, &1))
    assert State.hydrated?(state)
  end

  test "malformed, untyped, and unknown events are rejected" do
    assert :error = State.apply_event(State.new(), {:unknown, :ssh, %{}})
    assert :error = State.apply_event(State.new(), {:state_reported, :unknown, %{}})
    assert :error = State.apply_event(State.new(), {:state_reported, :ssh, %{state: :disabled}})
    assert :error = State.apply_event(State.new(), {:state_reported, :alarms, [%{id: 1}]})
  end

  defp apply!(state, event) do
    assert {:ok, state} = State.apply_event(state, event)
    state
  end

  defp firmware do
    %NervesGate.Firmware.Status{
      supported: false,
      phase: :unsupported,
      current: %{version: "1.0.0"},
      validation: :unsupported
    }
  end

  defp internet(online) do
    %NervesGate.Internet.Status{
      state: if(online, do: :online, else: :offline),
      interface: if(online, do: "eth0"),
      online: online,
      ready: online,
      reason: if(online, do: nil, else: :offline),
      checks: %{}
    }
  end

  defp tailnet(online) do
    %NervesGate.Tailnet.Status{
      state: if(online, do: :online, else: :connecting),
      online: online,
      authenticated: online,
      hostname: if(online, do: "gate-a"),
      ipv4: if(online, do: "100.64.0.10"),
      peers: [],
      nodes: [],
      subnet_router: %{},
      health: %{},
      error: if(online, do: nil, else: :offline)
    }
  end

  defp ssh(state) do
    %NervesGate.SSH.Status{
      enabled: state != :disabled,
      state: state,
      address: if(state == :listening, do: "100.64.0.10"),
      port: 22
    }
  end

  defp cluster(online) do
    %NervesGate.Cluster.Status{
      state: if(online, do: :online, else: :disabled),
      enabled: online,
      group: if(online, do: "Plant_floor"),
      online: online,
      node: nil,
      connected: [],
      candidates: [],
      groups: []
    }
  end
end
