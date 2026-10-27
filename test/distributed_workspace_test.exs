defmodule Workbench.DistributedWorkspaceTest do
  use ExUnit.Case, async: false

  test "unique hidden workspaces connect to the same gateway using the dev cookie" do
    {first, n1} = peer("first", "mycookie")
    {second, n2} = peer("second", "mycookie")
    {_gateway, target} = peer("gateway", "mycookie")
    {_wrong, rejected} = peer("wrong", "othercookie")
    assert :peer.call(first, :net_kernel, :connect_node, [target])
    assert :peer.call(second, :net_kernel, :connect_node, [target])
    assert target in :peer.call(first, :erlang, :nodes, [:connected])
    assert target in :peer.call(second, :erlang, :nodes, [:connected])
    refute target in :peer.call(first, :erlang, :nodes, [:visible])
    refute :peer.call(first, :net_kernel, :connect_node, [rejected])
    refute n1 == n2
    :peer.stop(first)
    assert :peer.call(second, :net_adm, :ping, [target]) == :pong
  end

  defp peer(label, cookie) do
    name = String.to_atom("mesh_#{label}_#{System.unique_integer([:positive])}")

    {:ok, pid, node} =
      :peer.start_link(%{
        name: name,
        host: ~c"127.0.0.1",
        longnames: true,
        connection: :standard_io,
        args: [~c"+S", ~c"2:2", ~c"-hidden", ~c"-setcookie", to_charlist(cookie)]
      })

    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: :peer.stop(pid) end)
    {pid, node}
  end
end
