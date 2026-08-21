defmodule NervesGate.ThreeNodeIntegrationTest do
  use ExUnit.Case

  @moduletag :integration

  test "three cookie-configured gateways accept explicit distributed Erlang connections" do
    nodes = required_nodes()

    # Peer discovery and automatic reconnection are intentionally out of scope.
    # This witness explicitly connects to devices that were configured with the
    # same cookie as the test runner.
    assert Enum.all?(nodes, &Node.connect/1)

    Enum.each(nodes, fn node ->
      status = :erpc.call(node, NervesGate, :status, [], 10_000)
      assert status.tailnet.online
      assert status.cluster.enabled
      assert status.cluster.online
      assert status.distribution.online

      assert_eventually(fn ->
        replicas =
          :erpc.call(node, NervesGate.DeviceState.Client, :replicas, [], 10_000)

        connected_gateways =
          replicas
          |> Map.values()
          |> Enum.count(& &1.connected)

        connected_gateways >= 2
      end)
    end)
  end

  defp assert_eventually(predicate, attempts \\ 30) do
    cond do
      predicate.() ->
        :ok

      attempts == 0 ->
        flunk("device-state replicas did not converge")

      true ->
        Process.sleep(1_000)
        assert_eventually(predicate, attempts - 1)
    end
  end

  defp required_nodes do
    for variable <- ~w(NERVES_GATE_M01_NODE NERVES_GATE_M02_NODE NERVES_GATE_M03_NODE) do
      variable
      |> System.fetch_env!()
      |> String.to_atom()
    end
  end
end
