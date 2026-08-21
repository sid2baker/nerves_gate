defmodule NervesGate.DeviceState.ServerTest do
  use ExUnit.Case, async: true

  alias NervesGate.DeviceState.Public
  alias NervesGate.DeviceState.Server

  setup do
    name = String.to_atom("device_state_server_#{System.unique_integer([:positive])}")

    public = %Public{
      device_id: "gate-a",
      name: "Gate A",
      boot_id: "boot-a",
      firmware_version: "1.0.0"
    }

    {:ok, server} =
      Server.start_link(
        name: name,
        boot_id: "boot-a",
        initial_public: public,
        subscribe: false
      )

    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    %{server: server}
  end

  test "join returns an atomic snapshot followed by ordered operations", %{server: server} do
    assert {:ok, snapshot} = Server.join(self(), server)
    assert snapshot.boot_id == "boot-a"
    assert snapshot.revision == 0
    assert snapshot.data.name == "Gate A"

    assert :ok = Server.apply_operation({:name_changed, "Boiler room"}, server)

    assert_receive {:device_state_operation, _owner_node, "boot-a", 1,
                    {:name_changed, "Boiler room"}}

    assert Server.snapshot(server).revision == 1
    assert Server.public(server).name == "Boiler room"
  end

  test "idempotent operations do not consume revisions", %{server: server} do
    assert {:ok, _snapshot} = Server.join(self(), server)
    assert :ok = Server.apply_operation({:name_changed, "Gate A"}, server)
    refute_receive {:device_state_operation, _, _, _, _}
    assert Server.snapshot(server).revision == 0
  end

  test "client monitors are private and removed when a client exits", %{server: server} do
    client = spawn(fn -> Process.sleep(:infinity) end)
    assert {:ok, _snapshot} = Server.join(client, server)
    assert map_size(:sys.get_state(server).clients) == 1

    Process.exit(client, :kill)
    assert_eventually(fn -> map_size(:sys.get_state(server).clients) == 0 end)
    refute Map.has_key?(Public.to_map(Server.public(server)), :clients)
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
