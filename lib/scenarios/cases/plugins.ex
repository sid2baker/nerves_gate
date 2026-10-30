defmodule Scenarios.Cases.Plugins do
  @moduledoc false
  import ExUnit.Assertions
  alias Scenarios.{Device, ManagedPlugin}

  def spec do
    %{
      name: "Bundled plugins: no-SD activation, UI cleanup and real Modbus TCP state I/O",
      fresh_disk: true,
      requires: %{device: [], fixture: [:qemu]}
    }
  end

  def run(%{device: vm}) do
    ManagedPlugin.await_idle(vm, "firmware plugins discovered without commissioned SD")

    storage = Device.rpc(vm, NervesGate.Storage, :commissioning)
    refute storage.ready
    {:ok, plugins} = ManagedPlugin.plugins(vm, :list, [])
    assert Enum.map(plugins, & &1.app) == ["modbus_plugin", "tailnet_subrouter"]
    assert Enum.all?(plugins, &(&1.bundled? and not &1.enabled and not &1.running?))

    Device.save(vm, Device.settings("eth0"))

    try do
      assert :ok = ManagedPlugin.plugins(vm, :start, [:tailnet_subrouter])
      assert Device.rpc(vm, TailnetSubrouter, :status) == %{state: :disabled}
      ethernet(vm)
      assert :ok = ManagedPlugin.plugins(vm, :start, [:tailnet_subrouter])
      assert :ok = ManagedPlugin.plugins(vm, :start, [:modbus_plugin])
      # Without SD, saved definitions are blocked, never defaulted or moved to /data.
      assert %{storage: {:storage_unavailable, _}, connections: []} =
               Device.rpc(vm, ModbusPlugin, :status)

      assert {:error, {:storage_unavailable, _}} =
               Device.rpc(vm, ModbusPlugin, :save, ["server1", modbus_server()])

      assert {:error, :firmware_owned_plugin} =
               ManagedPlugin.plugins(vm, :uninstall, [:modbus_plugin])

      response = guest_page(vm, "/plugins")
      assert response.status == 200
      assert response.body =~ "/plugins/tailnet_subrouter"
      assert response.body =~ "/plugins/modbus_plugin"
    after
      assert :ok = ManagedPlugin.plugins(vm, :stop, [:tailnet_subrouter])
      assert :ok = ManagedPlugin.plugins(vm, :stop, [:modbus_plugin])
    end

    ManagedPlugin.with_plugin(vm, fn _main ->
      assert :ok = ManagedPlugin.plugins(vm, :start, [:tailnet_subrouter])
      client = ManagedPlugin.client(vm)

      assert {:ok, TailnetSubrouter.UI, _} =
               ManagedPlugin.call(vm, client, NervesGate.Plugins, :mount_ui, ["tailnet_subrouter"])

      assert :ok = ManagedPlugin.plugins(vm, :stop, [:tailnet_subrouter])
      refute Device.rpc(vm, :erlang, :is_process_alive, [client])
      assert Device.rpc(vm, :code, :is_loaded, [TailnetSubrouter.UI]) == false
      modbus(vm)
    end)
  end

  defp ethernet(vm) do
    assert {:error, "hardware_not_assigned"} =
             Device.rpc(vm, TailnetSubrouter, :configure, ["eth1", "10.44.0.2", 24], 75_000)

    assert {:error, %{code: "hardware_reserved"}} =
             ManagedPlugin.plugins(vm, :assign_port, ["eth0", true, "tailnet_subrouter", true])

    assert :ok =
             ManagedPlugin.plugins(vm, :assign_port, ["eth1", true, "tailnet_subrouter", true])

    assert :ok = ManagedPlugin.plugins(vm, :start, [:tailnet_subrouter])
    assert :ok = Device.rpc(vm, TailnetSubrouter, :configure, ["eth1", "10.44.0.2", 24], 75_000)

    Device.await(vm, "assigned LAN is configured without changing Internet", fn status ->
      status.network.local != nil and status.network.local.phase == :configured and
        NervesGate.Config.role_port(status.network.desired, "internet") == "eth0"
    end)

    assert :ok = Device.rpc(vm, TailnetSubrouter, :disable, [], 75_000)
    changed = Device.settings("eth1")

    assert {:error, %{code: "hardware_assigned"}} =
             Device.rpc(vm, NervesGate.Network, :propose, [changed])

    assert :ok = Device.rpc(vm, TailnetSubrouter, :configure, ["eth1", "10.44.0.2", 24], 75_000)
    assert :ok = ManagedPlugin.plugins(vm, :assign_port, ["eth1", false, nil, true])

    Device.await(vm, "reassignment drains the owning plugin's LAN lease", fn status ->
      status.network.local == nil and
        Enum.any?(status.connections.ports, &(&1.name == "eth1" and &1.addresses == []))
    end)

    {:ok, plugins} = ManagedPlugin.plugins(vm, :list, [])
    refute Enum.find(plugins, &(&1.app == "tailnet_subrouter")).running?
  end

  @modbus_port 15_020
  @server_holding "modbus_plugin.server1.holding0"
  @server_coil "modbus_plugin.server1.coil0"
  @client_holding "modbus_plugin.client1.holding0"
  @holding_setter "modbus_plugin.client1.holding0_set"
  @coil_setter "modbus_plugin.client1.coil0_set"

  # Saved server + client in one plugin over real loopback TCP and the real I/O domain:
  # desired -> client write -> server map -> client poll -> linked feedback.
  defp modbus(vm) do
    assert :ok = ManagedPlugin.plugins(vm, :start, [:modbus_plugin])

    try do
      assert %{storage: nil, connections: []} = Device.rpc(vm, ModbusPlugin, :status)
      assert :ok = Device.rpc(vm, ModbusPlugin, :save, ["server1", modbus_server()])
      assert :ok = Device.rpc(vm, ModbusPlugin, :save, ["client1", modbus_client()])

      # Platform configuration storage keys the term by the running plugin version.
      config = "/mnt/plugins/data/modbus_plugin/.nerves_gate/config/0.4.0.term"

      assert %{"client1" => _, "server1" => _} =
               config |> then(&Device.rpc(vm, File, :read!, [&1])) |> :erlang.binary_to_term()

      # Save registers nothing: endpoints appear only once a runtime starts.
      assert {:error, :unknown_input} = io(vm, :input, [@server_holding])
      assert :ok = Device.rpc(vm, ModbusPlugin, :start, ["server1"])
      assert :ok = Device.rpc(vm, ModbusPlugin, :start, ["client1"])
      await_value(vm, "server publishes its initial map", @server_holding, 7)
      await_value(vm, "client polls the server map", @client_holding, 7)
      await_value(vm, "client polls the server coil", "modbus_plugin.client1.coil0", true)

      # A claim alone sets no desire and causes no write.
      assert :ok = command(vm, :claim, [@holding_setter])
      assert {:ok, %{claimed?: true, desired: nil}} = io(vm, :output, [@holding_setter])
      assert :ok = command(vm, :set, [@holding_setter, 42])
      await_value(vm, "desired register reaches the server map", @server_holding, 42)

      Device.await(vm, "readback evidence confirms the applied register", fn _ ->
        match?(
          {:ok,
           %{
             desired: 42,
             status: %{
               state: :confirmed,
               applied: :applied,
               evidence: [%{input: @client_holding, role: :readback, state: :confirmed}]
             }
           }},
          io(vm, :output, [@holding_setter])
        )
      end)

      assert :ok = command(vm, :claim, [@coil_setter])
      assert :ok = command(vm, :set, [@coil_setter, false])
      await_value(vm, "desired coil reaches the server map", @server_coil, false)

      for value <- 1..5, do: assert(:ok = command(vm, :set, [@holding_setter, value]))
      await_value(vm, "rapid desires converge on the latest", @server_holding, 5)

      # A local server change contradicting a held desire is reconciled back.
      assert :ok = Device.rpc(vm, ModbusPlugin.Server, :put, ["server1", "holding0", 99])
      await_value(vm, "client restores held desire after feedback mismatch", @server_holding, 5)

      Device.await(vm, "restored register is confirmed again", fn _ ->
        match?(
          {:ok, %{desired: 5, status: %{state: :confirmed}}},
          io(vm, :output, [@holding_setter])
        )
      end)

      # Release drops the desire without writing; later local changes stand.
      assert :ok = command(vm, :release, [@holding_setter])
      assert {:ok, %{claimed?: false, desired: nil}} = io(vm, :output, [@holding_setter])
      assert :ok = Device.rpc(vm, ModbusPlugin.Server, :put, ["server1", "holding0", 99])
      await_value(vm, "client observes the local server change", @client_holding, 99)
      Process.sleep(1_000)
      assert {:ok, %{reading: %{value: 99}}} = io(vm, :input, [@server_holding])
      manual(vm)

      # Losing the server is reported as unknown/invalid, never a stale success.
      assert :ok = Device.rpc(vm, ModbusPlugin, :stop, ["server1"])
      assert {:ok, %{available?: false}} = io(vm, :input, [@server_holding])

      Device.await(vm, "client reports lost server without fabricated values", fn _ ->
        match?(
          {:ok, %{reading: %{value: nil, quality: quality}}} when quality != :good,
          io(vm, :input, [@client_holding])
        )
      end)

      # Stopping the client clears its binding, claims and desire, not definitions.
      assert :ok = Device.rpc(vm, ModbusPlugin, :stop, ["client1"])

      assert {:ok, %{available?: false, claimed?: false, desired: nil}} =
               io(vm, :output, [@coil_setter])

      assert :ok = Device.rpc(vm, ModbusPlugin, :start, ["client1"])

      assert {:error, :stop_first} =
               Device.rpc(vm, ModbusPlugin, :save, ["client1", modbus_client()])

      assert :ok = Device.rpc(vm, ModbusPlugin, :stop, ["client1"])
    after
      assert :ok = ManagedPlugin.plugins(vm, :stop, [:modbus_plugin])
    end

    assert Device.rpc(vm, :code, :is_loaded, [Modbus.Client]) == false
    definitions = Device.rpc(vm, NervesGate.IO, :definitions)
    assert Map.has_key?(definitions, @holding_setter)

    # Saved definitions return after restart; nothing starts or communicates.
    assert :ok = ManagedPlugin.plugins(vm, :start, [:modbus_plugin])

    try do
      assert %{
               storage: nil,
               connections: [%{id: "client1", state: :stopped}, %{id: "server1", state: :stopped}]
             } =
               Device.rpc(vm, ModbusPlugin, :status)

      assert {:ok, %{available?: false, reading: nil}} = io(vm, :input, [@server_holding])
      assert :ok = Device.rpc(vm, ModbusPlugin, :delete, ["client1"])
      assert :ok = Device.rpc(vm, ModbusPlugin, :delete, ["server1"])
    after
      assert :ok = ManagedPlugin.plugins(vm, :stop, [:modbus_plugin])
    end
  end

  # The gateway I/O page and its manual writer against the plugin's own writer.
  defp manual(vm) do
    page = io_page(vm)
    assert page =~ ~s(id="io-input-modbus_plugin-server1-holding0")
    assert page =~ ~s(id="io-claim-modbus_plugin-client1-holding0_set")

    assert :ok = manual(vm, :claim, [@holding_setter])
    assert {:error, _} = command(vm, :claim, [@holding_setter])
    assert :ok = manual(vm, :set, [@holding_setter, 11])
    await_value(vm, "manual desire reaches the server map", @server_holding, 11)
    page = io_page(vm)
    assert page =~ "Manual control"
    assert page =~ "Target: 11"
    assert page =~ ~s(id="io-status-modbus_plugin-client1-holding0_set")
    assert :ok = manual(vm, :release, [@holding_setter])
    assert {:ok, %{claimed?: false, desired: nil}} = io(vm, :output, [@holding_setter])
    await_value(vm, "release writes nothing back", @server_holding, 11)
  end

  # Disposable guests are replaced without closing host sockets; a pooled
  # keep-alive connection would fail the next scenario's first request.
  defp guest_page(vm, path),
    do: Req.get!(Scenarios.Qemu.ui_url(vm) <> path, headers: [connection: "close"], retry: false)

  defp io_page(vm) do
    response = guest_page(vm, "/io")
    assert response.status == 200
    response.body
  end

  defp manual(vm, function, args), do: Device.rpc(vm, NervesGate.IO.Manual, function, args)
  defp io(vm, function, args), do: Device.rpc(vm, NervesGate.IO, function, args)
  defp command(vm, function, args), do: Device.rpc(vm, ModbusPlugin.Command, function, args)

  defp await_value(vm, phase, id, value) do
    Device.await(vm, phase, fn _ ->
      match?({:ok, %{reading: %{value: ^value, quality: :good}}}, io(vm, :input, [id]))
    end)
  end

  defp modbus_server do
    %{
      "role" => "server",
      "transport" => "tcp",
      "port" => @modbus_port,
      "unit" => 1,
      "timeout" => 1000,
      "mappings" => [
        %{"id" => "holding0", "table" => "holding", "address" => 0, "initial" => 7},
        %{"id" => "coil0", "table" => "coil", "address" => 0, "initial" => true}
      ]
    }
  end

  defp modbus_client do
    %{
      "role" => "client",
      "transport" => "tcp",
      "host" => "127.0.0.1",
      "port" => @modbus_port,
      "unit" => 1,
      "interval" => 200,
      "timeout" => 500,
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
        %{
          "id" => "coil0_set",
          "table" => "coil",
          "address" => 0,
          "direction" => "output",
          "feedback" => "coil0"
        }
      ]
    }
  end
end
