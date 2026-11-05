defmodule ModbusPluginTest do
  use ExUnit.Case, async: false
  alias ModbusPlugin.{Config, Connection, Store}

  setup do
    :ok = Application.stop(:modbus_plugin)
    {:ok, _} = Application.ensure_all_started(:modbus_plugin)
    :ok
  end

  defp state(configs), do: %{configs: configs, error: nil, monitors: %{}}
  defp from, do: {self(), make_ref()}

  test "without platform storage the controller stays inspectable and refuses to save" do
    assert %{storage: {:storage_unavailable, :runtime_unavailable}, connections: []} =
             ModbusPlugin.status()

    assert {:error, {:storage_unavailable, :runtime_unavailable}} =
             ModbusPlugin.save("one", client(502))

    assert ModbusPlugin.start("missing") == {:error, :save_first}
    assert ModbusPlugin.health_check() == :ok
  end

  test "a failed save preserves definitions and an uncertain commit blocks further changes" do
    {:ok, configs} = Store.put(%{}, "one", client(502))

    assert {:reply, {:error, :runtime_unavailable}, %{configs: ^configs, error: nil}} =
             ModbusPlugin.handle_call({:save, "two", client(503)}, from(), state(configs))

    blocked = %{state(configs) | error: :commit_unknown}

    for command <- [{:save, "one", client(502)}, {:delete, "one"}] do
      assert {:reply, {:error, :commit_unknown}, ^blocked} =
               ModbusPlugin.handle_call(command, from(), blocked)
    end

    assert {:reply, {:error, :unknown_connection}, _} =
             ModbusPlugin.handle_call({:delete, "nope"}, from(), state(configs))
  end

  test "legacy schemas are refused instead of silently discarding interpretation" do
    for key <- ~w(mappings max_gap) do
      assert {:error, {:unknown_field, ^key}} =
               Config.validate("one", Map.put(client(502), key, []))
    end

    assert {:error, {:invalid_field, "id", "Bad-Id"}} = Config.validate("Bad-Id", client(502))
  end

  test "connection fields and raw range coordinates reject malformed values" do
    for change <- [
          %{"unit" => "0"},
          %{"interval" => "0"},
          %{"host" => "http://example.com"},
          %{"timeout" => "999999"},
          %{"role" => "master"},
          %{"transport" => "udp"},
          %{"ranges" => nil},
          %{"ranges" => [%{"id" => "Bad", "table" => "holding", "address" => 0, "count" => 1}]},
          %{"ranges" => [%{"id" => "x", "table" => "unknown", "address" => 0, "count" => 1}]},
          %{"ranges" => [%{"id" => "x", "table" => "holding", "address" => 65536, "count" => 1}]}
        ] do
      assert {:error, _} = Config.validate("one", Map.merge(client(502), change))
    end

    assert {:error, _} =
             Config.validate("one", %{
               "role" => "server",
               "port" => 502,
               "unit" => 1,
               "timeout" => 100,
               "ranges" => []
             })
  end

  test "without activation membership Start and discovery open no TCP transport" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, {_, port}} = :inet.sockname(listener)
    {:ok, configs} = Store.put(%{}, "client", client(port))
    {:ok, configs} = Store.put(configs, "server", Map.put(client(port), "role", "server"))

    for operation <- [
          {:start, "client"},
          {:start, "server"},
          {:discover, "client", %{"units" => [1]}}
        ] do
      assert {:reply, {:error, :runtime_unavailable}, _} =
               ModbusPlugin.handle_call(operation, from(), state(configs))
    end

    assert {:error, :timeout} = :gen_tcp.accept(listener, 100)
    assert Connection.pid("client") == nil
    assert Connection.pid("server") == nil
    assert DynamicSupervisor.which_children(ModbusPlugin.Connections) == []
  end

  test "empty client ranges are discovery-only and never start polling" do
    {:ok, config} = Config.validate("one", Map.put(client(502), "ranges", []))
    s = state(%{"one" => config})

    assert {:reply, {:error, :no_ranges}, ^s} =
             ModbusPlugin.handle_call({:start, "one"}, from(), s)

    assert {:error, :not_running} = ModbusPlugin.write("one", "block", [1])
    assert {:error, :not_running} = ModbusPlugin.Server.put("one", "block", [1])
  end

  def client(port),
    do: %{
      "role" => "client",
      "transport" => "tcp",
      "host" => "127.0.0.1",
      "port" => port,
      "unit" => 1,
      "interval" => 100,
      "timeout" => 100,
      "ranges" => [%{"id" => "block", "table" => "holding", "address" => 0, "count" => 2}]
    }
end
