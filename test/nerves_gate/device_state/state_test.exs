defmodule NervesGate.DeviceState.StateTest do
  use ExUnit.Case, async: true

  alias NervesGate.DeviceState.State

  test "the same public operation stream produces identical state" do
    operations = [
      {:put, :internet, internet(true)},
      {:put, :tailnet, tailnet(true)},
      {:put, :ssh, ssh(:listening)},
      {:put, :cluster, cluster(true)},
      {:put, :alarms,
       [%{id: "Internet.Alarm", description: "Internet unavailable", level: :warning}]}
    ]

    owner = Enum.reduce(operations, State.new(), &apply!(&2, &1))
    replica = Enum.reduce(operations, State.new(), &apply!(&2, &1))

    assert owner == replica
    assert owner.internet.online
    assert owner.tailnet.online
    assert owner.ssh.state == :listening
    assert owner.cluster.online
  end

  test "one operation replaces only its owned public slice" do
    original =
      State.new()
      |> apply!({:put, :internet, internet(false)})
      |> apply!({:put, :ssh, ssh(:disabled)})

    updated = apply!(original, {:put, :internet, internet(true)})

    assert updated.internet == internet(true)
    assert updated.ssh == original.ssh
  end

  test "nil distinguishes an unhydrated owner from explicit offline state" do
    state = State.new()
    assert state.internet == nil

    state = apply!(state, {:put, :internet, internet(false)})
    assert state.internet == internet(false)
  end

  test "hydration requires every essential typed slice" do
    operations = [
      {:put, :device, %{device_id: "gate-a", name: "Gate A", firmware_version: "1.0.0"}},
      {:put, :firmware, firmware()},
      {:put, :configuration, %{configured: false}},
      {:put, :commissioning,
       %NervesGate.Commissioning.Status{state: :disabled, active: [], mode: :disabled}},
      {:put, :internet, internet(false)},
      {:put, :tailnet, tailnet(false)},
      {:put, :subnet_router,
       %NervesGate.SubnetRouter.Status{
         enabled: false,
         routes: [],
         state: :disabled,
         observed: %{}
       }},
      {:put, :ssh, ssh(:disabled)},
      {:put, :cluster, cluster(false)},
      {:put, :alarms, []}
    ]

    state = Enum.reduce(operations, State.new(), &apply!(&2, &1))
    assert State.hydrated?(state)
  end

  test "malformed, untyped, and unknown operations are rejected" do
    assert :error = State.reduce(State.new(), {:unknown, :ssh, %{}})
    assert :error = State.reduce(State.new(), {:put, :unknown, %{}})
    assert :error = State.reduce(State.new(), {:put, :ssh, %{state: :disabled}})
    assert :error = State.reduce(State.new(), {:put, :alarms, [%{id: 1}]})
  end

  defp apply!(state, operation) do
    assert {:ok, state} = State.reduce(state, operation)
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
