defmodule NervesGate.RemoteTailscaleTest do
  use ExUnit.Case, async: false
  alias NervesGate.{Alarms, Config, Indicators, Network, Remote}

  @network __MODULE__.Network
  @remote __MODULE__.Remote

  defmodule CachedNetwork do
    # The real notification format and properties, without VintageNet's workers,
    # persistence, interface configuration or even sysfs reads on the workstation.
    alias NervesGate.Network.Host
    defdelegate load(host), to: Host
    defdelegate restore(config, host), to: Host
    def observations(_), do: [{VintageNet, ["interface"]}]

    def snapshot(host) do
      observed = Host.snapshot(host)

      ports =
        Enum.map(observed.ports, fn port ->
          %{port | connection: VintageNet.get(["interface", port.name, "connection"])}
        end)

      %{observed | ports: ports}
    end
  end

  setup do
    # Only cached properties, never the VPN/network applications or host devices.
    for {name, options} <- [
          {Tailscale.Properties,
           properties: [
             {["state"], :online},
             {["auth", "state"], :authenticated},
             {["configuration", "value"], %{hostname: "gateway", advertise_routes: []}},
             {["health"], []},
             {["ipv4"], {100, 64, 0, 10}}
           ]},
          {VintageNet,
           properties: [
             {["connection"], :internet},
             {["interface", "eth0", "connection"], :internet},
             {["interface", "eth1", "connection"], :internet},
             {["interface", "usb0", "connection"], :lan}
           ],
           tuple_events: true}
        ] do
      start_supervised!(Supervisor.child_spec({PropertyTable, [name: name] ++ options}, id: name))
    end

    on_exit(fn ->
      for {name, faults} <- [
            {@network, [:internet_unavailable, :network_restore_failed]},
            {@remote, [:remote_unavailable, :remote_offline, :remote_health]}
          ],
          fault <- faults,
          do: Alarms.report(fault, name, false)

      :gen_event.which_handlers(:alarm_handler)
    end)

    :ok
  end

  test "Running remains a Tailscale state regardless of the Internet uplink" do
    for connection <- [:disconnected, :lan, nil] do
      PropertyTable.put(VintageNet, ["interface", "eth1", "connection"], connection)
      PropertyTable.put(VintageNet, ["connection"], connection)

      assert %{
               state: "online",
               available: true,
               auth_state: "authenticated",
               ipv4: "100.64.0.10"
             } = Remote.Tailscale.snapshot(nil)
    end

    stop_supervised!(VintageNet)
    assert %{state: "online", available: true} = Remote.Tailscale.snapshot(nil)
    refute Enum.any?(Remote.Tailscale.observations(nil), &(elem(&1, 0) == VintageNet))
  end

  test "internet alone does not turn stopped or unavailable Tailscale into online" do
    PropertyTable.put(Tailscale.Properties, ["state"], :offline)
    PropertyTable.put(Tailscale.Properties, ["auth", "state"], :stopped)
    assert %{state: "offline", auth_state: "stopped"} = Remote.Tailscale.snapshot(nil)
    stop_supervised!(Tailscale.Properties)
    assert %{state: "unavailable", available: false} = Remote.Tailscale.snapshot(nil)
  end

  test "only the selected uplink drives Internet alarms and USER1, without polling" do
    indicators = start_domains()
    assert Indicators.status(indicators).led.patterns.user1 == "solid"
    id = {Alarms.Warning, @network, :internet_unavailable}
    Alarmist.subscribe(id)

    # Other interfaces and the global best connection remain online: they must
    # not mask loss on eth1, the configured Internet-facing interface.
    PropertyTable.put(VintageNet, ["interface", "eth1", "connection"], :disconnected)
    eventually(fn -> Indicators.status(indicators).led.patterns.user1 == "slow" end)
    assert_receive %Alarmist.Event{id: ^id, state: :set, level: :warning}, 2_500
    eventually(fn -> Indicators.status(indicators).led.patterns.user1 == "fast" end)
    assert Indicators.status(indicators).led.patterns.run == "solid"
    assert Remote.status(@remote).state == "online"

    PropertyTable.put(VintageNet, ["interface", "eth1", "connection"], :lan)
    assert Alarmist.alarm_state(id) == :set
    PropertyTable.delete(VintageNet, ["interface", "eth1", "connection"])
    refute_receive %Alarmist.Event{id: ^id, state: :clear}, 50
    assert Indicators.status(indicators).led.patterns.user1 == "fast"

    PropertyTable.put(VintageNet, ["interface", "eth1", "connection"], :internet)
    assert_receive %Alarmist.Event{id: ^id, state: :clear}, 500
    eventually(fn -> Indicators.status(indicators).led.patterns.user1 == "solid" end)
  end

  test "Tailscale health notifications alarm independently of Running and Internet" do
    indicators = start_domains()
    id = {Alarms.Warning, @remote, :remote_health}
    Alarmist.subscribe(id)

    PropertyTable.put(Tailscale.Properties, ["health"], [
      "Cannot reach https://private.example/token"
    ])

    eventually(fn -> Indicators.status(indicators).led.patterns.user1 == "slow" end)
    assert_receive %Alarmist.Event{id: ^id, state: :set}, 2_500
    eventually(fn -> Indicators.status(indicators).led.patterns.user1 == "fast" end)
    assert Remote.status(@remote).health == ["Cannot reach [private URL]"]
    assert Remote.status(@remote).state == "online"
    refute inspect(Alarmist.get_alarms(level: :debug)) =~ "private.example"

    PropertyTable.put(Tailscale.Properties, ["health"], [])
    assert_receive %Alarmist.Event{id: ^id, state: :clear}, 500
    eventually(fn -> Indicators.status(indicators).led.patterns.user1 == "solid" end)

    PropertyTable.put(Tailscale.Properties, ["state"], :offline)
    offline = {Alarms.Warning, @remote, :remote_offline}
    Alarmist.subscribe(offline)
    assert_receive %Alarmist.Event{id: ^offline, state: :set}, 2_500
    PropertyTable.put(Tailscale.Properties, ["auth", "state"], :stopped)
    PropertyTable.put(Tailscale.Properties, ["health"], ["stale health"])
    assert_receive %Alarmist.Event{id: ^offline, state: :clear}, 500
    eventually(fn -> Indicators.status(indicators).led.patterns.user1 == "off" end)
    refute_receive %Alarmist.Event{id: ^id, state: :set}, 2_100
  end

  test "unknown uplink is not healthy even with no active alarm" do
    PropertyTable.delete(VintageNet, ["interface", "eth1", "connection"])
    indicators = start_domains()
    assert Indicators.status(indicators).led.patterns.user1 == "slow"
    refute Alarmist.alarm_state({Alarms.Warning, @network, :internet_unavailable}) == :set
  end

  defp start_domains do
    host = start_supervised!({Network.Host, name: nil})

    network = %{
      "mode" => "ports",
      "eth0" => nil,
      "eth1" => %{"role" => "internet", "address" => Config.address_defaults()}
    }

    Network.Host.save(network, host)
    Network.Host.restore(network, host)
    observed = Network.Host.snapshot(host)

    ports =
      Enum.map(
        observed.ports,
        &%{&1 | link: true, addresses: [%{address: "192.0.2.10", prefix_length: 24}]}
      )

    Network.Host.simulate(%{ports: ports}, host)

    start_supervised!(
      {Network, name: @network, adapter: {CachedNetwork, host}, remote: nil, poll_ms: 60_000}
    )

    start_supervised!({Remote, name: @remote, adapter: {Remote.Tailscale, nil}, poll_ms: 60_000})
    leds = start_supervised!({Indicators.Host, name: nil})

    start_supervised!(
      {Indicators,
       name: nil,
       adapter: {Indicators.Host, leds},
       remote: @remote,
       network: @network,
       poll_ms: 60_000}
    )
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end
end
