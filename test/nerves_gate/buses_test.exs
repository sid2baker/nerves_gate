defmodule NervesGate.BusesTest do
  use ExUnit.Case, async: true
  alias NervesGate.Buses
  alias NervesGate.Buses.Host

  @read %{
    "unit" => "1",
    "function" => "3",
    "address" => "10",
    "count" => "2",
    "authorized" => "true"
  }
  @can %{"enabled" => "true", "bitrate" => "125000"}

  setup do
    host = start_supervised!({Host, name: nil})
    server = start_supervised!({Buses, name: nil, adapter: {Host, host}})
    api = [buses: server, network: nil, remote: nil, equipment: nil, indicators: nil]
    assert Enum.count_until(NervesGate.Buses.status(server).ports(), 4 + 1) == 4
    %{server: server, host: host, api: api}
  end

  test "reading and subscribing are passive; disabled ports cannot capture", ctx do
    assert :ok = NervesGate.subscribe(ctx.api)
    status = NervesGate.status(ctx.api)
    assert status.buses.simulated
    assert Jason.encode!(status) =~ "rs485"

    for name <- ["can0", "can1", "ttyS3", "ttyS4"] do
      assert {:error, %{code: "bus_disabled"}} = NervesGate.bus_capture(name, ctx.api)
    end

    assert {:error, %{code: "bus_disabled"}} = NervesGate.modbus_read("ttyS3", @read, ctx.api)
    assert Host.calls(ctx.host) == []
  end

  test "CAN config is explicit and always listen-only; one worker prevents overlap", ctx do
    Host.simulate(%{delay: 100}, ctx.host)
    assert :ok = NervesGate.bus_configure("can0", @can, ctx.api)
    assert Buses.status(ctx.server).operation == %{kind: "configure", port: "can0"}

    assert {:error, %{code: "operation_in_progress"}} =
             NervesGate.bus_configure("can1", @can, ctx.api)

    refute NervesGate.status(ctx.api).actions["bus.capture"].enabled
    await_idle(ctx.server)
    assert hd(Buses.status(ctx.server).ports).enabled

    assert [{:configure, "can0", %{enabled: true, bitrate: 125_000, listen_only: true}}] =
             Host.calls(ctx.host)

    :ok = NervesGate.subscribe(ctx.api)
    assert :ok = NervesGate.bus_capture("can0", ctx.api)
    await_idle(ctx.server)
    assert [%{data: "01020304"}] = Buses.status(ctx.server).result.data.frames
    assert_receive %PropertyTable.Event{}
    assert :ok = NervesGate.bus_configure("can0", %{@can | "enabled" => "false"}, ctx.api)
    await_idle(ctx.server)
    refute hd(Buses.status(ctx.server).ports).enabled
  end

  test "RS485 opt-in opens nothing; reads are one-shot and mode resets without replay", ctx do
    assert :ok = NervesGate.bus_configure("ttyS3", %{"enabled" => "true"}, ctx.api)
    assert Host.calls(ctx.host) == []
    assert :ok = NervesGate.modbus_read("ttyS3", @read, ctx.api)
    await_idle(ctx.server)
    assert Buses.status(ctx.server).result.data.registers == [10, 11]
    assert :ok = NervesGate.bus_capture("ttyS3", ctx.api)
    await_idle(ctx.server)
    assert Buses.status(ctx.server).result.data.bytes == 7
    calls = Host.calls(ctx.host)
    stop_supervised!(Buses)
    server = start_supervised!({Buses, name: nil, adapter: {Host, ctx.host}})
    refute Enum.find(Buses.status(server).ports, &(&1.name == "ttyS3")).enabled
    assert Buses.status(server).result == nil
    assert Host.calls(ctx.host) == calls
  end

  test "reject console, arbitrary paths, write functions, broadcasts, ranges and missing consent",
       ctx do
    for name <- ["ttyS0", "/dev/ttyS3", "can2", "eth0", nil, %{}] do
      assert {:error, _} = NervesGate.bus_configure(name, @can, ctx.api)
      assert {:error, _} = NervesGate.bus_capture(name, ctx.api)
      assert {:error, _} = NervesGate.modbus_read(name, @read, ctx.api)
    end

    for params <- [
          nil,
          %{},
          %{"enabled" => "yes", "bitrate" => "125000"},
          %{@can | "bitrate" => "125000;reboot"}
        ] do
      assert {:error, %{code: "invalid_parameters"}} =
               NervesGate.bus_configure("can0", params, ctx.api)
    end

    for {key, value} <- [
          {"function", "6"},
          {"function", "16"},
          {"unit", "0"},
          {"unit", "248"},
          {"count", "0"},
          {"count", "33"},
          {"address", "65535"},
          {"address", "-1"},
          {"authorized", "false"}
        ] do
      assert {:error, %{code: "invalid_parameters"}} =
               NervesGate.modbus_read("ttyS3", Map.put(@read, key, value), ctx.api)
    end

    assert Host.calls(ctx.host) == []
  end

  test "missing and externally normal-mode CAN are not represented as passive", ctx do
    ports = Host.snapshot(ctx.host)
    [can | rest] = ports
    Host.simulate(%{ports: [%{can | enabled: true, listen_only: false} | rest]}, ctx.host)
    send(ctx.server, :poll)
    assert {:error, %{code: "can_not_passive"}} = NervesGate.bus_capture("can0", ctx.api)
    Host.simulate(%{ports: [%{can | present: false} | rest]}, ctx.host)
    send(ctx.server, :poll)
    assert {:error, %{code: "bus_missing"}} = NervesGate.bus_configure("can0", @can, ctx.api)
    assert Host.calls(ctx.host) == []
  end

  test "failure and timeout release the worker without retries; stale messages cannot complete new work",
       ctx do
    :ok = NervesGate.bus_configure("ttyS4", %{"enabled" => "true"}, ctx.api)
    Host.simulate(%{failure: {:modbus_exception, 2}}, ctx.host)
    :ok = NervesGate.modbus_read("ttyS4", @read, ctx.api)
    await_idle(ctx.server)
    assert Buses.status(ctx.server).error.code == "modbus_exception"
    Host.simulate(%{failure: nil, delay: 2_000}, ctx.host)
    :sys.replace_state(ctx.server, &%{&1 | timeout: 30})
    :ok = NervesGate.bus_capture("ttyS4", ctx.api)
    {task, _} = :sys.get_state(ctx.server).worker
    monitor = Process.monitor(task.pid)
    await_idle(ctx.server)
    assert_receive {:DOWN, ^monitor, :process, _, :killed}
    assert Buses.status(ctx.server).error.code == "bus_timeout"
    send(ctx.server, {task.ref, {:ok, %{hex: "STALE"}}})
    send(ctx.server, {:timeout, task.ref})
    assert Buses.status(ctx.server).result == nil
    assert Enum.count_until(NervesGate.Buses.Host.calls(ctx.host()), 2 + 1) == 2
  end

  test "a crashed worker releases admission and a later operation can succeed", ctx do
    :ok = NervesGate.bus_configure("ttyS3", %{"enabled" => "true"}, ctx.api)
    Host.simulate(%{delay: 2_000}, ctx.host)
    :ok = NervesGate.bus_capture("ttyS3", ctx.api)
    {task, _} = :sys.get_state(ctx.server).worker
    Process.exit(task.pid, :kill)
    await_idle(ctx.server)
    assert Buses.status(ctx.server).error.code == "bus_failed"
    assert Process.alive?(ctx.server)
    Host.simulate(%{delay: 1}, ctx.host)
    :ok = NervesGate.bus_capture("ttyS3", ctx.api)
    await_idle(ctx.server)
    assert Buses.status(ctx.server).error == nil
    assert Buses.status(ctx.server).result.data.bytes == 7
  end

  test "service termination stops its worker, unsupported targets and absent services fail closed",
       ctx do
    :ok = NervesGate.bus_configure("ttyS3", %{"enabled" => "true"}, ctx.api)
    Host.simulate(%{delay: 2_000}, ctx.host)
    :ok = NervesGate.bus_capture("ttyS3", ctx.api)
    {task, _} = :sys.get_state(ctx.server).worker
    monitor = Process.monitor(task.pid)
    stop_supervised!(Buses)
    assert_receive {:DOWN, ^monitor, :process, _, :killed}
    refute NervesGate.status(ctx.api).buses.available
    assert {:error, _} = NervesGate.bus_capture("ttyS3", ctx.api)
    server = start_supervised!({Buses, name: nil, adapter: nil})
    refute Buses.status(server).available
    assert {:error, :bus_unsupported} = Buses.configure("can0", @can, server)
  end

  defp await_idle(server, remaining \\ 100)
  defp await_idle(server, 0), do: assert(Buses.status(server).operation == nil)

  defp await_idle(server, remaining) do
    if Buses.status(server).operation do
      Process.sleep(10)
      await_idle(server, remaining - 1)
    else
      :ok
    end
  end
end
