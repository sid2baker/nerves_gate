defmodule ModbusPluginTest do
  use ExUnit.Case, async: false
  alias ModbusPlugin.{Config, Connection}

  setup do
    # Restart only this test project's application, never gateway/bench services.
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

  test "a failed save keeps the previous definitions; an uncertain commit blocks saving" do
    {:ok, configs} = ModbusPlugin.Store.put(%{}, "one", client(502))

    # The host SDK has no runtime, so the real persist call fails before any write.
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

  test "definitions are bounded and validated" do
    for change <- [
          %{"unit" => "0"},
          %{"interval" => "0"},
          %{"host" => "http://example.com"},
          %{"timeout" => "999999"},
          %{"role" => "master"},
          %{"mappings" => []},
          %{"mappings" => [%{"id" => "Bad", "table" => "holding", "address" => 0}]},
          %{"mappings" => [%{"id" => "x", "table" => "input", "address" => 0}]},
          %{"mappings" => [%{"id" => "x", "table" => "holding", "address" => 65536}]},
          %{
            "mappings" => [
              %{"id" => "x", "table" => "holding", "address" => 0},
              %{"id" => "x", "table" => "holding", "address" => 1}
            ]
          },
          %{
            "mappings" => [
              %{"id" => "x", "table" => "coil", "address" => 0, "direction" => "input"},
              %{
                "id" => "y",
                "table" => "holding",
                "address" => 0,
                "direction" => "output",
                "feedback" => "x"
              }
            ]
          }
        ] do
      assert {:error, :invalid_configuration} =
               Config.validate("one", Map.merge(client(502), change))
    end

    assert {:error, :invalid_configuration} = Config.validate("Bad-Id", client(502))

    assert {:error, :invalid_configuration} =
             Config.validate(
               "s",
               Map.put(server(502), "mappings", [
                 %{"id" => "c", "table" => "coil", "address" => 0, "initial" => 2}
               ])
             )
  end

  test "without the platform runtime, Start fails closed and opens no transport" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {_, port}} = :inet.sockname(listener)
    {:ok, configs} = ModbusPlugin.Store.put(%{}, "client", client(port))
    {:ok, configs} = ModbusPlugin.Store.put(configs, "server", server(port + 1))

    assert {:reply,
            {:error, {:start_failed, {:registration_failed, "holding0", :runtime_unavailable}}},
            _} =
             ModbusPlugin.handle_call({:start, "client"}, from(), state(configs))

    assert {:error, :timeout} = :gen_tcp.accept(listener, 200)
    assert Connection.pid("client") == nil
    :gen_tcp.close(listener)

    assert {:reply, {:error, {:start_failed, {:registration_failed, _, :runtime_unavailable}}}, _} =
             ModbusPlugin.handle_call({:start, "server"}, from(), state(configs))

    assert {:ok, free} = :gen_tcp.listen(port + 1, [:binary, ip: {127, 0, 0, 1}, reuseaddr: true])
    :gen_tcp.close(free)
    assert DynamicSupervisor.which_children(ModbusPlugin.Connections) == []
  end

  test "a stopped plugin leaves no runtime and the manual writer holds no claims" do
    assert ModbusPlugin.Command.claims() == []
    assert {:error, :not_claimed} = ModbusPlugin.Command.set("modbus_plugin.x.y", 1)
    assert {:error, :runtime_unavailable} = ModbusPlugin.Command.claim("modbus_plugin.x.y")
    assert {:error, :not_running} = ModbusPlugin.Server.put("x", "y", 1)
    :ok = Application.stop(:modbus_plugin)
    refute Process.whereis(ModbusPlugin)
    refute Process.whereis(ModbusPlugin.Command)
    {:ok, _} = Application.ensure_all_started(:modbus_plugin)
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
      "mappings" => [
        %{"id" => "holding0", "table" => "holding", "address" => 0, "direction" => "input"},
        %{
          "id" => "holding0_set",
          "table" => "holding",
          "address" => 0,
          "direction" => "output",
          "feedback" => "holding0"
        },
        %{"id" => "coil0", "table" => "coil", "address" => 0, "direction" => "input"},
        %{"id" => "coil0_set", "table" => "coil", "address" => 0, "direction" => "output"}
      ]
    }

  def server(port),
    do: %{
      "role" => "server",
      "transport" => "tcp",
      "port" => port,
      "unit" => 1,
      "timeout" => 1000,
      "mappings" => [
        %{"id" => "holding0", "table" => "holding", "address" => 0, "initial" => 7},
        %{"id" => "coil0", "table" => "coil", "address" => 0, "initial" => true}
      ]
    }
end
