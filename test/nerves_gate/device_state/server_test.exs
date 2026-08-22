defmodule NervesGate.DeviceState.ServerTest do
  use ExUnit.Case, async: true

  alias NervesGate.DeviceState.Data
  alias NervesGate.DeviceState.Server

  setup do
    name = String.to_atom("device_state_server_#{System.unique_integer([:positive])}")
    data = Data.new(device_id: "gate-a", name: "Gate A", firmware_version: "1.0.0")

    {:ok, server} =
      Server.start_link(
        name: name,
        boot_id: "boot-a",
        initial_data: data,
        subscribe: false
      )

    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    %{server: server}
  end

  test "join returns canonical data followed by ordered operations", %{server: server} do
    assert {:ok, snapshot} = Server.join(self(), server)
    assert snapshot.boot_id == "boot-a"
    assert snapshot.revision == 0
    assert snapshot.data.name == "Gate A"

    operation = {:set_name, :device, "Boiler room"}
    assert :ok = Server.apply_operation(operation, server)

    assert_receive {:device_state_operation, _owner_node, "boot-a", 1, ^operation}
    assert {:ok, client_data, _actions} = Data.apply_operation(snapshot.data, operation)

    assert Server.snapshot(server).revision == 1
    assert Server.data(server) == client_data
    assert client_data.name == "Boiler room"
  end

  test "idempotent operations do not consume revisions", %{server: server} do
    assert {:ok, _snapshot} = Server.join(self(), server)
    assert :ok = Server.apply_operation({:set_name, :device, "Gate A"}, server)
    refute_receive {:device_state_operation, _, _, _, _}
    assert Server.snapshot(server).revision == 0
  end

  test "invalid or non-public operations are rejected and never broadcast", %{server: server} do
    assert {:ok, _snapshot} = Server.join(self(), server)
    assert :error = Server.apply_operation({:unknown, :test}, server)

    operation =
      {:set_cluster, :cluster,
       %{enabled: true, runtime_status: :online, connected: [], credential: "private-value"}}

    assert :error = Server.apply_operation(operation, server)
    refute_receive {:device_state_operation, _, _, _, _}
    assert Server.snapshot(server).revision == 0
    refute inspect(Server.data(server)) =~ "private-value"
  end

  test "client monitors remain outside canonical data", %{server: server} do
    client = spawn(fn -> Process.sleep(:infinity) end)
    assert {:ok, _snapshot} = Server.join(client, server)
    assert map_size(:sys.get_state(server).clients) == 1

    Process.exit(client, :kill)
    assert_eventually(fn -> map_size(:sys.get_state(server).clients) == 0 end)
    refute Map.has_key?(Data.to_map(Server.data(server)), :clients)
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
