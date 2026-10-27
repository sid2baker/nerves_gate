defmodule ModbusPluginTest do
  use ExUnit.Case, async: false
  alias ModbusPlugin.{Config, Connection}

  setup do
    # Restart only this test project's application, never gateway/bench services.
    :ok = Application.stop(:modbus_plugin)
    {:ok, _} = Application.ensure_all_started(:modbus_plugin)
    :ok
  end

  test "startup and configuration never connect; input is bounded" do
    assert ModbusPlugin.status() == []
    assert ModbusPlugin.connect("missing") == {:error, :configure_first}
    assert ModbusPlugin.configure("one", params(502)) == :ok
    assert [%{state: :disconnected}] = ModbusPlugin.status()
    assert Connection.pid("one") == nil

    for change <- [
          %{"count" => "126"},
          %{"address" => "65535"},
          %{"table" => "write"},
          %{"unit" => "0"},
          %{"interval" => "0"},
          %{"host" => "http://example.com"},
          %{"timeout" => "999999"}
        ] do
      assert {:error, :invalid_configuration} =
               Config.validate("one", Map.merge(params(502), change))
    end
  end

  test "real yamodbus TCP reads FC3 and FC4 and disconnect drains client and polling" do
    {port, _listener} = peer(:reply)
    assert :ok = ModbusPlugin.configure("one", params(port))
    refute_receive {:request, _, _, _, _}, 30
    assert :ok = ModbusPlugin.connect("one")
    assert_receive {:request, 1, 3, 10, 2}, 2_000
    assert [%{values: [10, 11], error: nil}] = await_values([10, 11])
    assert {:error, :disconnect_first} = ModbusPlugin.configure("one", params(port))
    pid = Connection.pid("one")
    client = :sys.get_state(pid).client
    assert :ok = ModbusPlugin.disconnect("one")
    refute Process.alive?(pid)
    refute Process.alive?(client)
    assert [%{state: :disconnected}] = ModbusPlugin.status()
    assert :ok = ModbusPlugin.configure("one", Map.put(params(port), "table", "input"))
    assert :ok = ModbusPlugin.connect("one")
    assert_receive {:request, 1, 4, 10, 2}, 2_000
    assert [%{values: [10, 11]}] = await_values([10, 11])
  end

  test "timeouts are visible and stopped plugins leave no connections or configuration" do
    {port, _} = peer(:silence)
    :ok = ModbusPlugin.configure("one", params(port))
    :ok = ModbusPlugin.connect("one")
    assert_receive {:request, 1, 3, 10, 2}, 2_000
    assert [%{state: :read_failed, error: :timeout, values: nil}] = await_error()
    pid = Connection.pid("one")
    client = :sys.get_state(pid).client
    :ok = Application.stop(:modbus_plugin)
    refute Process.alive?(pid)
    refute Process.alive?(client)
    {:ok, _} = Application.ensure_all_started(:modbus_plugin)
    assert ModbusPlugin.status() == []
  end

  test "a stopped library client terminates its worker instead of leaving a stuck poll" do
    {port, _} = peer(:reply)
    :ok = ModbusPlugin.configure("one", params(port))
    :ok = ModbusPlugin.connect("one")
    pid = Connection.pid("one")
    client = :sys.get_state(pid).client
    ref = Process.monitor(pid)
    :ok = Modbus.Client.stop(client)
    assert_receive {:DOWN, ^ref, :process, ^pid, {:client_exit, :normal}}
    assert [%{state: :disconnected}] = await_disconnected()
  end

  test "unexpected connection death is not automatically restarted" do
    {port, _} = peer(:reply)
    :ok = ModbusPlugin.configure("one", params(port))
    :ok = ModbusPlugin.connect("one")
    pid = Connection.pid("one")
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    assert [%{state: :disconnected}] = await_disconnected()
  end

  defp params(port),
    do: %{
      "host" => "127.0.0.1",
      "port" => port,
      "unit" => 1,
      "table" => "holding",
      "address" => 10,
      "count" => 2,
      "interval" => 100,
      "timeout" => 100
    }

  # Registry observes process death independently of the test's monitor.
  defp await_disconnected(attempts \\ 100)
  defp await_disconnected(0), do: flunk("Connection registry did not drain")

  defp await_disconnected(attempts) do
    case ModbusPlugin.status() do
      [%{state: :disconnected}] = status ->
        status

      _ ->
        Process.sleep(10)
        await_disconnected(attempts - 1)
    end
  end

  defp await_values(expected, attempts \\ 100)
  defp await_values(_, 0), do: flunk("No successful Modbus read")

  defp await_values(expected, attempts) do
    case ModbusPlugin.status() do
      [%{values: ^expected}] = status ->
        status

      _ ->
        Process.sleep(10)
        await_values(expected, attempts - 1)
    end
  end

  defp await_error(attempts \\ 100)
  defp await_error(0), do: flunk("No Modbus timeout reported")

  defp await_error(attempts) do
    case ModbusPlugin.status() do
      [%{error: :timeout}] = status ->
        status

      _ ->
        Process.sleep(10)
        await_error(attempts - 1)
    end
  end

  defp peer(mode) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {_, port}} = :inet.sockname(listener)
    owner = self()
    start_supervised!({Task, fn -> accept(listener, owner, mode) end})
    {port, listener}
  end

  defp accept(listener, owner, mode) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        serve(socket, owner, mode)
        accept(listener, owner, mode)

      _ ->
        :ok
    end
  end

  defp serve(socket, owner, mode) do
    case :gen_tcp.recv(socket, 12, 2_000) do
      {:ok, <<tx::16, 0::16, 6::16, unit, function, address::16, count::16>>} ->
        send(owner, {:request, unit, function, address, count})

        if mode == :reply do
          values = for offset <- 0..(count - 1), into: <<>>, do: <<address + offset::16>>
          pdu = <<function, byte_size(values), values::binary>>

          :ok =
            :gen_tcp.send(socket, <<tx::16, 0::16, byte_size(pdu) + 1::16, unit, pdu::binary>>)
        end

        serve(socket, owner, mode)

      _ ->
        :gen_tcp.close(socket)
    end
  end
end
