defmodule Scenarios.Cases.Plugins do
  @moduledoc false
  import ExUnit.Assertions
  alias Scenarios.{Device, ManagedApp}

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
    {:ok, plugins} = ManagedApp.apps(vm, :list, [])
    assert Enum.map(plugins, & &1.app) == ["modbus_plugin", "tailnet_subrouter"]
    assert Enum.all?(plugins, &(&1.bundled? and not &1.enabled and not &1.running?))

    try do
      assert :ok = ManagedApp.apps(vm, :start, [:tailnet_subrouter])
      assert Device.rpc(vm, TailnetSubrouter, :status) == %{state: :disabled}
      assert :ok = ManagedApp.apps(vm, :start, [:modbus_plugin])
      assert Device.rpc(vm, ModbusPlugin, :status) == []
      assert {:error, :firmware_owned_plugin} = ManagedApp.apps(vm, :uninstall, [:modbus_plugin])
      response = Req.get!(Scenarios.Qemu.ui_url(vm) <> "/plugins", retry: false)
      assert response.status == 200
      assert response.body =~ "/plugins/tailnet_subrouter"
      assert response.body =~ "/plugins/modbus_plugin"
    after
      assert :ok = ManagedApp.apps(vm, :stop, [:tailnet_subrouter])
      assert :ok = ManagedApp.apps(vm, :stop, [:modbus_plugin])
    end

    ManagedApp.with_app(vm, fn _main ->
      assert :ok = ManagedApp.apps(vm, :start, [:tailnet_subrouter])
      client = ManagedApp.client(vm)

      assert {:ok, TailnetSubrouter.UI, _} =
               ManagedApp.call(vm, client, NervesGate.Plugins, :mount_ui, ["tailnet_subrouter"])

      assert :ok = ManagedApp.apps(vm, :stop, [:tailnet_subrouter])
      refute Device.rpc(vm, :erlang, :is_process_alive, [client])
      assert Device.rpc(vm, :code, :is_loaded, [TailnetSubrouter.UI]) == false
      modbus(vm)
    end)
  end

  defp modbus(vm) do
    assert :ok = ManagedApp.apps(vm, :start, [:modbus_plugin])

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

      assert :ok = ManagedApp.apps(vm, :stop, [:modbus_plugin])
    end

    assert Device.rpc(vm, :code, :is_loaded, [Modbus.Client]) == false
  end
end
