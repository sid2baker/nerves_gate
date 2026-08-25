defmodule NervesGate.DependenciesTest do
  use ExUnit.Case, async: true

  alias NervesGate.Dependencies
  alias NervesGate.DeviceState
  alias NervesGate.DeviceState.{Server, State}

  test "projects future public dependency state without owning lifecycle" do
    owner = self()
    {:ok, server} = server(owner, State.new())

    {:ok, _bridge} =
      Dependencies.start_link(
        name: nil,
        device_state: server,
        dispatch: fn source, value -> send(owner, {:dependency, source, value}) end
      )

    tailnet = tailnet(true, "100.64.0.10")
    assert :ok = DeviceState.publish({:state_reported, :tailnet, tailnet}, server)
    assert_receive {:dependency, :tailnet, ^tailnet}

    assert :ok = DeviceState.publish({:state_reported, :alarms, []}, server)
    refute_receive {:dependency, :alarms, _alarms}
  end

  test "reconstructs current dependencies from the atomic snapshot" do
    owner = self()
    tailnet = tailnet(false, nil)
    {:ok, initial} = State.apply_event(State.new(), {:state_reported, :tailnet, tailnet})
    {:ok, server} = server(owner, initial)

    {:ok, _bridge} =
      Dependencies.start_link(
        name: nil,
        device_state: server,
        dispatch: fn source, value -> send(owner, {:dependency, source, value}) end
      )

    assert_receive {:dependency, :tailnet, ^tailnet}
  end

  test "revision gaps reinstall an atomic snapshot without buffering events" do
    owner = self()
    tailnet = tailnet(false, nil)
    {:ok, initial} = State.apply_event(State.new(), {:state_reported, :tailnet, tailnet})
    {:ok, server} = server(owner, initial)

    {:ok, bridge} =
      Dependencies.start_link(
        name: nil,
        device_state: server,
        dispatch: fn source, value -> send(owner, {:dependency, source, value}) end
      )

    assert_receive {:dependency, :tailnet, ^tailnet}

    send(
      bridge,
      {:device_state_event, node(), "unknown-boot", 99,
       {:state_reported, :tailnet, tailnet(true, "100.64.0.99")}}
    )

    assert_receive {:dependency, :tailnet, ^tailnet}
    assert Process.alive?(bridge)

    updated = tailnet(true, "100.64.0.10")
    assert :ok = DeviceState.publish({:state_reported, :tailnet, updated}, server)
    assert_receive {:dependency, :tailnet, ^updated}
  end

  defp tailnet(online, ipv4) do
    %NervesGate.Tailnet.Status{
      state: if(online, do: :online, else: :connecting),
      online: online,
      authenticated: online,
      hostname: nil,
      ipv4: ipv4,
      peers: [],
      nodes: [],
      subnet_router: %{},
      health: %{},
      error: if(online, do: nil, else: :offline)
    }
  end

  defp server(owner, initial) do
    Server.start_link(
      name: nil,
      initial_state: initial,
      device: %{device_id: "gate-a", name: "Gate A", firmware_version: "1.0.0"},
      owners: %{tailnet: owner, alarms: owner}
    )
  end
end
