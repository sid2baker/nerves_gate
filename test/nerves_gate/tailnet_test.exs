defmodule NervesGate.TailnetTest do
  use ExUnit.Case, async: true

  alias NervesGate.Tailnet
  alias NervesGate.Tailnet.Observation
  alias Tailscale.Peer
  alias Tailscale.Status

  test "pure observations project typed self, peers, and valid Tailnet addresses" do
    projected = Observation.project(online_status())

    assert projected.online
    assert projected.ipv4 == "100.64.0.10"
    assert Enum.any?(projected.nodes, &(&1.hostname == "nervesgate-m02"))
    refute Enum.any?(projected.nodes, &(&1.hostname == "technician-laptop"))

    refute Observation.project(%Status{online: true, ipv4: "192.168.1.10"}).online
  end

  test "machine distinguishes connecting, authentication, and online contracts" do
    {:ok, source} = Agent.start_link(fn -> Status.unknown() end)
    machine = start_machine(fn -> {:ok, Agent.get(source, & &1)} end)

    assert :ok = Tailnet.refresh(machine)
    assert Tailnet.diagnostics(machine).state == :connecting

    Agent.update(source, fn _ -> %Status{backend_state: :needs_login, authenticated: false} end)
    assert :ok = Tailnet.refresh(machine)
    assert Tailnet.diagnostics(machine).state == :needs_auth

    Agent.update(source, fn _ -> online_status() end)
    assert :ok = Tailnet.refresh(machine)
    assert Tailnet.diagnostics(machine).state == :online
    assert Tailnet.status(machine).online
  end

  test "a transient route-status read failure retains the last successful observation" do
    routes = %{advertised: ["192.168.10.0/24"], approved: [], primary: [], error: nil}

    assert Observation.route_status(fn -> {:error, :not_ready} end, routes) == routes
  end

  test "route health is observed without degrading a usable Tailnet" do
    {:ok, routes} = Agent.start_link(fn -> {:error, :not_ready} end)

    machine =
      start_machine(
        fn -> {:ok, online_status()} end,
        route_status: fn -> Agent.get(routes, & &1) end
      )

    assert :ok = Tailnet.refresh(machine)
    assert Tailnet.diagnostics(machine).state == :online
    assert Tailnet.status(machine).subnet_router.error == :unavailable

    Agent.update(routes, fn _ ->
      {:ok,
       %{
         advertised: ["192.168.10.0/24"],
         approved: ["192.168.10.0/24"],
         primary: []
       }}
    end)

    assert :ok = Tailnet.refresh(machine)
    assert Tailnet.diagnostics(machine).state == :online
    assert Tailnet.status(machine).subnet_router.approved == ["192.168.10.0/24"]
  end

  test "passive authentication observations keep the public needs-auth lifecycle" do
    owner = self()
    source = %Status{backend_state: :needs_login, authenticated: false}

    machine =
      start_machine(fn -> {:ok, source} end,
        publisher: fn status -> send(owner, {:published, status}) end
      )

    assert :ok = Tailnet.refresh(machine)
    drain_published()

    assert :ok = Tailnet.refresh(machine)
    statuses = drain_published()

    assert statuses != []
    assert Enum.all?(statuses, &(&1.state == :needs_auth))
  end

  test "passive online observations keep the last known public lifecycle" do
    owner = self()

    machine =
      start_machine(fn -> {:ok, online_status()} end,
        publisher: fn status -> send(owner, {:published, status}) end
      )

    assert :ok = Tailnet.refresh(machine)
    drain_published()

    assert :ok = Tailnet.refresh(machine)
    statuses = drain_published()

    assert statuses != []
    assert Enum.all?(statuses, &(&1.state == :online))
    assert Tailnet.diagnostics(machine).state == :online
  end

  test "healing performs only fresh typed reads" do
    owner = self()

    machine =
      start_machine(fn ->
        send(owner, :read_status)
        {:ok, online_status()}
      end)

    assert :ok = Tailnet.heal(machine)
    assert_receive :read_status
    assert Tailnet.status(machine).online
  end

  defp start_machine(read_status, options \\ []) do
    name = String.to_atom("tailnet_machine_#{System.unique_integer([:positive])}")

    payload =
      Tailnet.new(
        Keyword.merge(
          [
            read_status: read_status,
            read_health: fn -> {:ok, Tailscale.Health.initial()} end,
            route_status: fn -> {:ok, %{advertised: [], approved: [], primary: []}} end,
            publisher: fn _ -> :ok end,
            alarm_reporter: fn _ -> :ok end
          ],
          options
        )
      )

    {:ok, machine} = Tailnet.start_link(payload: payload, name: name)
    machine
  end

  defp drain_published(statuses \\ []) do
    receive do
      {:published, status} -> drain_published([status | statuses])
    after
      0 -> Enum.reverse(statuses)
    end
  end

  defp online_status do
    %Status{
      backend_state: :running,
      authenticated: true,
      online: true,
      hostname: "nervesgate-m01",
      ipv4: "100.64.0.10",
      peers: [
        %Peer{id: "peer-1", online: true, hostname: "nervesgate-m02", ipv4: "100.64.0.11"},
        %Peer{id: "laptop", online: true, hostname: "technician-laptop", ipv4: "100.64.0.20"}
      ]
    }
  end
end
