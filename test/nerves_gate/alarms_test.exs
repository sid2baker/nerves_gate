defmodule NervesGate.AlarmsTest do
  use ExUnit.Case, async: false
  alias NervesGate.{Alarms, Buses, Config, Equipment, Indicators, Network, Remote}
  alias NervesGate.TestNetworkAdapter, as: Adapter

  @network_name __MODULE__.Network
  @led_name __MODULE__.Indicators
  @network_alarm {Alarms, @network_name, :network_restore_failed}
  @led_alarm {Alarms, @led_name, :led_restore_failed}
  @equipment_name __MODULE__.Equipment
  @remote_name __MODULE__.Remote
  @buses_name __MODULE__.Buses
  @equipment_alarm {Alarms, @equipment_name, :equipment_discovery_unavailable}
  @remote_alarm {Alarms, @remote_name, :remote_unavailable}
  @buses_alarm {Alarms, @buses_name, :bus_port_unavailable}

  @equipment_network %{
    "mode" => "ports",
    "eth0" => %{
      "role" => "equipment",
      "address" => %{
        "ip_method" => "static",
        "static_ip" => "192.168.50.2",
        "subnet_mask" => "255.255.255.0",
        "gateway" => nil
      }
    },
    "eth1" => nil
  }

  setup do
    for {_, name, fault} <- [
          @network_alarm,
          @led_alarm,
          @equipment_alarm,
          @remote_alarm,
          @buses_alarm
        ] do
      Alarms.register(name, [fault])
    end

    on_exit(fn ->
      Alarms.report(:network_restore_failed, @network_name, false)
      Alarms.report(:led_restore_failed, @led_name, false)
      Alarms.report(:equipment_discovery_unavailable, @equipment_name, false)
      Alarms.report(:remote_unavailable, @remote_name, false)
      Alarms.report(:remote_health, @remote_name, false)
      Alarms.report(:remote_offline, @remote_name, false)
      Alarms.report(:internet_unavailable, @network_name, false)
      Alarms.report(:recovery_failed, @led_name, false)
      Alarms.report(:bus_port_unavailable, @buses_name, false)
      # Drain the asynchronous reports before another test reuses these names.
      :gen_event.which_handlers(:alarm_handler)
    end)

    :ok
  end

  test "failed network restoration sets an alarm until a verified successful retry, including restart" do
    host = start_supervised!({Network.Host, name: nil})
    adapter = start_supervised!({Adapter, host: host, owner: self()})
    Adapter.fail(adapter, :apply, :offline)
    :ok = Alarmist.subscribe(@network_alarm)
    opts = [name: @network_name, adapter: {Adapter, adapter}, poll_ms: 20]
    start_supervised!({Network, opts})
    assert_receive %Alarmist.Event{id: @network_alarm, state: :set, level: :error}, 1_000
    assert Network.status(@network_name).recovering

    assert {@network_alarm, "Saved network settings could not be restored."} in Alarmist.get_alarms()

    # Missing observations must not replace the restoration error or clear its alarm.
    Adapter.fail(adapter, :snapshot, :unavailable)
    send(@network_name, :poll)
    assert %{observed: nil, error: {:restore, _}} = Network.status(@network_name)
    refute_receive %Alarmist.Event{id: @network_alarm, state: :clear}, 30
    Adapter.fail(adapter, :snapshot, nil)

    stop_supervised!(Network)
    assert Alarmist.alarm_state(@network_alarm) == :set
    start_supervised!({Network, opts})
    refute_receive %Alarmist.Event{id: @network_alarm, state: :clear}, 30
    refute_receive %Alarmist.Event{id: @network_alarm, state: :set}, 30

    Adapter.fail(adapter, :apply, nil)
    send(@network_name, :poll)
    assert_receive %Alarmist.Event{id: @network_alarm, state: :clear}, 1_000
    refute Network.status(@network_name).recovering
    assert Network.status(@network_name).config == Config.defaults()
  end

  test "a timed-out restoration retry never clears its existing fault" do
    host = start_supervised!({Network.Host, name: nil})
    adapter = start_supervised!({Adapter, host: host, owner: self()})
    Adapter.fail(adapter, :apply, :offline)

    start_supervised!(
      {Network, name: @network_name, adapter: {Adapter, adapter}, poll_ms: 20, effect_ms: 40}
    )

    eventually(fn -> Alarmist.alarm_state(@network_alarm) == :set end)
    :ok = Alarmist.subscribe(@network_alarm)
    Adapter.hold(adapter, :apply, Config.defaults()["network"])
    assert_receive {:blocked, :apply, first}, 1_000
    monitor = Process.monitor(first)
    assert_receive {:DOWN, ^monitor, :process, ^first, _}, 1_000
    assert_receive {:blocked, :apply, _second}, 1_000
    refute_receive %Alarmist.Event{id: @network_alarm, state: :clear}, 60
    assert Alarmist.alarm_state(@network_alarm) == :set
    assert Network.status(@network_name).recovering
  end

  test "successful startup clears a stale network alarm; unnamed instances do not overwrite it" do
    Alarms.report(:network_restore_failed, @network_name, true)
    :gen_event.which_handlers(:alarm_handler)
    host = start_supervised!({Network.Host, name: nil})
    unnamed = start_supervised!({Network, name: nil, adapter: {Network.Host, host}})
    assert Network.status(unnamed).phase == :idle
    :gen_event.which_handlers(:alarm_handler)
    assert Alarmist.alarm_state(@network_alarm) == :set
    stop_supervised!(Network)
    start_supervised!({Network, name: @network_name, adapter: {Network.Host, host}})
    eventually(fn -> Alarmist.alarm_state(@network_alarm) == :clear end)
  end

  test "LED control failure clears only after current patterns can be applied" do
    host = start_supervised!({Indicators.Host, name: nil})
    Indicators.Host.simulate(%{write_error: [:run]}, host)
    :ok = Alarmist.subscribe(@led_alarm)
    start_supervised!({Indicators, name: @led_name, adapter: {Indicators.Host, host}})
    assert_receive %Alarmist.Event{id: @led_alarm, state: :set}, 1_000
    assert Indicators.status(@led_name).led.restore_pending
    assert {:error, :led_unavailable} = Indicators.identify(@led_name)
    Indicators.Host.simulate(%{write_error: []}, host)
    send(@led_name, :refresh)
    assert_receive %Alarmist.Event{id: @led_alarm, state: :clear}, 1_000
    refute Indicators.status(@led_name).led.restore_pending
    assert Indicators.Host.snapshot(host).values.run == 1
  end

  test "LED startup reconciles status and alarm events refresh the policy immediately" do
    Alarms.report(:led_restore_failed, @led_name, true)
    :gen_event.which_handlers(:alarm_handler)
    host = start_supervised!({Indicators.Host, name: nil})

    start_supervised!(
      {Indicators, name: @led_name, adapter: {Indicators.Host, host}, poll_ms: 60_000}
    )

    assert Indicators.status(@led_name).led.available
    eventually(fn -> Alarmist.alarm_state(@led_alarm) == :clear end)
    Alarms.report(:network_restore_failed, @network_name, true)
    eventually(fn -> Indicators.status(@led_name).led.patterns.user2 == "fast" end)
    Alarms.report(:network_restore_failed, @network_name, false)
  end

  test "a stalled alarm handler cannot delay a network deadline or rollback" do
    host = start_supervised!({Network.Host, name: nil})
    start_supervised!({Network, name: @network_name, adapter: {Network.Host, host}, trial_ms: 40})
    :sys.suspend(:alarm_handler)

    try do
      network = %{"mode" => "ports", "eth0" => nil, "eth1" => nil}
      assert {:ok, _} = Network.propose(network, @network_name)
      eventually(fn -> Network.status(@network_name).trial == nil end)
      eventually(fn -> not Network.status(@network_name).recovering end)
      assert Network.status(@network_name).config == Config.defaults()
    after
      :sys.resume(:alarm_handler)
    end
  end

  test "equipment discovery faults survive scan success and clear on an empty passive observation" do
    %{equipment: equipment, network: network} = start_equipment()
    assert_receive {:observing, worker, _}
    send(worker, {:return, {:error, :eacces}})
    eventually(fn -> Alarmist.alarm_state(@equipment_alarm) == :set end)
    :ok = Alarmist.subscribe(@equipment_alarm)

    task = Task.async(fn -> NervesGate.equipment_scan(network: network, equipment: equipment) end)
    assert_receive {:scanning, scanner, _}
    send(scanner, :continue)
    assert :ok = Task.await(task)
    refute_receive %Alarmist.Event{id: @equipment_alarm, state: :clear}, 30
    assert Alarmist.alarm_state(@equipment_alarm) == :set

    send(equipment, :poll)
    assert_receive {:observing, recovered, _}
    send(recovered, :continue)
    assert_receive %Alarmist.Event{id: @equipment_alarm, state: :clear}, 1_000
    assert Equipment.status(equipment).entries == []
  end

  test "unknown network state preserves a discovery fault; removing equipment configuration clears it" do
    %{equipment: equipment, network: network} = start_equipment()
    assert_receive {:observing, worker, _}
    send(worker, {:return, {:error, :eacces}})
    eventually(fn -> Alarmist.alarm_state(@equipment_alarm) == :set end)
    :ok = Alarmist.subscribe(@equipment_alarm)

    {:ok, id} = Network.propose(%{"mode" => "ports", "eth0" => nil, "eth1" => nil}, network)
    send(equipment, :poll)
    eventually(fn -> Equipment.status(equipment).scope == nil end)
    refute_receive {:observing, _, _}, 30
    refute_receive %Alarmist.Event{id: @equipment_alarm, state: :clear}, 30

    :ok = Network.confirm(id, network)
    send(equipment, :poll)
    assert_receive %Alarmist.Event{id: @equipment_alarm, state: :clear}, 1_000
    refute_receive {:observing, _, _}, 30
  end

  test "discovery worker death and timeout raise only after the equipment backend was reached" do
    %{equipment: equipment, network: network} = start_equipment(effect_ms: 80)

    for failure <- [:kill, :timeout] do
      assert_receive {:observing, worker, scope}
      %{worker: %{task: %{ref: ref}}} = :sys.get_state(equipment)
      monitor = Process.monitor(worker)
      if failure == :kill, do: Process.exit(worker, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^worker, _}, 1_000
      eventually(fn -> Alarmist.alarm_state(@equipment_alarm) == :set end)
      :ok = Alarmist.subscribe(@equipment_alarm)
      send(equipment, {ref, {scope, {:ok, []}}})
      send(equipment, {:observing, worker, scope})
      refute_receive %Alarmist.Event{id: @equipment_alarm, state: :clear}, 30

      send(equipment, :poll)
      assert_receive {:observing, recovered, _}
      send(recovered, :continue)
      assert_receive %Alarmist.Event{id: @equipment_alarm, state: :clear}, 1_000
      if failure == :kill, do: send(equipment, :poll)
    end

    :sys.suspend(network)

    try do
      send(equipment, :poll)
      eventually(fn -> Equipment.status(equipment).error != nil end)
      refute_receive {:observing, _, _}, 30
      assert Alarmist.alarm_state(@equipment_alarm) == :clear
    after
      :sys.resume(network)
    end
  end

  test "equipment startup and unavailable network observations do not clear a previous fault" do
    %{network: network} = start_equipment()
    assert_receive {:observing, worker, _}
    send(worker, {:return, {:error, :eacces}})
    eventually(fn -> Alarmist.alarm_state(@equipment_alarm) == :set end)
    :ok = Alarmist.subscribe(@equipment_alarm)
    stop_supervised!(Equipment)
    :sys.suspend(network)

    try do
      equipment = restart_equipment(network, effect_ms: 40)
      eventually(fn -> Equipment.status(equipment).error != nil end)
      refute_receive %Alarmist.Event{id: @equipment_alarm, state: :clear}, 30
    after
      :sys.resume(network)
    end

    send(@equipment_name, :poll)
    assert_receive {:observing, recovered, _}
    send(recovered, :continue)
    assert_receive %Alarmist.Event{id: @equipment_alarm, state: :clear}, 1_000
  end

  test "remote daemon loss after connection sets a deduplicated alarm and unknown restart preserves it" do
    {remote, host} = start_remote()
    assert :ok = Remote.connect("gateway", remote)
    eventually(fn -> Remote.status(remote).operation == nil end)
    Remote.Host.simulate(%{available: false}, host)
    send(remote, :poll)
    eventually(fn -> Alarmist.alarm_state(@remote_alarm) == :set end)
    :ok = Alarmist.subscribe(@remote_alarm)
    send(remote, :poll)
    assert Remote.status(remote).available == false
    refute_receive %Alarmist.Event{id: @remote_alarm}, 30

    stop_supervised!(Remote)

    remote =
      start_supervised!(
        {Remote, name: @remote_name, adapter: {Remote.Host, host}, poll_ms: 60_000}
      )

    refute Remote.status(remote).available
    refute_receive %Alarmist.Event{id: @remote_alarm, state: :clear}, 30

    Remote.Host.simulate(%{auth_state: "needs_approval"}, host)
    send(remote, :poll)
    assert_receive %Alarmist.Event{id: @remote_alarm, state: :clear}, 1_000
    assert Remote.status(remote).state == "offline"
  end

  test "a deliberately disconnected remote and an unconfigured remote do not require a daemon" do
    {remote, host} = start_remote()
    assert {:error, _} = Remote.connect("invalid name", remote)
    Remote.Host.simulate(%{available: false}, host)
    send(remote, :poll)
    refute Remote.status(remote).available
    refute Alarmist.alarm_state(@remote_alarm) == :set

    Remote.Host.simulate(%{}, host)
    assert :ok = Remote.connect("gateway", remote)
    eventually(fn -> Remote.status(remote).operation == nil end)
    assert :ok = Remote.disconnect(remote)
    eventually(fn -> Remote.status(remote).operation == nil end)
    Remote.Host.simulate(%{available: false}, host)
    send(remote, :poll)
    refute Remote.status(remote).available
    :gen_event.which_handlers(:alarm_handler)
    refute Alarmist.alarm_state(@remote_alarm) == :set
  end

  test "enabled bus ports remain expected when missing; another command cannot clear their alarm" do
    {buses, host} = start_buses()
    assert :ok = Buses.configure("ttyS3", %{"enabled" => true}, buses)
    assert :ok = Buses.configure("can0", %{"enabled" => true, "bitrate" => 125_000}, buses)
    eventually(fn -> Buses.status(buses).operation == nil end)
    original = Buses.Host.snapshot(host)
    calls = Buses.Host.calls(host)

    missing =
      for port <- original,
          do:
            if(port.name in ["can0", "ttyS3"],
              do: %{port | present: false, enabled: false},
              else: port
            )

    Buses.Host.simulate(%{ports: missing}, host)
    send(buses, :poll)
    eventually(fn -> Alarmist.alarm_state(@buses_alarm) == :set end)
    :ok = Alarmist.subscribe(@buses_alarm)
    send(buses, :poll)
    assert Buses.status(buses).operation == nil
    assert Buses.Host.calls(host) == calls
    refute_receive %Alarmist.Event{id: @buses_alarm}, 30

    assert :ok = Buses.configure("ttyS4", %{"enabled" => true}, buses)
    refute_receive %Alarmist.Event{id: @buses_alarm, state: :clear}, 30
    Buses.Host.simulate(%{ports: Enum.reject(original, &(&1.name == "can0"))}, host)
    send(buses, :poll)
    refute_receive %Alarmist.Event{id: @buses_alarm, state: :clear}, 30

    Buses.Host.simulate(%{ports: original}, host)
    send(buses, :poll)
    assert_receive %Alarmist.Event{id: @buses_alarm, state: :clear}, 1_000
  end

  test "disabled ports do not alarm and bus command failures are not availability faults" do
    {buses, host} = start_buses()
    ports = Buses.Host.snapshot(host)
    Buses.Host.simulate(%{ports: Enum.map(ports, &%{&1 | present: false})}, host)
    send(buses, :poll)

    assert {:error, :bus_missing} =
             Buses.configure("can0", %{"enabled" => true, "bitrate" => 125_000}, buses)

    :gen_event.which_handlers(:alarm_handler)
    refute Alarmist.alarm_state(@buses_alarm) == :set

    Buses.Host.simulate(%{ports: ports, failure: :modbus_timeout}, host)
    send(buses, :poll)
    assert :ok = Buses.configure("ttyS3", %{"enabled" => true}, buses)
    assert :ok = Buses.capture("ttyS3", buses)
    eventually(fn -> Buses.status(buses).operation == nil end)
    assert Buses.status(buses).error.code == "modbus_timeout"
    refute Alarmist.alarm_state(@buses_alarm) == :set
  end

  test "unknown CAN enablement after restart does not erase a previously reported bus fault" do
    {buses, host} = start_buses()
    assert :ok = Buses.configure("can0", %{"enabled" => true, "bitrate" => 125_000}, buses)
    eventually(fn -> Buses.status(buses).operation == nil end)
    ports = Buses.Host.snapshot(host)
    Buses.Host.simulate(%{ports: Enum.reject(ports, &(&1.name == "can0"))}, host)
    send(buses, :poll)
    eventually(fn -> Alarmist.alarm_state(@buses_alarm) == :set end)
    :ok = Alarmist.subscribe(@buses_alarm)
    stop_supervised!(Buses)
    buses = start_supervised!({Buses, name: @buses_name, adapter: {Buses.Host, host}})
    assert [_, _, _] = Buses.status(buses).ports
    refute_receive %Alarmist.Event{id: @buses_alarm, state: :clear}, 30
    Buses.Host.simulate(%{ports: ports}, host)
    send(buses, :poll)
    assert_receive %Alarmist.Event{id: @buses_alarm, state: :clear}, 1_000
  end

  test "unnamed domain instances cannot overwrite named alarms" do
    for {_, name, fault} <- [@equipment_alarm, @remote_alarm, @buses_alarm],
        do: Alarms.report(fault, name, true)

    %{equipment: equipment} = start_equipment(name: nil)
    assert_receive {:observing, worker, _}
    send(worker, :continue)
    eventually(fn -> :sys.get_state(equipment).worker == nil end)
    {remote, _} = start_remote(name: nil)
    {buses, _} = start_buses(name: nil)
    assert Remote.status(remote).available
    assert [_, _, _, _] = Buses.status(buses).ports
    :gen_event.which_handlers(:alarm_handler)

    for alarm <- [@equipment_alarm, @remote_alarm, @buses_alarm],
        do: assert(Alarmist.alarm_state(alarm) == :set)
  end

  test "all availability faults use Alarmist debounce, deduplication and factual clearing" do
    faults = [
      {@network_name, :internet_unavailable},
      {@equipment_name, :equipment_discovery_unavailable},
      {@remote_name, :remote_unavailable},
      {@remote_name, :remote_health},
      {@remote_name, :remote_offline},
      {@buses_name, :bus_port_unavailable}
    ]

    for {name, fault} <- faults do
      Alarms.register(name, [fault])
      Alarmist.subscribe({Alarms.Warning, name, fault})
      Alarms.report(fault, name, true)
    end

    :gen_event.which_handlers(:alarm_handler)
    refute_receive %Alarmist.Event{state: :set}, 50

    for {name, fault} <- faults do
      assert Alarmist.alarm_state({Alarms, name, fault}) == :set
      refute {Alarms, name, fault} in Alarmist.get_alarm_ids()
      Alarms.report(fault, name, false)
    end

    :gen_event.which_handlers(:alarm_handler)
    refute_receive %Alarmist.Event{state: :set}, 2_100

    for {name, fault} <- faults, do: Alarms.report(fault, name, true)
    refute_receive %Alarmist.Event{state: :set}, 1_000

    # Registration after a producer restart must not restart the debounce clock.
    for {name, fault} <- faults, do: Alarms.register(name, [fault])

    for {name, fault} <- faults do
      id = {Alarms.Warning, name, fault}
      assert_receive %Alarmist.Event{id: ^id, state: :set, level: :warning}, 1_200
      Alarms.report(fault, name, nil)
      Alarms.report(fault, name, true)
    end

    refute_receive %Alarmist.Event{state: :set}, 30
    assert Alarms.indication(@network_name, @remote_name).connection

    for {name, fault} <- faults do
      id = {Alarms.Warning, name, fault}
      Alarms.report(fault, name, false)
      assert_receive %Alarmist.Event{id: ^id, state: :clear}, 500
    end

    refute Alarms.indication(@network_name, @remote_name).connection
  end

  test "a physical recovery failure is immediate and drives LEDs through Alarmist" do
    host = start_supervised!({Indicators.Host, name: nil})
    start_supervised!({Indicators, name: @led_name, adapter: {Indicators.Host, host}})
    id = {Alarms, @led_name, :recovery_failed}
    Alarmist.subscribe(id)
    Alarms.report(:recovery_failed, @led_name, true)
    assert_receive %Alarmist.Event{id: ^id, state: :set, level: :error}, 500
    eventually(fn -> Indicators.status(@led_name).led.patterns.user2 == "fast" end)
    Alarms.report(:recovery_failed, @led_name, nil)
    assert Alarmist.alarm_state(id) == :set
  end

  defp start_equipment(opts \\ []) do
    host = start_supervised!({Network.Host, name: nil})
    :ok = Network.Host.save(@equipment_network, host)
    network = start_supervised!({Network, name: nil, adapter: {Network.Host, host}})
    %{network: network, equipment: restart_equipment(network, opts)}
  end

  defp restart_equipment(network, opts) do
    host = start_supervised!({Equipment.Host, name: nil}, id: make_ref())

    opts =
      Keyword.merge(
        [
          name: @equipment_name,
          network: network,
          adapter: {NervesGate.TestEquipmentAdapter, %{host: host, owner: self(), observe: true}},
          poll_ms: 60_000,
          effect_ms: 1_000
        ],
        opts
      )

    start_supervised!({Equipment, opts})
  end

  defp start_remote(opts \\ []) do
    host = start_supervised!({Remote.Host, name: nil})

    opts =
      Keyword.merge([name: @remote_name, adapter: {Remote.Host, host}, poll_ms: 60_000], opts)

    {start_supervised!({Remote, opts}), host}
  end

  defp start_buses(opts \\ []) do
    host = start_supervised!({Buses.Host, name: nil})
    Buses.Host.simulate(%{delay: 0}, host)
    opts = Keyword.merge([name: @buses_name, adapter: {Buses.Host, host}], opts)
    {start_supervised!({Buses, opts}), host}
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
