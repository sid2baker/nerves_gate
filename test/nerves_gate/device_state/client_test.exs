defmodule NervesGate.DeviceState.ClientTest do
  use ExUnit.Case, async: true

  alias NervesGate.DeviceState.Client
  alias NervesGate.DeviceState.Public
  alias NervesGate.DeviceState.Replica
  alias NervesGate.DeviceState.Snapshot

  setup do
    name = String.to_atom("device_state_client_#{System.unique_integer([:positive])}")

    {:ok, client} =
      Client.start_link(
        name: name,
        subscribe: false,
        monitor_nodes: false,
        sync_connected: false
      )

    remote = :"gate-a@100.64.0.10"
    replica = Replica.new(remote, snapshot())

    :sys.replace_state(client, fn state ->
      %{state | replicas: %{remote => replica}}
    end)

    on_exit(fn -> if Process.alive?(client), do: GenServer.stop(client) end)
    %{client: client, remote: remote}
  end

  test "ordered remote operations update the local replica", %{client: client, remote: remote} do
    send(client, {:device_state_operation, remote, "boot-a", 2, {:name_changed, "Boiler room"}})

    assert_eventually(fn ->
      case Client.get("gate-a", client) do
        %Replica{revision: 2, data: %{name: "Boiler room"}} -> true
        _other -> false
      end
    end)
  end

  test "node loss keeps the last snapshot but marks it stale", %{client: client, remote: remote} do
    send(client, {:nodedown, remote, []})

    assert_eventually(fn ->
      case Client.get("gate-a", client) do
        %Replica{connected: false, data: %{name: "Gate A"}} -> true
        _other -> false
      end
    end)
  end

  defp snapshot do
    data = %Public{
      device_id: "gate-a",
      name: "Gate A",
      boot_id: "boot-a",
      firmware_version: "1.0.0"
    }

    %Snapshot{boot_id: "boot-a", revision: 1, data: data}
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
