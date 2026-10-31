defmodule Workbench.GatewaysTest do
  use ExUnit.Case, async: false
  alias Workbench.Gateways

  test "candidates: owned guests win over the same node found on the network" do
    owned = [%{id: :gateway_a, node: :"nerves_gate@10.203.42.2", address: "10.203.42.2"}]

    assert [
             %{node: :"nerves_gate@10.203.42.2", source: :qemu, sim_id: :gateway_a},
             %{node: :"nerves_gate@192.168.1.42", source: :network, sim_id: nil}
           ] = Gateways.candidates(owned, [{"10.203.42.2", :network}, {"192.168.1.42", :network}])
  end

  test "Tailnet peers become candidates only when online and tagged, regardless of name" do
    tag = ["tag:nerves-gate"]

    status = %{
      "Peer" => %{
        "a" => %{"Online" => true, "DNSName" => "em300.example.ts.net.", "Tags" => tag},
        "b" => %{"Online" => false, "DNSName" => "ec100.example.ts.net.", "Tags" => tag},
        "c" => %{"Online" => true, "DNSName" => "nerves-gate.example.ts.net.", "Tags" => nil},
        "d" => %{"Online" => true, "DNSName" => "ci.example.ts.net.", "Tags" => ["tag:ci"]}
      }
    }

    assert Gateways.tailnet_peers(status) == [{"em300.example.ts.net", :network}]
    assert Gateways.tailnet_peers(%{}) == []
  end

  test "manual addresses are hostnames or unicast IPv4, never URLs or loopback" do
    assert {:ok, "ec100.example.ts.net"} = Gateways.host(" EC100.example.ts.net. ")
    assert {:ok, "192.168.1.42"} = Gateways.host("192.168.1.42")

    for invalid <- [
          "https://device.example/",
          "127.0.0.1",
          "",
          "a b",
          nil,
          "0.0.0.0",
          "224.0.0.1"
        ],
        do: assert({:error, _} = Gateways.host(invalid))
  end

  test "a non-gateway is never connected, and node-down keeps last-seen identity" do
    start_supervised!({Phoenix.PubSub, name: NervesGate.PubSub})
    start_supervised!({Gateways, poll: false})
    Gateways.subscribe()

    candidate = %{
      node: :"nerves_gate@192.0.2.1",
      address: "192.0.2.1",
      source: :network,
      sim_id: nil
    }

    assert %{connected: false, error: :unreachable} = Gateways.verify(candidate)

    seen =
      Map.merge(candidate, %{
        connected: true,
        identity: %{target: "ec100"},
        last_seen: ~U[2026-10-27 12:00:00Z],
        error: nil
      })

    send(Gateways, {:verified, seen})
    # A verification reply arriving after transport loss must not resurrect it.
    assert_receive {:gateways, [%{connected: false}]}
    assert {:error, :not_connected} = Gateways.fetch(seen.node)

    # Exercise the node-down transition independently of any physical connection.
    Gateways.handle_info({:nodedown, seen.node, []}, %{gateways: %{seen.node => seen}})
    assert_receive {:gateways, [gateway]}
    assert %{connected: false, error: :node_down, identity: %{target: "ec100"}} = gateway
    assert gateway.last_seen == ~U[2026-10-27 12:00:00Z]
    assert {:error, :not_connected} = Gateways.fetch(seen.node)

    # A later failed attempt keeps the last sighting.
    send(Gateways, {:verified, Gateways.verify(candidate)})
    assert_receive {:gateways, [%{last_seen: ~U[2026-10-27 12:00:00Z], identity: %{}}]}
  end
end
