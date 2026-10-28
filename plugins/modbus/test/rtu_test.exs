defmodule ModbusPlugin.RTUTest do
  @moduledoc "RTU admission without hardware. Real PTY exchanges run with the platform in the root suite."
  use ExUnit.Case, async: false
  alias ModbusPlugin.{Config, Connection, Store}

  setup do
    :ok = Application.stop(:modbus_plugin)
    {:ok, _} = Application.ensure_all_started(:modbus_plugin)
    :ok
  end

  test "RTU is explicit and never accepts arbitrary device paths or unsupported line settings" do
    assert {:ok, %{transport: "rtu", speed: 9600, parity: :none, stop_bits: 1}} =
             Config.validate("one", params())

    for change <- [
          %{"authorized" => false},
          %{"serial_port" => "/dev/ttyS0"},
          %{"serial_port" => "ttyS0"},
          %{"speed" => 9601},
          %{"parity" => "mark"},
          %{"stop_bits" => 3},
          %{"unit" => 0}
        ] do
      assert {:error, :invalid_configuration} =
               Config.validate("one", Map.merge(params(), change))
    end

    {:ok, configs} = Store.put(%{}, "unassigned", params())
    state = %{configs: configs, error: nil, monitors: %{}}
    from = {self(), make_ref()}

    assert {:reply, {:error, :runtime_unavailable}, ^state} =
             ModbusPlugin.handle_call({:start, "unassigned"}, from, state)

    assert Connection.pid("unassigned") == nil

    assert {:reply, %{connections: [%{state: :stopped} = saved]}, ^state} =
             ModbusPlugin.handle_call(:status, from, state)

    refute Map.has_key?(saved, :serial_path)
  end

  test "an unverified dead RTU worker cannot be restarted, saved, deleted or stopped" do
    {:ok, configs} = Store.put(%{}, "lost", params())
    state = %{configs: configs, error: nil, monitors: %{"lost" => make_ref()}}
    from = {self(), make_ref()}

    for command <- [
          {:start, "lost"},
          {:save, "lost", params()},
          {:delete, "lost"},
          {:stop, "lost"}
        ] do
      assert {:reply, {:error, :connection_cleanup_required}, ^state} =
               ModbusPlugin.handle_call(command, from, state)
    end

    assert {:reply, %{connections: [%{state: :cleanup_required} = public]}, ^state} =
             ModbusPlugin.handle_call(:status, from, state)

    refute Map.has_key?(public, :serial_monitor)
  end

  test "a retained serial marker keeps the port exclusive for other definitions" do
    {:ok, configs} = Store.put(%{}, "lost", params())
    {:ok, configs} = Store.put(configs, "second", params())
    {:ok, configs} = Store.put(configs, "other", Map.put(params(), "serial_port", "ttyS4"))
    state = %{configs: configs, error: nil, monitors: %{"lost" => make_ref()}}
    from = {self(), make_ref()}

    assert {:reply, {:error, :serial_port_in_use}, ^state} =
             ModbusPlugin.handle_call({:start, "second"}, from, state)

    # ttyS4 is free, so admission proceeds to assignment, which no host provides.
    assert {:reply, {:error, :runtime_unavailable}, ^state} =
             ModbusPlugin.handle_call({:start, "other"}, from, state)
  end

  defp params,
    do: %{
      "role" => "client",
      "transport" => "rtu",
      "serial_port" => "ttyS3",
      "authorized" => true,
      "speed" => 9600,
      "parity" => "none",
      "stop_bits" => 1,
      "unit" => 1,
      "interval" => 500,
      "timeout" => 200,
      "mappings" => [
        %{"id" => "holding0", "table" => "holding", "address" => 0, "direction" => "input"}
      ]
    }
end
