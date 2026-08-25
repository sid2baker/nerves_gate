defmodule NervesGate.Cluster.PeerTest do
  use ExUnit.Case, async: true

  alias NervesGate.Cluster.Peer
  alias NervesGate.FSM.Diagnostics

  test "same-group peers discover, connect, and recover from nodedown" do
    {:ok, connected} = Agent.start_link(fn -> [] end)
    candidate = candidate()

    ops = %{
      discover: fn _ -> {:ok, "field"} end,
      connect: fn _ ->
        Agent.update(connected, fn _ -> [:"nervesgate@100.64.0.11"] end)
        {:ok, :"nervesgate@100.64.0.11"}
      end,
      connected: fn -> Agent.get(connected, & &1) end
    }

    machine = start_machine(candidate, "field", ops)
    transition(machine, :tick)
    assert Peer.status(machine).state == :connecting
    transition(machine, :tick)
    assert Peer.status(machine).state == :connected

    Agent.update(connected, fn _ -> [] end)
    transition(machine, :tick)
    assert Peer.status(machine).state == :connecting
  end

  test "foreign groups do not affect the global connection contract" do
    ops = %{
      discover: fn _ -> {:ok, "other"} end,
      connect: fn _ -> flunk("foreign peer must not connect") end,
      connected: fn -> [] end
    }

    machine = start_machine(candidate(), "field", ops)
    transition(machine, :tick)
    assert %{state: :foreign, group: "other", connected: false} = Peer.status(machine)
  end

  test "foreign peers wait before rediscovery instead of flapping every tick" do
    ops = %{
      discover: fn _ -> {:ok, "other"} end,
      connect: fn _ -> flunk("foreign peer must not connect") end,
      connected: fn -> [] end
    }

    machine = start_machine(candidate(), "field", ops, retry_delay: 30_000)
    transition(machine, :tick)
    assert Peer.status(machine).state == :foreign

    transition(machine, :tick)
    assert Peer.status(machine).state == :foreign
    assert is_integer(Peer.diagnostics(machine).retry_at)
  end

  test "singular peers remain foreign without reporting a discovery failure" do
    ops = %{
      discover: fn _ -> {:ok, nil} end,
      connect: fn _ -> flunk("singular peer must not connect") end,
      connected: fn -> [] end
    }

    machine = start_machine(candidate(), nil, ops)
    transition(machine, :tick)

    assert %{state: :foreign, group: nil, discovered: false, last_error: nil} =
             Peer.status(machine)
  end

  test "discovery and connection failures retain context in backoff" do
    ops = %{
      discover: fn _ -> {:error, :timeout} end,
      connect: fn _ -> {:error, :unused} end,
      connected: fn -> [] end
    }

    machine = start_machine(candidate(), "field", ops)
    transition(machine, :tick)
    assert Peer.status(machine).state == :backoff
    assert Peer.status(machine).last_error == %{kind: :discovery_failed, reason: :timeout}
    assert {:ok, _json} = Jason.encode(Peer.status(machine))
    assert Peer.diagnostics(machine).last_error == {:discovery_failed, :timeout}
  end

  defp start_machine(candidate, group, ops, options \\ []) do
    name = String.to_atom("peer_machine_#{System.unique_integer([:positive])}")
    payload = Peer.new(candidate, group, ops, Keyword.put_new(options, :retry_delay, 1))
    {:ok, machine} = Peer.start_link(payload: payload, name: name)
    machine
  end

  defp transition(machine, event), do: assert({:ok, _} = Diagnostics.transition(machine, event))

  defp candidate do
    %{hostname: "nervesgate-m02", ipv4: "100.64.0.11", node: "nervesgate@100.64.0.11"}
  end
end
