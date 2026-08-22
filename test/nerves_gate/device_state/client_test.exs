defmodule NervesGate.DeviceState.ClientTest do
  use ExUnit.Case, async: true

  alias NervesGate.DeviceState.Client
  alias NervesGate.DeviceState.Data

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
    data = data()

    metadata = %{
      boot_id: "boot-a",
      revision: 1,
      connected: true,
      last_seen_at: DateTime.utc_now()
    }

    :sys.replace_state(client, fn state ->
      %{state | data: %{remote => data}, metadata: %{remote => metadata}}
    end)

    on_exit(fn -> if Process.alive?(client), do: GenServer.stop(client) end)
    %{client: client, remote: remote, initial_data: data}
  end

  test "ordered operations produce the same canonical Data on the client", context do
    operation = {:set_name, :device, "Boiler room"}
    assert {:ok, expected, _actions} = Data.apply_operation(context.initial_data, operation)

    send(
      context.client,
      {:device_state_operation, context.remote, "boot-a", 2, operation}
    )

    assert_eventually(fn -> Client.data("gate-a", context.client) == expected end)

    assert %{revision: 2, connected: true, data: ^expected} =
             Client.get("gate-a", context.client)
  end

  test "node loss keeps canonical data unchanged and marks only metadata stale", context do
    send(context.client, {:nodedown, context.remote, []})

    assert_eventually(fn ->
      case Client.get("gate-a", context.client) do
        %{connected: false, data: data} -> data == context.initial_data
        _other -> false
      end
    end)
  end

  test "revision gaps and owner reboots make the copy stale pending resynchronization", context do
    operation = {:set_name, :device, "Missed revision"}

    send(
      context.client,
      {:device_state_operation, context.remote, "boot-a", 3, operation}
    )

    assert_eventually(fn -> not Client.get("gate-a", context.client).connected end)
    assert Client.data("gate-a", context.client) == context.initial_data

    :sys.replace_state(context.client, fn state ->
      metadata = Map.update!(state.metadata, context.remote, &%{&1 | connected: true})
      %{state | metadata: metadata, pending: MapSet.new()}
    end)

    send(
      context.client,
      {:device_state_operation, context.remote, "boot-b", 1, operation}
    )

    assert_eventually(fn -> not Client.get("gate-a", context.client).connected end)
    assert Client.data("gate-a", context.client) == context.initial_data
  end

  defp data do
    Data.new(device_id: "gate-a", name: "Gate A", firmware_version: "1.0.0")
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
