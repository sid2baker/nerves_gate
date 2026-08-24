defmodule NervesGate.Tailnet.ObserverTest do
  use ExUnit.Case

  alias NervesGate.Tailnet.Observer
  alias Tailscale.Peer
  alias Tailscale.Status

  test "projects typed self and peer state for NervesGate consumers" do
    projected = Observer.project(online_status())

    assert projected.online
    assert projected.authenticated
    assert projected.ipv4 == "100.64.0.10"
    assert [_, _, _] = projected.peers
    assert [_, _, _] = projected.nodes
    assert Enum.any?(projected.nodes, &(&1.hostname == "nervesgate-m02"))
    refute Enum.any?(projected.nodes, &(&1.hostname == "technician-laptop"))
  end

  test "unknown and invalid addresses remain safely offline" do
    projected = Observer.project(%Status{backend_state: :starting})
    refute projected.online
    assert projected.authenticated == :unknown
    assert projected.peers == []
    assert projected.nodes == []

    projected = Observer.project(%Status{online: true, ipv4: "192.168.1.10"})
    refute projected.online
    assert projected.ipv4 == nil
    assert projected.error == :address_unavailable
  end

  test "subscribed status and explicit route refreshes are broadcast" do
    Phoenix.PubSub.subscribe(NervesGate.PubSub, "tailnet")
    {:ok, routes} = Agent.start_link(fn -> [] end)

    route_status = fn ->
      current = Agent.get(routes, & &1)
      {:ok, %{advertised: current, approved: current, primary: current}}
    end

    {:ok, observer} = start_observer(route_status: route_status)
    send(observer, {:tailscale, :status_changed, 1, online_status()})

    assert_receive {:tailnet_changed, %{online: true, subnet_router: %{advertised: []}}}, 500

    Agent.update(routes, fn _old -> ["192.168.10.0/24"] end)
    Observer.refresh(observer)

    assert_receive {:tailnet_changed,
                    %{
                      subnet_router: %{
                        advertised: ["192.168.10.0/24"],
                        approved: ["192.168.10.0/24"],
                        primary: ["192.168.10.0/24"]
                      }
                    }},
                   500
  end

  test "explicit healing refresh reads fresh typed status without lifecycle mutations" do
    Phoenix.PubSub.subscribe(NervesGate.PubSub, "tailnet")

    {:ok, observer} =
      start_observer(
        read_status: fn -> {:ok, online_status()} end,
        route_status: fn -> {:ok, %{advertised: [], approved: [], primary: []}} end
      )

    assert :ok = Observer.refresh(observer)
    assert_receive {:tailnet_changed, %{online: true, ipv4: "100.64.0.10"}}, 500
  end

  test "loss and recovery are driven by normalized library subscriptions" do
    Phoenix.PubSub.subscribe(NervesGate.PubSub, "tailnet")
    {:ok, observer} = start_observer()

    send(observer, {:tailscale, :status_changed, 1, online_status()})
    assert_receive {:tailnet_changed, %{online: true}}, 500

    send(observer, {:tailscale, :status_changed, 2, Status.unknown()})
    assert_receive {:tailnet_changed, %{online: false, error: :status_unavailable}}, 500

    send(observer, {:tailscale, :status_changed, 3, online_status()})
    assert_receive {:tailnet_changed, %{online: true}}, 500
  end

  defp start_observer(options \\ []) do
    name = String.to_atom("tailscale_observer_#{System.unique_integer([:positive])}")

    Observer.start_link(Keyword.merge([name: name, enabled: true, subscribe: false], options))
  end

  defp online_status do
    %Status{
      backend_state: :running,
      authenticated: true,
      online: true,
      hostname: "nervesgate-m01",
      ipv4: "100.64.0.10",
      ipv6: "fd7a:115c:a1e0::10",
      peers: [
        %Peer{
          id: "peer-1",
          online: true,
          hostname: "nervesgate-m02",
          dns_name: "nervesgate-m02.example.ts.net.",
          ipv4: "100.64.0.11"
        },
        %Peer{
          id: "peer-2",
          online: false,
          hostname: "nervesgate-m03",
          ipv4: "100.64.0.12"
        },
        %Peer{
          id: "laptop",
          online: true,
          hostname: "technician-laptop",
          ipv4: "100.64.0.20"
        }
      ]
    }
  end
end
