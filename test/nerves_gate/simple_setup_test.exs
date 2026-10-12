defmodule NervesGate.SimpleSetupTest do
  use ExUnit.Case, async: true
  alias NervesGate.{Config, Network}
  alias NervesGate.Network.{Access, Discovery, Host, Vintage}
  alias NervesGate.TestNetworkAdapter, as: Adapter
  alias NervesGateWeb.NetworkForm
  @usb %{present: true, link: true, addresses: [%{address: "10.13.0.1", prefix_length: 30}]}
  @access %{local: "10.13.0.1", peer: {10, 13, 0, 2}}
  @empty %{"mode" => "ports", "eth0" => nil, "eth1" => nil}
  @wan Map.put(@empty, "eth0", %{"role" => "internet", "address" => Config.address_defaults()})
  @equipment %{
    "role" => "equipment",
    "address" => %{
      "ip_method" => "static",
      "static_ip" => "192.168.50.2",
      "subnet_mask" => "255.255.255.0",
      "gateway" => nil
    }
  }

  setup do
    host = start_supervised!({Host, name: nil})
    Host.simulate(%{usb: @usb}, host)
    adapter = start_supervised!({Adapter, host: host, owner: self()})

    opts = [
      name: nil,
      adapter: {Adapter, adapter},
      poll_ms: 10,
      trial_ms: 2_000
    ]

    server = start_supervised!({Network, opts})
    %{host: host, server: server, opts: opts, adapter: adapter}
  end

  test "partial and offline configurations are valid without inventing equipment addresses" do
    for network <- [
          @empty,
          @wan,
          Map.put(@empty, "eth1", @equipment),
          Map.put(@wan, "eth1", @equipment)
        ] do
      assert {:ok, ^network} = Config.validate_network(network)
    end

    assert {:error, _} = Config.validate_network(Map.put(@wan, "eth1", @wan["eth0"]))

    assert {:error, _} =
             Config.validate_network(
               Map.put(@empty, "eth0", %{@equipment | "address" => Config.address_defaults()})
             )

    assert {:error, _} = Config.validate_network(Map.put(@empty, "usb0", nil))
  end

  test "manual WAN settings and DNS reach VintageNet but not equipment" do
    address =
      Map.merge(@equipment["address"], %{
        "gateway" => "192.168.50.1",
        "nameservers" => ["1.1.1.1", "9.9.9.9"]
      })

    network = put_in(@wan["eth0"]["address"], address)
    assert {:ok, ^network} = Config.validate_network(network)
    configs = Map.new(Vintage.configurations(network))
    assert configs["eth0"].ipv4.name_servers == ["1.1.1.1", "9.9.9.9"]
    assert configs["eth0"].ipv4.gateway == "192.168.50.1"
    assert configs["eth1"].ipv4.method == :disabled
    assert configs["br0"].vintage_net_bridge.interfaces == []
    refute Map.has_key?(configs, "usb0")
    assert {:error, _} = Config.validate_network(put_in(network["eth0"]["role"], "equipment"))

    assert {:error, _} =
             Config.validate_network(put_in(network["eth0"]["address"]["nameservers"], ["oops"]))
  end

  test "detection requires one unambiguous candidate and online wins over local" do
    left = port("eth0", :lan)
    right = port("eth1", :internet)
    assert Discovery.internet_port([left]) == "eth0"
    assert Discovery.internet_port([left, right]) == "eth1"
    assert Discovery.internet_port([%{left | connection: :internet}, right]) == nil
    assert Discovery.internet_port([left, %{right | connection: :lan}]) == nil
    assert Discovery.internet_port([%{right | link: false}]) == nil
    assert Discovery.internet_port([%{right | addresses: []}]) == nil
    assert Discovery.internet_port([]) == nil
  end

  test "USB exemption is bound to both socket endpoints, not USB cable presence", ctx do
    observed = Host.snapshot(ctx.host)
    assert Access.usb?(observed, @access)
    refute NervesGate.Network.Access.usb?(observed, nil)
    refute NervesGate.Network.Access.usb?(observed, %{@access | peer: {10, 13, 0, 0}})
    refute NervesGate.Network.Access.usb?(observed, %{@access | peer: {10, 13, 0, 3}})
    refute NervesGate.Network.Access.usb?(observed, %{@access | peer: {0, 0, 0, 0, 0, 0, 0, 1}})
    refute Access.usb?(observed, %{@access | local: "192.0.2.10"})
    refute Access.usb?(observed, %{@access | peer: {192, 0, 2, 20}})
    refute Access.usb?(observed, %{@access | peer: {10, 13, 0, 1}})
    refute Access.usb?(%{observed | usb: %{@usb | link: false}}, @access)

    refute Access.usb?(
             %{observed | usb: %{@usb | addresses: [%{address: "10.13.0.1", prefix_length: 24}]}},
             @access
           )

    overlap = %{hd(observed.ports) | addresses: [%{address: "10.13.0.3", prefix_length: 24}]}
    refute Access.usb?(%{observed | ports: [overlap]}, @access)
  end

  test "first USB setup saves directly; later USB edits still expire and restore", ctx do
    assert {:ok, _} = Network.propose(@wan, ctx.server, @access)
    assert Network.status(ctx.server).trial == nil
    assert {:ok, saved} = Host.load(ctx.host)
    assert saved["setup_completed"]
    assert saved["network"] == @wan
    :sys.replace_state(ctx.server, &%{&1 | trial_ms: 200})
    assert {:ok, _} = Network.propose(@empty, ctx.server, @access)
    refute Network.status(ctx.server).trial.auto_save

    eventually(fn ->
      status = Network.status(ctx.server)
      status.trial == nil and not status.recovering
    end)

    assert Host.snapshot(ctx.host).ports |> hd() |> Map.get(:method) == "dhcp"
    assert {:ok, ^saved} = Host.load(ctx.host)
  end

  test "USB-only and equipment-only setup can finish offline", ctx do
    assert {:ok, _} = Network.propose(@empty, ctx.server, @access)
    assert Network.status(ctx.server).trial == nil
    network = Map.put(@empty, "eth1", @equipment)
    assert {:ok, id} = Network.propose(network, ctx.server)
    refute Enum.at(Host.snapshot(ctx.host).ports, 1).link
    assert :ok = Network.confirm(id, ctx.server)
    assert Network.status(ctx.server).config["network"] == network
  end

  test "offline shared network does not require a DHCP lease or carrier", ctx do
    shared = %{"mode" => "shared", "equipment" => Config.address_defaults()}
    assert {:ok, id} = Network.propose(shared, ctx.server)
    snapshot = Host.snapshot(ctx.host)

    Host.simulate(
      %{
        usb: @usb,
        bridge: %{snapshot.bridge | link: false, addresses: []},
        ports: Enum.map(snapshot.ports, &%{&1 | link: false})
      },
      ctx.host
    )

    assert :ok = Network.confirm(id, ctx.server)
  end

  test "automatic save waits for application, not browser confirmation", ctx do
    ports = Host.snapshot(ctx.host).ports
    Host.simulate(%{usb: @usb, ports: ports}, ctx.host)
    assert {:ok, _} = Network.propose(@empty, ctx.server, @access)
    assert Network.status(ctx.server).trial.auto_save
    refute Network.status(ctx.server).config["setup_completed"]
    Host.simulate(%{usb: @usb}, ctx.host)
    eventually(fn -> Network.status(ctx.server).trial == nil end)
    assert Network.status(ctx.server).config["setup_completed"]
  end

  test "stalled automatic application expires and restart restores the old configuration", ctx do
    Host.simulate(%{usb: @usb, ports: Host.snapshot(ctx.host).ports}, ctx.host)
    assert {:ok, _} = Network.propose(@empty, ctx.server, @access)

    :sys.replace_state(ctx.server, fn state ->
      %{state | deadline: System.monotonic_time(:millisecond) - 1}
    end)

    send(ctx.server, :poll)

    eventually(fn ->
      status = Network.status(ctx.server)
      status.trial == nil and not status.recovering
    end)

    refute Network.status(ctx.server).config["setup_completed"]
    assert {:ok, _} = Network.propose(@empty, ctx.server, @access)
    stop_supervised!(Network)
    server = start_supervised!({Network, ctx.opts})
    assert Network.status(server).trial == nil
    assert Network.status(server).config == Config.defaults()
  end

  test "automatic save rejects overlaps and reports the error immediately", ctx do
    network = Map.put(@wan, "eth1", put_in(@equipment["address"]["static_ip"], "192.0.2.20"))
    assert {:error, :conflicting_networks} = Network.propose(network, ctx.server, @access)
    assert Network.status(ctx.server).trial == nil
    assert Network.status(ctx.server).config == Config.defaults()
  end

  test "failed automatic persistence never reports success", ctx do
    Adapter.fail(ctx.adapter, :save, :enospc)
    assert {:error, {:save, _}} = Network.propose(@empty, ctx.server, @access)
    assert Network.status(ctx.server).trial == nil
    refute Network.status(ctx.server).config["setup_completed"]
    assert hd(Host.snapshot(ctx.host).ports).method == "dhcp"
  end

  test "forms round-trip port settings and never silently reuse a port" do
    settings = %{
      "mode" => "ports",
      "eth1" => %{"role" => "internet", "address" => NervesGate.Config.address_defaults()},
      "eth0" => %{"role" => "equipment", "address" => @equipment["address"]}
    }

    draft = NetworkForm.from_settings(settings)
    assert {:ok, network} = NetworkForm.to_network(draft, [])
    assert network["eth0"] == @equipment
    assert network["eth1"] == @wan["eth0"]
    assert {:error, _} = NetworkForm.to_network(%{draft | "equipment_port" => "eth1"}, [])

    assert {:error, _} =
             NetworkForm.to_network(%{draft | "internet_port" => "auto"}, [
               port("eth0", :internet),
               port("eth1", :internet)
             ])
  end

  defp port(name, connection),
    do: %{
      name: name,
      present: true,
      link: true,
      connection: connection,
      addresses: [%{address: "192.0.2.10", prefix_length: 24}]
    }

  defp eventually(fun, remaining \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, remaining) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, remaining - 1)
        )
  end
end
