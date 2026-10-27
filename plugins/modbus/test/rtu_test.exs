defmodule ModbusPlugin.RTUTest do
  use ExUnit.Case, async: false
  import Bitwise
  alias ModbusPlugin.{Config, Connection}

  setup do
    dir = Path.join(System.tmp_dir!(), "gate-rtu-" <> Base.encode16(:crypto.strong_rand_bytes(8)))
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    executable =
      System.find_executable("socat") || raise "RTU tests require socat for disposable PTYs"

    a = Path.join(dir, "master")
    b = Path.join(dir, "peer")

    start_supervised!(
      {MuonTrap.Daemon, [executable, ["pty,raw,echo=0,link=#{a}", "pty,raw,echo=0,link=#{b}"]]},
      id: :pty_bridge
    )

    await(fn -> File.exists?(a) and File.exists?(b) end)
    {:ok, config} = Config.validate("rtu-test", params())
    %{a: a, b: b, config: Map.put(config, :serial_path, a)}
  end

  test "RTU is explicit, read-only and never accepts arbitrary device paths" do
    assert {:ok, %{transport: "rtu"}} = Config.validate("one", params())

    assert {:error, :invalid_configuration} =
             Config.validate("one", Map.put(params(), "authorized", false))

    assert {:error, :invalid_configuration} =
             Config.validate("one", Map.put(params(), "serial_port", "/dev/ttyS0"))

    assert {:error, :invalid_configuration} = Config.validate("one", Map.put(params(), "unit", 0))
    assert :ok = ModbusPlugin.configure("unassigned", params())
    assert {:error, _} = ModbusPlugin.connect("unassigned")
    assert Connection.pid("unassigned") == nil
  end

  test "an unverified dead RTU worker cannot be reopened or reconfigured" do
    {:ok, config} = Config.validate("lost", params())
    configs = %{"lost" => Map.put(config, :serial_monitor, make_ref())}

    assert {:reply, {:error, :connection_cleanup_required}, ^configs} =
             ModbusPlugin.handle_call({:connect, "lost"}, {self(), make_ref()}, configs)

    assert {:reply, {:error, :connection_cleanup_required}, ^configs} =
             ModbusPlugin.handle_call(
               {:configure, "lost", params()},
               {self(), make_ref()},
               configs
             )

    assert {:reply, {:error, :connection_cleanup_required}, ^configs} =
             ModbusPlugin.handle_call({:disconnect, "lost"}, {self(), make_ref()}, configs)

    assert {:reply, [%{state: :cleanup_required} = public], ^configs} =
             ModbusPlugin.handle_call(:status, {self(), make_ref()}, configs)

    refute Map.has_key?(public, :serial_monitor)
  end

  test "real yamodbus and circuits_uart exchange RTU frames and drain native handles", %{
    b: peer,
    config: config
  } do
    uart = start_supervised!({Circuits.UART, []})
    :ok = Circuits.UART.open(uart, peer, active: false, speed: 9600, parity: :none)
    worker = start_supervised!({Connection, config})
    client = :sys.get_state(worker).client
    configs = %{"rtu-test" => config, "second" => %{config | id: "second"}}

    assert {:reply, {:error, :serial_port_in_use}, ^configs} =
             ModbusPlugin.handle_call({:connect, "second"}, {self(), make_ref()}, configs)

    assert {:ok, <<1, 3, 0, 10, 0, 2, crc::little-16>>} = read_frame(uart, 8)
    assert crc == checksum(<<1, 3, 0, 10, 0, 2>>)
    response = <<1, 3, 4, 0, 42, 0, 43>>
    :ok = Circuits.UART.write(uart, <<response::binary, checksum(response)::little-16>>)
    await(fn -> Connection.status("rtu-test").values == [42, 43] end)
    assert :ok = stop_supervised(Connection)
    refute Process.alive?(worker)
    refute Process.alive?(client)
    # A second real driver can open the master immediately after checked stop.
    replacement = start_supervised!({Circuits.UART, []}, id: :replacement)
    assert :ok = Circuits.UART.open(replacement, config.serial_path, active: false, parity: :none)
  end

  test "one plugin can supervise independent RTU workers on two ports", %{
    b: peer1,
    config: config1
  } do
    root = Path.dirname(config1.serial_path)
    master2 = Path.join(root, "master2")
    peer2 = Path.join(root, "peer2")

    start_supervised!(
      {MuonTrap.Daemon,
       [
         System.find_executable("socat"),
         ["pty,raw,echo=0,link=#{master2}", "pty,raw,echo=0,link=#{peer2}"]
       ]},
      id: :second_pty_bridge
    )

    await(fn -> File.exists?(peer2) end)
    uart1 = start_supervised!({Circuits.UART, []}, id: :peer1)
    uart2 = start_supervised!({Circuits.UART, []}, id: :peer2)
    :ok = Circuits.UART.open(uart1, peer1, active: false, parity: :none)
    :ok = Circuits.UART.open(uart2, peer2, active: false, parity: :none)
    start_supervised!({Connection, config1}, id: :connection1)
    config2 = %{config1 | id: "second-port", serial_port: "ttyS4", serial_path: master2}
    start_supervised!({Connection, config2}, id: :connection2)

    for {uart, value} <- [{uart1, 42}, {uart2, 84}] do
      assert {:ok, _} = read_frame(uart, 8)
      bytes = <<1, 3, 4, value::16, value + 1::16>>
      :ok = Circuits.UART.write(uart, <<bytes::binary, checksum(bytes)::little-16>>)
    end

    await(fn -> Connection.status("rtu-test").values == [42, 43] end)
    await(fn -> Connection.status("second-port").values == [84, 85] end)
    :ok = stop_supervised(:connection1)
    assert Connection.status("second-port").values == [84, 85]
  end

  test "RTU exception and timeout are surfaced without stale values", %{b: peer, config: config} do
    uart = start_supervised!({Circuits.UART, []})
    :ok = Circuits.UART.open(uart, peer, active: false, parity: :none)
    start_supervised!({Connection, config})
    assert {:ok, _} = read_frame(uart, 8)
    exception = <<1, 0x83, 2>>
    :ok = Circuits.UART.write(uart, <<exception::binary, checksum(exception)::little-16>>)
    await(fn -> Connection.status("rtu-test").error == {:exception, :illegal_data_address} end)
    assert {:ok, _} = read_frame(uart, 8)
    await(fn -> Connection.status("rtu-test").error == :timeout end)
    assert Connection.status("rtu-test").values == nil
  end

  defp params,
    do: %{
      "transport" => "rtu",
      "serial_port" => "ttyS3",
      "authorized" => true,
      "unit" => 1,
      "table" => "holding",
      "address" => 10,
      "count" => 2,
      "interval" => 500,
      "timeout" => 200
    }

  defp read_frame(uart, count, bytes \\ <<>>, attempts \\ 20)
  defp read_frame(_, count, bytes, _) when byte_size(bytes) >= count, do: {:ok, bytes}
  defp read_frame(_, _, _, 0), do: {:error, :timeout}

  defp read_frame(uart, count, bytes, attempts) do
    {:ok, chunk} = Circuits.UART.read(uart, 100)
    read_frame(uart, count, bytes <> chunk, attempts - 1)
  end

  defp checksum(bytes) do
    for <<byte <- bytes>>, reduce: 0xFFFF do
      crc ->
        Enum.reduce(1..8, bxor(crc, byte), fn _, n ->
          if (n &&& 1) == 1, do: bxor(n >>> 1, 0xA001), else: n >>> 1
        end)
    end
  end

  defp await(fun, count \\ 200)
  defp await(fun, 0), do: assert(fun.())

  defp await(fun, count) do
    unless fun.(),
      do:
        (
          Process.sleep(10)
          await(fun, count - 1)
        )
  end
end
