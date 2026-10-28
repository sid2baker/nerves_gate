defmodule Scenarios.Cases.Plugins do
  @moduledoc false
  import ExUnit.Assertions
  alias Scenarios.{Device, ManagedPlugin}

  def spec do
    %{
      name: "Bundled plugins: no-SD activation, UI cleanup and real Modbus TCP",
      fresh_disk: true,
      requires: %{device: [], fixture: [:qemu]}
    }
  end

  def run(%{device: vm}) do
    Device.await(vm, "firmware plugins discovered without commissioned SD", fn _ ->
      state = Device.rpc(vm, :sys, :get_state, [NervesGate.Plugins])
      state.restored? and state.job == nil and state.blocked == nil
    end)

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
      assert Device.rpc(vm, ModbusPlugin, :status) == []

      assert {:error, :firmware_owned_plugin} =
               ManagedPlugin.plugins(vm, :uninstall, [:modbus_plugin])

      response = Req.get!(Scenarios.Qemu.ui_url(vm) <> "/plugins", retry: false)
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

  defp modbus(vm) do
    assert :ok = ManagedPlugin.plugins(vm, :start, [:modbus_plugin])

    {:ok, memory} =
      Device.rpc(vm, DynamicSupervisor, :start_child, [
        ManagedFixture.Clients,
        {Modbus.Memory, [holding_registers: 100]}
      ])

    {:ok, server} =
      Device.rpc(vm, DynamicSupervisor, :start_child, [
        ManagedFixture.Clients,
        {Modbus.Server, [port: 0, handler: {Modbus.Memory, memory}]}
      ])

    try do
      :ok = Device.rpc(vm, Modbus.Memory, :put, [memory, :holding_register, 10, [42, 43]])
      port = Device.rpc(vm, Modbus.Server, :port, [server])

      params = %{
        "host" => "127.0.0.1",
        "port" => port,
        "unit" => 1,
        "table" => "holding",
        "address" => 10,
        "count" => 2,
        "interval" => 100,
        "timeout" => 1000
      }

      assert :ok = Device.rpc(vm, ModbusPlugin, :configure, ["peer", params])
      assert [%{state: :disconnected}] = Device.rpc(vm, ModbusPlugin, :status)
      assert :ok = Device.rpc(vm, ModbusPlugin, :connect, ["peer"])

      Device.await(vm, "yamodbus returns real TCP register values", fn _ ->
        match?([%{values: [42, 43], error: nil}], Device.rpc(vm, ModbusPlugin, :status))
      end)

      assert :ok = Device.rpc(vm, ModbusPlugin, :disconnect, ["peer"])
    after
      assert :ok =
               Device.rpc(vm, DynamicSupervisor, :terminate_child, [
                 ManagedFixture.Clients,
                 server
               ])

      assert :ok =
               Device.rpc(vm, DynamicSupervisor, :terminate_child, [
                 ManagedFixture.Clients,
                 memory
               ])

      assert :ok = ManagedPlugin.plugins(vm, :stop, [:modbus_plugin])
    end

    assert Device.rpc(vm, :code, :is_loaded, [Modbus.Client]) == false
  end
end
