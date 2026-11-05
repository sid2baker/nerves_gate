defmodule ModbusPlugin.RawDataTest do
  use ExUnit.Case, async: false
  alias ModbusPlugin.{Config, Connection, Protocol, Server, Store}

  defp params(ranges, extra \\ %{}),
    do:
      Map.merge(
        %{
          "role" => "client",
          "host" => "127.0.0.1",
          "port" => 502,
          "unit" => 1,
          "interval" => 100,
          "timeout" => 100,
          "ranges" => ranges
        },
        extra
      )

  defp block(extra \\ %{}),
    do: Map.merge(%{"id" => "raw", "table" => "holding", "address" => 0, "count" => 2}, extra)

  test "four raw tables normalize and restore exactly without interpretation fields" do
    for table <- Protocol.tables() do
      {:ok, config} = Config.validate("one", params([block(%{"table" => to_string(table)})]))
      assert Config.validate("one", Config.params(config)) == {:ok, config}
      assert Store.valid?(%{"one" => config})
      [range] = config.ranges
      assert Protocol.read(range) == {Protocol.function(table), 0, 2}

      assert Protocol.valid_values?(
               range,
               if(Protocol.bits?(table), do: [true, false], else: [65535, 0])
             )
    end

    for key <- ~w(type scale unit word_order bit length feedback access direction) do
      assert {:error, {:invalid_range, "raw", {:unknown_field, ^key}}} =
               Config.validate("one", params([Map.put(block(), key, 1)]))
    end
  end

  test "bounds, overlap, writable tables and wire limits are checked before use" do
    for range <- [
          block(%{"count" => 0}),
          block(%{"count" => 126}),
          block(%{"address" => 65535}),
          block(%{"writable" => true, "count" => 124}),
          block(%{"table" => "input", "writable" => true}),
          block(%{"table" => "coil", "writable" => true, "count" => 1969})
        ] do
      assert {:error, {:invalid_range, "raw", _}} = Config.validate("one", params([range]))
    end

    assert {:error, {:invalid_range, "other", :overlap}} =
             Config.validate("one", params([block(), block(%{"id" => "other", "address" => 1})]))

    assert {:error, {:invalid_range, "raw", :duplicate_id}} =
             Config.validate("one", params([block(), block(%{"address" => 10})]))

    assert {:error, {:invalid_range, "raw", _}} =
             Config.validate(
               "one",
               params([block(%{"initial" => [-1, 0]})], %{"role" => "server"})
             )

    assert {:error, {:invalid_range, "raw", _}} =
             Config.validate(
               "one",
               params([block(%{"table" => "coil", "initial" => [1, 0]})], %{"role" => "server"})
             )

    assert {:ok, _} = Config.validate("one", params([block(%{"count" => 125})]))

    assert {:ok, _} =
             Config.validate("one", params([block(%{"table" => "coil", "count" => 2000})]))

    refute Protocol.valid_values?(%{count: 2, table: :holding}, [-1, 0])
    refute Protocol.valid_values?(%{count: 2, table: :holding}, [1.0, 0])
    refute Protocol.valid_values?(%{count: 2, table: :holding}, [1])

    assert Protocol.write(%{table: :holding, address: 10}, [65535, 0]) ==
             {:write_multiple_registers, 10, [65535, 0]}

    assert Protocol.write(%{table: :coil, address: 10}, [true, false]) ==
             {:write_multiple_coils, 10, [true, false]}
  end

  test "real TCP polling keeps grouped raw values and explicit writes use one FC16" do
    {:ok, server_config} =
      Config.validate(
        "rawserver",
        params(
          [
            block(%{"initial" => [65535, 65436]}),
            block(%{"id" => "bits", "table" => "discrete", "initial" => [true, false]}),
            block(%{"id" => "coils", "table" => "coil", "initial" => [false, true]}),
            block(%{"id" => "input", "table" => "input", "initial" => [32768, 0]})
          ],
          %{"role" => "server"}
        )
      )

    server = start_supervised!({Server, %{server_config | port: 0}})
    %{server: transport} = :sys.get_state(server)

    ranges = [
      block(%{"writable" => true}),
      block(%{"id" => "bits", "table" => "discrete"}),
      block(%{"id" => "coils", "table" => "coil", "writable" => true}),
      block(%{"id" => "input", "table" => "input"})
    ]

    {:ok, config} =
      Config.validate("rawclient", params(ranges, %{"port" => Modbus.Server.port(transport)}))

    client = start_supervised!({Connection, config})

    await(fn ->
      match?(
        %{observations: %{"input" => %{values: [32768, 0], quality: :good}}},
        GenServer.call(client, :status)
      )
    end)

    assert %{
             observations: %{
               "raw" => %{values: [65535, 65436]},
               "bits" => %{values: [true, false]}
             }
           } = GenServer.call(client, :status)

    assert :ok = ModbusPlugin.write("rawclient", "raw", [0, 42])
    assert %{values: %{"raw" => [0, 42]}} = GenServer.call(server, :status)

    await(fn ->
      match?(
        %{observations: %{"raw" => %{values: [0, 42], quality: :good}}},
        GenServer.call(client, :status)
      )
    end)

    assert :ok = ModbusPlugin.write("rawclient", "coils", [true, false])
    assert %{values: %{"coils" => [true, false]}} = GenServer.call(server, :status)

    await(fn ->
      match?(
        %{observations: %{"coils" => %{values: [true, false], quality: :good}}},
        GenServer.call(client, :status)
      )
    end)

    assert {:error, :read_only} = ModbusPlugin.write("rawclient", "input", [0, 1])
    assert {:error, :invalid_raw_values} = ModbusPlugin.write("rawclient", "raw", [1.2, 3])
    assert :ok = stop_supervised(Server)

    await(fn ->
      match?(
        %{observations: %{"raw" => %{values: nil, quality: :unknown}}},
        GenServer.call(client, :status)
      )
    end)
  end

  test "a timed-out write is unknown, never retried, and concurrent writes are refused" do
    owner = self()

    server =
      start_supervised!(
        {Modbus.Server,
         port: 0,
         handler: fn
           _, {:read_holding_registers, _, _} ->
             {:ok, [0, 0]}

           _, {:write_multiple_registers, _, _} = request ->
             send(owner, {:write, request})
             Process.sleep(250)
             :ok
         end}
      )

    {:ok, config} =
      Config.validate(
        "uncertain",
        params([block(%{"writable" => true})], %{"port" => Modbus.Server.port(server)})
      )

    start_supervised!({Connection, config})
    task = Task.async(fn -> ModbusPlugin.write("uncertain", "raw", [1, 2]) end)
    assert_receive {:write, {:write_multiple_registers, 0, [1, 2]}}
    assert {:error, :busy} = ModbusPlugin.write("uncertain", "raw", [3, 4])
    assert Task.await(task) == {:error, :outcome_unknown}
    refute_receive {:write, _}, 400
  end

  test "only one write may wait behind an in-flight read" do
    owner = self()
    flag = :atomics.new(1, [])

    server =
      start_supervised!(
        {Modbus.Server,
         port: 0,
         handler: fn
           _, {:read_holding_registers, _, _} ->
             if :atomics.exchange(flag, 1, 1) == 0 do
               send(owner, {:reading, self()})

               receive do
                 :continue -> :ok
               after
                 1500 -> :ok
               end
             end

             {:ok, [0, 0]}

           _, {:write_multiple_registers, _, values} ->
             send(owner, {:written, values})
             :ok
         end}
      )

    {:ok, config} =
      Config.validate(
        "queued",
        params([block(%{"writable" => true})], %{
          "port" => Modbus.Server.port(server),
          "timeout" => 1000
        })
      )

    client = start_supervised!({Connection, config})
    assert_receive {:reading, handler}
    task = Task.async(fn -> ModbusPlugin.write("queued", "raw", [1, 2]) end)
    await(fn -> Enum.any?(:sys.get_state(client).queue, &match?({{:write, _, _}, _}, &1)) end)
    assert {:error, :busy} = ModbusPlugin.write("queued", "raw", [3, 4])
    send(handler, :continue)
    assert Task.await(task) == :ok
    assert_receive {:written, [1, 2]}
    refute_receive {:written, _}, 150
  end

  test "server raw writes refuse unmapped spans atomically and local puts accept input tables" do
    {:ok, config} = Config.validate("one", params([block()], %{"role" => "server"}))
    state = %{config: config, map: %{{:holding, 0} => 0, {:holding, 1} => 0}}

    assert {:reply, {:error, {:exception, :illegal_data_address}}, ^state} =
             Server.handle_call({:request, 1, {:write_multiple_registers, 1, [1, 2]}}, nil, state)

    assert {:reply, {:error, {:exception, :illegal_data_value}}, ^state} =
             Server.handle_call(
               {:request, 1, {:write_multiple_registers, 0, [-1, 2]}},
               nil,
               state
             )

    assert {:reply, {:error, {:exception, :gateway_path_unavailable}}, ^state} =
             Server.handle_call({:request, 2, {:read_holding_registers, 0, 2}}, nil, state)

    input = %{hd(config.ranges) | table: :input}
    state = %{config: %{config | ranges: [input]}, map: %{{:input, 0} => 0, {:input, 1} => 0}}
    assert {:reply, :ok, next} = Server.handle_call({:put, "raw", [65535, 1]}, nil, state)
    assert next.map == %{{:input, 0} => 65535, {:input, 1} => 1}
  end

  defp await(fun, attempts \\ 200)
  defp await(_, 0), do: flunk("raw observation did not arrive")

  defp await(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          await(fun, attempts - 1)
        )
  end
end
