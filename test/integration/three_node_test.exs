defmodule NervesGate.ThreeNodeIntegrationTest do
  use ExUnit.Case

  @moduletag :integration

  test "M01, M02, and M03 survive loss, persistent restart, and full cluster restart" do
    nodes = required_nodes()

    Enum.each(nodes, fn node ->
      status = :erpc.call(node, NervesGate, :status, [], 10_000)
      assert status.tailnet.online
      assert status.distribution.online
      expected_peers = nodes |> List.delete(node) |> Enum.map(&Atom.to_string/1)
      assert Enum.all?(expected_peers, &(&1 in status.cluster.connected))
    end)

    # The companion script controls persistent disks and QEMU lifecycle. This
    # witness verifies the post-stop/restart and post-full-restart convergence.
    assert Enum.all?(nodes, &(Node.ping(&1) == :pong))
  end

  defp required_nodes do
    for variable <- ~w(NERVES_GATE_M01_NODE NERVES_GATE_M02_NODE NERVES_GATE_M03_NODE) do
      variable
      |> System.fetch_env!()
      |> String.to_atom()
    end
  end
end
