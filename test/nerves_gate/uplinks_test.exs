defmodule NervesGate.UplinksTest do
  use ExUnit.Case, async: false
  alias NervesGate.{Alarms, Config, Network}
  alias NervesGate.Network.{Host, Policy, RouteMetric}
  alias NervesGate.Observations.Network, as: Observation
  alias VintageNet.Route.InterfaceInfo

  @name __MODULE__.Network
  @backup %{
    "mode" => "ports",
    "eth0" => %{"role" => "internet", "address" => Config.address_defaults()},
    "eth1" => nil,
    "internet" => %{"mode" => "backup", "apn" => "internet.example"}
  }
  @cellular %{
    @backup
    | "eth0" => nil,
      "internet" => %{"mode" => "cellular", "apn" => "internet.example"}
  }

  setup do
    host = start_supervised!({Host, name: nil})
    opts = [name: @name, adapter: {Host, host}, poll_ms: 10, trial_ms: 10_000]
    server = start_supervised!({Network, opts})

    on_exit(fn ->
      for fault <- [
            :network_restore_failed,
            :internet_unavailable,
            :internet_backup,
            :cellular_unavailable
          ],
          do: Alarms.report(fault, @name, false)

      :gen_event.which_handlers(:alarm_handler)
    end)

    %{host: host, server: server, opts: opts}
  end

  test "legacy Ethernet settings stay unchanged and cellular combinations are explicit" do
    legacy = Map.delete(@backup, "internet")
    assert Config.validate_network(legacy) == {:ok, legacy}
    assert Config.internet(legacy) == %{"mode" => "ethernet"}
    assert Config.validate_network(@backup) == {:ok, @backup}
    assert Config.validate_network(@cellular) == {:ok, @cellular}
    assert {:error, _} = Config.validate_network(%{@backup | "eth0" => nil})
    assert {:error, _} = Config.validate_network(%{@cellular | "eth0" => @backup["eth0"]})

    for apn <- [nil, "", "bad\napn", String.duplicate("a", 101)] do
      assert {:error, _} = Config.validate_network(put_in(@cellular, ["internet", "apn"], apn))
    end
  end

  test "VintageNet metrics prefer working Ethernet, then working cellular, not merely a LAN link" do
    ethernet = %InterfaceInfo{interface_type: :ethernet, status: :internet}
    modem = %InterfaceInfo{interface_type: :mobile, status: :internet}

    config =
      Elixir.Config.Reader.read!(Path.expand("../../config/target.exs", __DIR__), target: :ec100)

    {module, function, arity} = config[:vintage_net][:route_metric_fun]
    metric = Function.capture(module, function, arity)

    assert metric.("br0", %{ethernet | interface_type: :unknown}) ==
             RouteMetric.compute_metric("eth0", ethernet)

    assert RouteMetric.compute_metric("eth0", ethernet) <
             RouteMetric.compute_metric("wwan0", modem)

    assert RouteMetric.compute_metric("wwan0", modem) <
             RouteMetric.compute_metric("eth0", %{ethernet | status: :lan})

    assert RouteMetric.compute_metric("eth0", %{ethernet | status: :disconnected}) == :disabled

    assert RouteMetric.compute_metric("br0", %{ethernet | interface_type: :unknown}) <
             RouteMetric.compute_metric("cell0", %{modem | interface_type: :unknown})
  end

  test "both modes save offline, missing modem is not readiness, cancellation and restart restore policy",
       ctx do
    for network <- [@backup, @cellular] do
      assert {:ok, id} = Network.propose(network, ctx.server)
      assert Network.status(ctx.server).ready
      refute Observation.internet(Network.status(ctx.server)).online
      assert :ok = Network.confirm(id, ctx.server)
      assert {:ok, %{"network" => ^network}} = Host.load(ctx.host)
    end

    cell = Host.snapshot(ctx.host).cellular
    Host.simulate(%{cellular: %{cell | present: false}}, ctx.host)
    assert {:ok, id} = Network.propose(@cellular, ctx.server)
    assert Network.status(ctx.server).ready
    assert :ok = Network.cancel(id, ctx.server)
    assert {:ok, id} = Network.propose(@backup, ctx.server)
    assert :ok = Network.cancel(id, ctx.server)
    assert Network.status(ctx.server).config["network"] == @cellular

    assert {:ok, _id} = Network.propose(@backup, ctx.server)
    stop_supervised!(Network)
    server = start_supervised!({Network, ctx.opts})
    assert Network.status(server).trial == nil
    assert Network.status(server).config["network"] == @cellular
  end

  test "unsupported firmware rejects cellular before a trial or Ethernet change", ctx do
    Host.simulate(%{cellular_supported: false, cellular: nil}, ctx.host)
    assert {:error, :cellular_unsupported} = Network.propose(@backup, ctx.server)
    assert Network.status(ctx.server).trial == nil
    assert {:ok, config} = Host.load(ctx.host)
    assert config == Config.defaults()
  end

  test "failover, failback, permitted uplinks, unknown and overlapping cellular subnets", ctx do
    {:ok, _} = Network.propose(@backup, ctx.server)
    observed = Host.snapshot(ctx.host)
    [ethernet, equipment] = observed.ports
    ethernet = %{ethernet | connection: :internet}

    cellular = %{
      observed.cellular
      | connection: :internet,
        addresses: [%{address: "100.64.0.2", prefix_length: 30}]
    }

    observed = %{observed | ports: [ethernet, equipment], cellular: cellular}
    status = %{config: Config.from_network(@backup), observed: observed}
    assert %{selected: "eth0", online: true, backup: false} = Observation.internet(status)

    for loss <- [:lan, :disconnected] do
      status = put_in(status, [:observed, :ports], [%{ethernet | connection: loss}, equipment])
      assert %{selected: "wwan0", online: true, backup: true} = Observation.internet(status)
    end

    # Only the configured uplinks count; neither USB nor another Ethernet can mask failure.
    lost = %{
      observed
      | ports: [%{ethernet | connection: :lan}, %{equipment | connection: :internet}],
        usb: %{observed.usb | connection: :internet},
        cellular: %{cellular | present: false}
    }

    assert %{online: false, connection: :lan} = Observation.internet(%{status | observed: lost})

    assert %{connection: :unknown} =
             Observation.internet(%{status | observed: %{lost | cellular: nil}})

    assert %{selected: "eth0"} = Observation.internet(status)

    assert %{selected: "wwan0"} =
             Observation.internet(%{status | config: Config.from_network(@cellular)})

    refute Observation.internet(%{
             status
             | config: Config.from_network(@cellular),
               observed: lost
           }).online

    overlap = %{observed | cellular: %{cellular | addresses: ethernet.addresses}}
    assert [_] = Policy.conflicts(overlap, @backup)
    assert Policy.conflicts(overlap, Map.delete(@backup, "internet")) == []
  end

  test "backup is a managed warning, not an Internet outage or a USER1 connection fault", ctx do
    backup = {Alarms.Warning, @name, :internet_backup}
    outage = {Alarms.Warning, @name, :internet_unavailable}
    cellular_fault = {Alarms.Warning, @name, :cellular_unavailable}
    for id <- [backup, outage, cellular_fault], do: Alarmist.subscribe(id)
    {:ok, _} = Network.propose(@backup, ctx.server)
    observed = Host.snapshot(ctx.host)
    [ethernet, equipment] = observed.ports

    cellular = %{
      observed.cellular
      | connection: :internet,
        addresses: [%{address: "100.64.0.2", prefix_length: 30}]
    }

    Host.simulate(
      %{cellular: cellular, ports: [%{ethernet | connection: :lan}, equipment]},
      ctx.host
    )

    assert_receive %Alarmist.Event{id: ^backup, state: :set, level: :warning}, 3_000
    refute Alarmist.alarm_state(outage) == :set
    assert %{connection: false, severity: :warning} = Alarms.indication(@name, nil)

    Host.simulate(%{cellular: nil}, ctx.host)
    refute_receive %Alarmist.Event{id: ^backup, state: :clear}, 100
    assert Alarmist.alarm_state(backup) == :set

    Host.simulate(%{cellular: %{cellular | present: false}}, ctx.host)
    assert_receive %Alarmist.Event{id: ^outage, state: :set}, 3_000
    assert_receive %Alarmist.Event{id: ^cellular_fault, state: :set}, 1_000
    assert Alarms.indication(@name, nil).connection

    Host.simulate(
      %{cellular: cellular, ports: [%{ethernet | connection: :internet}, equipment]},
      ctx.host
    )

    assert_receive %Alarmist.Event{id: ^outage, state: :clear}, 1_000
    assert_receive %Alarmist.Event{id: ^cellular_fault, state: :clear}, 1_000
    refute Alarms.indication(@name, nil).connection
  end
end
