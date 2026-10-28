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

  test "real distribution reconnect preserves handshake and rejects a replaced identity at admission" do
    {server, server_node} = peer("session", "mycookie")
    {client, _} = peer("client", "mycookie")

    for peer <- [server, client] do
      :ok = :peer.call(peer, :code, :add_paths, [:code.get_path()])
      :ok = :peer.call(peer, Application, :load, [:nerves_gate_workbench])
      :ok = :peer.call(peer, Application, :load, [:nerves_gate_sdk])
    end

    :ok = :peer.call(server, System, :put_env, ["WORKBENCH_SESSION_ID", "contract-session"])
    :ok = :peer.call(server, Workbench.Session, :capture, [])

    {:ok, _} =
      :peer.call(server, GenServer, :start, [Workbench.Jobs, nil, [name: Workbench.Jobs]])

    remote =
      :peer.call(client, :erpc, :call, [server_node, Workbench.Session, :handshake, [], 5_000])

    expected = Map.take(remote, [:root, :id, :compatibility])
    assert :ok = Workbench.Session.validate(remote, expected, true)
    assert :peer.call(client, Node, :disconnect, [server_node])

    assert remote ==
             :peer.call(client, :erpc, :call, [
               server_node,
               Workbench.Session,
               :handshake,
               [],
               5_000
             ])

    # The client verified the old identity, but replacement happens before write admission.
    :ok = :peer.call(server, System, :put_env, ["WORKBENCH_SESSION_ID", "replacement"])

    assert {:error, reason} =
             :peer.call(client, :erpc, :call, [
               server_node,
               Workbench.Jobs,
               :build,
               ["ec100", expected],
               5_000
             ])

    assert reason =~ "identity changed"
    assert %{status: :idle} = :peer.call(server, Workbench.Jobs, :snapshot, [])
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
