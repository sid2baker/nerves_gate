defmodule NervesGate.DeviceState.ServerTest do
  use ExUnit.Case, async: true

  alias NervesGate.DeviceState
  alias NervesGate.DeviceState.{Secret, Server, State}

  setup do
    owner = self()

    {:ok, server} =
      Server.start_link(
        name: nil,
        boot_id: "boot-a",
        initial_state: State.new(),
        device: %{device_id: "gate-a", name: "Gate A", firmware_version: "1.0.0"},
        owners: %{ssh: owner, internet: owner, alarms: owner}
      )

    %{server: server}
  end

  test "subscription atomically returns a snapshot followed by ordered operations", %{
    server: server
  } do
    assert {:ok, snapshot} = Server.subscribe(self(), server)
    assert snapshot.node == node()
    assert snapshot.boot_id == "boot-a"
    assert snapshot.revision == 0
    assert snapshot.state.device.name == "Gate A"

    event = {:state_reported, :ssh, ssh("100.64.0.10")}
    assert :ok = DeviceState.publish(event, server)

    operation = {:put, :ssh, ssh("100.64.0.10")}
    assert_receive {:device_state_operation, _node, "boot-a", 1, ^operation}
    assert {:ok, client_state} = State.reduce(snapshot.state, operation)
    assert Server.snapshot(server).state == client_state
  end

  test "identical reports do not consume revisions", %{server: server} do
    assert {:ok, _snapshot} = Server.subscribe(self(), server)

    event =
      {:state_reported, :internet,
       %NervesGate.Internet.Status{
         state: :offline,
         interface: nil,
         online: false,
         ready: false,
         reason: :offline,
         checks: %{}
       }}

    assert :ok = DeviceState.publish(event, server)

    assert_receive {:device_state_operation, _node, "boot-a", 1, {:put, :internet, _status}}

    assert :ok = DeviceState.publish(event, server)
    refute_receive {:device_state_operation, _node, _boot, _revision, _operation}
    assert Server.snapshot(server).revision == 1
  end

  test "publication is authenticated against the current owner", %{server: server} do
    parent = self()

    spawn(fn ->
      send(
        parent,
        {:result, DeviceState.publish({:state_reported, :ssh, %{state: :fake}}, server)}
      )
    end)

    assert_receive {:result, {:error, :not_owner}}
    assert Server.snapshot(server).revision == 0
  end

  test "private and secret-bearing state is rejected", %{server: server} do
    assert {:error, :secret_detected} =
             DeviceState.publish(
               {:state_reported, :ssh, ssh(Secret.new("secret"))},
               server
             )

    assert {:error, :invalid_state} =
             DeviceState.publish(
               {:state_reported, :ssh, ssh(self())},
               server
             )

    assert Server.snapshot(server).revision == 0
    refute inspect(Server.state(server)) =~ "secret"
  end

  test "only remote reducer clients receive lightweight boot and revision heartbeats", %{
    server: server
  } do
    assert {:ok, _snapshot} = Server.subscribe(self(), server)
    send(server, :heartbeat)
    refute_receive {:device_state_heartbeat, _node, "boot-a", 0}

    assert {:ok, _snapshot} = Server.subscribe_remote(self(), server)
    send(server, :heartbeat)
    assert_receive {:device_state_heartbeat, _node, "boot-a", 0}
  end

  test "subscriber monitors remain outside canonical state", %{server: server} do
    client = spawn(fn -> Process.sleep(:infinity) end)
    assert {:ok, _snapshot} = Server.subscribe(client, server)
    assert map_size(:sys.get_state(server).subscribers) == 1

    Process.exit(client, :kill)
    assert_eventually(fn -> map_size(:sys.get_state(server).subscribers) == 0 end)
    refute Map.has_key?(State.to_map(Server.state(server)), :subscribers)
  end

  defp ssh(address) do
    %NervesGate.SSH.Status{
      enabled: true,
      state: :listening,
      address: address,
      port: 22
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
