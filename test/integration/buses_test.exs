# Isolated PTYs only: MIX_TARGET=host mix run --no-start test/integration/buses_test.exs --pty
# Requires socat. This never opens an EC100/workstation hardware device.
ExUnit.start()
Application.ensure_all_started(:circuits_uart)

defmodule NervesGate.SerialIntegrationTest do
  use ExUnit.Case, async: false
  alias Circuits.UART
  alias NervesGate.Buses.{Modbus, Serial}

  @request %{unit: 1, function: 3, address: 0, count: 2}

  setup do
    root = Path.join(System.tmp_dir!(), "gate-pty-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    client = Path.join(root, "client")
    peer = Path.join(root, "peer")

    executable =
      System.find_executable("socat") || raise "Install socat for PTY integration tests"

    relay =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["pty,raw,echo=0,link=#{client}", "pty,raw,echo=0,link=#{peer}"]
      ])

    wait_path(peer, 100)
    {:ok, uart} = UART.start_link()
    :ok = UART.open(uart, peer, active: false, speed: 9600)

    on_exit(fn ->
      if Port.info(relay), do: Port.close(relay)
      File.rm_rf!(root)
    end)

    %{client: client, peer: uart}
  end

  test "one RTU read accepts a fragmented CRC-checked response and releases the port", ctx do
    task = Task.async(fn -> Serial.run(ctx.client, :modbus_read, @request) end)
    assert read_bytes(ctx.peer, 8) == Modbus.request(@request)
    <<first::binary-size(4), rest::binary>> = Modbus.checksum(<<1, 3, 4, 42::16, 65_535::16>>)
    :ok = UART.write(ctx.peer, first)
    Process.sleep(20)
    :ok = UART.write(ctx.peer, rest)
    assert {:ok, %{registers: [42, 65_535]}} = Task.await(task, 3_000)
    assert {:ok, ""} = UART.read(ctx.peer, 100)
    assert_released(ctx.client)
  end

  test "exception and corrupt responses fail without retry", ctx do
    for {packet, expected} <- [
          {Modbus.checksum(<<1, 0x83, 2>>), {:modbus_exception, 2}},
          {<<1, 3, 4, 0, 1, 0, 2, 0, 0>>, :modbus_response}
        ] do
      task = Task.async(fn -> Serial.run(ctx.client, :modbus_read, @request) end)
      assert read_bytes(ctx.peer, 8) == Modbus.request(@request)
      :ok = UART.write(ctx.peer, packet)
      assert {:error, ^expected} = Task.await(task, 3_000)
      assert {:ok, ""} = UART.read(ctx.peer, 100)
      assert_released(ctx.client)
    end
  end

  test "silent device times out after one request and sends no retries", ctx do
    task = Task.async(fn -> Serial.run(ctx.client, :modbus_read, @request) end)
    assert read_bytes(ctx.peer, 8) == Modbus.request(@request)
    assert {:error, :modbus_timeout} = Task.await(task, 3_000)
    assert {:ok, ""} = UART.read(ctx.peer, 100)
    assert_released(ctx.client)
  end

  test "passive capture is capped at 4096 bytes, transmits nothing and releases the UART", ctx do
    task = Task.async(fn -> Serial.run(ctx.client, :capture, %{}) end)
    # Do not use UART.configuration/find_pids as a barrier: passive read blocks its GenServer.
    for _ <- 1..20 do
      :ok = UART.write(ctx.peer, :binary.copy(<<42>>, 512))
      Process.sleep(10)
    end

    assert {:ok, %{bytes: 4_096, hex: hex}} = Task.await(task, 6_000)
    assert byte_size(hex) == 8_192
    assert {:ok, ""} = UART.read(ctx.peer, 100)
    assert_released(ctx.client)
  end

  test "a silent capture is bounded by five seconds and has no output", ctx do
    started = System.monotonic_time(:millisecond)
    assert {:ok, %{bytes: 0, hex: ""}} = Serial.run(ctx.client, :capture, %{})
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed in 4_900..6_000
    assert {:ok, ""} = UART.read(ctx.peer, 100)
    assert_released(ctx.client)
  end

  test "existing serial traffic prevents a Modbus request", ctx do
    writer =
      Task.async(fn ->
        for _ <- 1..150 do
          :ok = UART.write(ctx.peer, <<99>>)
          Process.sleep(2)
        end
      end)

    assert {:error, :serial_busy} = Serial.run(ctx.client, :modbus_read, @request)
    Task.await(writer)
    assert {:ok, ""} = UART.read(ctx.peer, 100)
    assert_released(ctx.client)
  end

  test "killing an operation closes its linked UART process", ctx do
    {pid, monitor} = spawn_monitor(fn -> Serial.run(ctx.client, :capture, %{}) end)
    uart = linked_uart(pid, 100)
    uart_monitor = Process.monitor(uart)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    assert_receive {:DOWN, ^uart_monitor, :process, ^uart, _}
    assert_released(ctx.client)
  end

  defp read_bytes(uart, expected, data \\ <<>>) do
    if byte_size(data) >= expected do
      data
    else
      assert {:ok, chunk} = UART.read(uart, 2_000)
      refute chunk == ""
      read_bytes(uart, expected, data <> chunk)
    end
  end

  defp assert_released(path) do
    {:ok, uart} = UART.start_link()
    assert :ok = UART.open(uart, path, active: false)
    UART.stop(uart)
  end

  defp wait_path(path, remaining) when remaining > 0 do
    if File.exists?(path),
      do: :ok,
      else:
        (
          Process.sleep(10)
          wait_path(path, remaining - 1)
        )
  end

  defp wait_path(_, 0), do: flunk("PTY relay did not start")

  defp linked_uart(worker, remaining) when remaining > 0 do
    {:links, links} = Process.info(worker, :links)

    case Enum.find(links, &uart_process?/1) do
      nil ->
        Process.sleep(10)
        linked_uart(worker, remaining - 1)

      uart ->
        uart
    end
  end

  defp linked_uart(_, 0), do: flunk("UART was not started")

  defp uart_process?(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} -> dictionary[:"$initial_call"] == {UART, :init, 1}
      _ -> false
    end
  end
end
