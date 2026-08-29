defmodule NervesGate.ClientTest do
  use ExUnit.Case, async: true

  alias NervesGate.Client
  alias NervesGate.DeviceState
  alias NervesGate.DeviceState.{Server, State}
  alias NervesGate.Fleet

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

    {:ok, fleet} =
      Fleet.start_link(
        name: nil,
        boot_id: "fleet-a",
        connected_nodes: fn -> [] end,
        tick_interval: 60_000
      )

    %{server: server, fleet: fleet}
  end

  test "the caller purely reduces ordered local operations", context do
    assert {:ok, client} = connect(context)
    assert Client.state(client).local.revision == 0

    assert :ok = DeviceState.publish({:state_reported, :ssh, ssh()}, context.server)
    assert_receive {:device_state_operation, _, "boot-a", 1, {:put, :ssh, _}} = operation

    assert {:ok, client, :changed} = Client.reduce(client, operation)
    assert Client.state(client).local.revision == 1
    assert Client.state(client).local.state.ssh == ssh()

    assert {:ok, ^client, :duplicate} = Client.reduce(client, operation)
  end

  test "revision gaps request one atomic resynchronization", context do
    assert {:ok, client} = connect(context)
    assert :ok = DeviceState.publish({:state_reported, :ssh, ssh()}, context.server)
    assert_receive operation
    assert {:ok, client, :changed} = Client.reduce(client, operation)

    gap = {:device_state_operation, node(), "different-boot", 99, {:put, :device, device("Bad")}}
    assert :resync = Client.reduce(client, gap)

    assert {:ok, client} = Client.resync(client)
    assert Client.state(client).local.boot_id == "boot-a"
    assert Client.state(client).local.revision == 1
    assert Client.state(client).local.state.device.name == "Local"
  end

  test "fleet operations use the same snapshot then ordered-operation contract", context do
    assert {:ok, client} = connect(context)
    remote = replica("Remote")

    operation = {:fleet_operation, client.fleet_boot_id, 1, {:put, "remote", remote}}
    assert {:ok, client, :changed} = Client.reduce(client, operation)
    assert Client.state(client).replicas == %{"remote" => remote}

    assert {:ok, ^client, :duplicate} = Client.reduce(client, operation)

    assert :resync =
             Client.reduce(
               client,
               {:fleet_operation, client.fleet_boot_id, 3, {:delete, "remote"}}
             )
  end

  test "disconnect removes direct process subscriptions", context do
    assert {:ok, client} = connect(context)
    assert map_size(:sys.get_state(context.server).subscribers) == 1
    assert map_size(:sys.get_state(context.fleet).subscribers) == 1

    assert :ok = Client.disconnect(client)
    assert map_size(:sys.get_state(context.server).subscribers) == 0
    assert map_size(:sys.get_state(context.fleet).subscribers) == 0
  end

  test "a partial connection failure removes the successful subscription", context do
    missing_fleet = String.to_atom("missing_fleet_#{System.unique_integer([:positive])}")

    assert {:error, :state_unavailable} =
             Client.connect(device_state: context.server, fleet: missing_fleet)

    assert map_size(:sys.get_state(context.server).subscribers) == 0
  end

  defp connect(context) do
    Client.connect(device_state: context.server, fleet: context.fleet)
  end

  defp replica(name) do
    {:ok, state} = State.reduce(State.new(), {:put, :device, device(name)})

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
