defmodule ModbusPlugin.DiscoveryTest do
  use ExUnit.Case, async: false
  alias ModbusPlugin.{Config, Discovery, Server}

  test "discovery validates bounded, explicitly selected units and ranges" do
    for change <- [
          %{"units" => []},
          %{"units" => [0]},
          %{"units" => [248]},
          %{"units" => [1, 1]},
          %{"units" => Enum.to_list(1..17)},
          %{"budget" => 1001},
          %{"delay" => -1},
          %{"ranges" => [%{"table" => "input", "address" => 65535, "count" => 2}]},
          %{"ranges" => [%{"table" => "input", "address" => 0, "count" => 4097}]},
          %{
            "ranges" => [
              %{"table" => "holding", "address" => 0, "count" => 3000},
              %{"table" => "input", "address" => 0, "count" => 3000}
            ]
          },
          %{"ranges" => [%{"table" => "write", "address" => 0, "count" => 1}]}
        ] do
      assert {:error, {:invalid_field, _, _}} =
               Discovery.validate(Map.merge(%{"units" => [1]}, change))
    end

    assert {:ok, %{budget: 200, delay: 50}} = Discovery.validate(%{"units" => [1]})
  end

  test "real TCP survey identifies, probes all tables, splits gaps and never sends a write" do
    parent = self()
    config = config()

    server_config = %{config | id: "server", role: :server}

    state = %{config: server_config, map: %{{:input, 0} => 80, {:input, 2} => 42}, values: %{}}

    server =
      start_supervised!(
        {Modbus.Server,
         port: 0,
         handler: fn unit, request ->
           send(parent, {:wire, unit, request, System.monotonic_time(:millisecond)})
           {:reply, result, _} = Server.handle_call({:request, unit, request}, nil, state)
           result
         end}
      )

    {:ok, plan} =
      Discovery.validate(%{
        "units" => [1],
        "ranges" => [%{"table" => "input", "address" => 0, "count" => 3}],
        "delay" => 5
      })

    worker = start_supervised!({Discovery, {%{config | port: Modbus.Server.port(server)}, plan}})
    status = await(worker)
    assert status.error == nil

    assert [%{identification: %{objects: objects}, server_id: id, tables: tables}] =
             status.discovery.units

    assert {0, "Nerves Gate"} in objects
    assert is_binary(id)
    assert tables.input == :ok
    assert tables.holding == {:exception, :illegal_data_address}

    assert Enum.map(status.discovery.evidence, &{&1.address, &1.raw}) == [
             {0, 80},
             {2, 42}
           ]

    assert [%{address: 1, result: {:exception, :illegal_data_address}}] =
             status.discovery.failures

    assert %{client: nil} = :sys.get_state(worker)
    assert GenServer.call(worker, {:write, "x", 99}) == {:error, :discovering}

    requests = wire([])
    assert length(requests) == status.discovery.requests

    assert Enum.all?(requests, fn {_, request, _} ->
             Modbus.PDU.function(request) in [1, 2, 3, 4, 17, 43]
           end)

    times = Enum.map(requests, &elem(&1, 2))
    assert Enum.all?(Enum.zip(times, tl(times)), fn {before, after_} -> after_ - before >= 4 end)
  end

  test "budget ends the survey and closes its transport with pending work visible" do
    memory = start_supervised!({Modbus.Memory, input_registers: 200})
    server = start_supervised!({Modbus.Server, port: 0, handler: {Modbus.Memory, memory}})
    {:ok, plan} = Discovery.validate(%{"units" => [1, 2], "budget" => 1, "delay" => 0})

    worker =
      start_supervised!({Discovery, {%{config() | port: Modbus.Server.port(server)}, plan}})

    status = await(worker)
    assert status.error == :budget_exhausted
    assert status.discovery.requests == 1
    assert status.discovery.remaining > 0
    assert %{client: nil} = :sys.get_state(worker)
  end

  test "evidence truncation on the last batch reports its limit, not successful completion" do
    memory = start_supervised!({Modbus.Memory, input_registers: 2050})
    server = start_supervised!({Modbus.Server, port: 0, handler: {Modbus.Memory, memory}})

    {:ok, plan} =
      Discovery.validate(%{
        "units" => [1, 2],
        "identify" => false,
        "ranges" => [%{"table" => "input", "address" => 0, "count" => 2050}],
        "delay" => 0
      })

    worker =
      start_supervised!({Discovery, {%{config() | port: Modbus.Server.port(server)}, plan}})

    status = await(worker)
    assert status.error == :evidence_limit
    assert status.discovery.remaining == 0
    assert length(status.discovery.evidence) == 4096
    assert %{client: nil} = :sys.get_state(worker)
  end

  test "identification pagination stays budgeted" do
    parent = self()

    server =
      start_supervised!(
        {Modbus.Server,
         port: 0,
         handler: fn
           _, {:read_device_identification, :basic, from} ->
             send(parent, {:page, from})

             {:ok,
              %{
                conformity_level: 1,
                more_follows: from == 0,
                next_object_id:
                  if from == 0 do
                    1
                  else
                    0
                  end,
                objects: [{from, "value"}]
              }}

           _, _ ->
             {:error, {:exception, :illegal_data_address}}
         end}
      )

    {:ok, plan} = Discovery.validate(%{"units" => [1], "delay" => 0})

    worker =
      start_supervised!({Discovery, {%{config() | port: Modbus.Server.port(server)}, plan}})

    status = await(worker)

    assert [%{identification: %{objects: [{0, "value"}, {1, "value"}], more: false}}] =
             status.discovery.units

    assert_receive {:page, 0}
    assert_receive {:page, 1}
  end

  test "controller rejects discovery on servers, missing definitions and unresolved cleanup" do
    {:ok, client} = Config.validate("client", Config.params(config()))
    server = %{config() | id: "server", role: :server}
    state = %{configs: %{"client" => client, "server" => server}, monitors: %{}, error: nil}
    from = {self(), make_ref()}

    assert {:reply, {:error, :client_required}, ^state} =
             ModbusPlugin.handle_call({:discover, "server", %{"units" => [1]}}, from, state)

    assert {:reply, {:error, :save_first}, ^state} =
             ModbusPlugin.handle_call({:discover, "missing", %{"units" => [1]}}, from, state)

    state = put_in(state.monitors["client"], make_ref())

    assert {:reply, {:error, :connection_cleanup_required}, ^state} =
             ModbusPlugin.handle_call({:discover, "client", %{"units" => [1]}}, from, state)
  end

  defp config do
    {:ok, config} =
      Config.validate("survey", %{
        "role" => "client",
        "host" => "127.0.0.1",
        "port" => 502,
        "unit" => 1,
        "interval" => 100,
        "timeout" => 100,
        "ranges" => [%{"id" => "p", "table" => "input", "address" => 0, "count" => 1}]
      })

    config
  end

  defp await(pid, attempts \\ 200)
  defp await(_, 0), do: flunk("discovery did not finish")

  defp await(pid, attempts) do
    case GenServer.call(pid, :status) do
      %{state: :discovered} = status ->
        status

      _ ->
        Process.sleep(10)
        await(pid, attempts - 1)
    end
  end

  defp wire(acc) do
    receive do
      {:wire, unit, request, at} -> wire([{unit, request, at} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
