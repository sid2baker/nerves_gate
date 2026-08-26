defmodule NervesGate.SessionTest do
  use ExUnit.Case, async: false

  alias NervesGate.DeviceState
  alias NervesGate.DeviceState.{Server, State}
  alias NervesGate.Session

  setup do
    owner = self()

    {:ok, server} =
      Server.start_link(
        name: nil,
        boot_id: "boot-a",
        initial_state: State.new(),
        device: device("Local"),
        owners: %{ssh: owner}
      )

    %{server: server}
  end

  test "owns the snapshot reducer and pushes complete state to its client", %{server: server} do
    {:ok, session} =
      Session.start_link(
        client: self(),
        device_state: server,
        replicas: fn -> %{} end
      )

    assert Session.state(session).local.revision == 0

    event = {:state_reported, :ssh, ssh()}
    assert :ok = DeviceState.publish(event, server)

    assert_receive {:nerves_gate_state_changed, ^session, fleet}
    assert fleet.local.revision == 1
    assert fleet.local.state.ssh == ssh()
    assert Session.state(session) == fleet
  end

  test "revision gaps reinstall an atomic snapshot without exposing the protocol", %{
    server: server
  } do
    {:ok, session} =
      Session.start_link(
        client: self(),
        device_state: server,
        replicas: fn -> %{} end
      )

    assert :ok = DeviceState.publish({:state_reported, :ssh, ssh()}, server)
    assert_receive {:nerves_gate_state_changed, ^session, %{local: %{revision: 1}}}

    send(
      session,
      {:device_state_event, node(), "different-boot", 99,
       {:state_reported, :device, device("Invalid")}}
    )

    assert_receive {:nerves_gate_state_changed, ^session, fleet}
    assert fleet.local.boot_id == "boot-a"
    assert fleet.local.revision == 1
    assert fleet.local.state.device.name == "Local"
  end

  test "remote replica changes become complete fleet updates", %{server: server} do
    {:ok, session} =
      Session.start_link(
        client: self(),
        device_state: server,
        replicas: fn -> %{} end
      )

    remote = replica("Remote")

    Phoenix.PubSub.local_broadcast(
      NervesGate.PubSub,
      "device_state",
      {:replica_changed, "remote", remote}
    )

    assert_receive {:nerves_gate_state_changed, ^session, fleet}
    assert fleet.replicas == %{"remote" => remote}
  end

  test "terminates when its client exits", %{server: server} do
    client = spawn(fn -> Process.sleep(:infinity) end)

    {:ok, session} =
      Session.start_link(
        client: client,
        device_state: server,
        replicas: fn -> %{} end
      )

    monitor = Process.monitor(session)
    Process.exit(client, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^session, :normal}
  end

  defp replica(name) do
    {:ok, state} = State.apply_event(State.new(), {:state_reported, :device, device(name)})

    %{
      state: state,
      node: :"remote@100.64.0.2",
      boot_id: "remote-boot",
      revision: 1,
      connected: true,
      last_seen_at: DateTime.utc_now()
    }
  end

  defp device(name),
    do: %{device_id: String.downcase(name), name: name, firmware_version: "1.0.0"}

  defp ssh do
    %NervesGate.SSH.Status{
      enabled: true,
      state: :listening,
      address: "100.64.0.1",
      port: 22
    }
  end
end
