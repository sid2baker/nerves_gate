defmodule Scenarios.Cases.Plugins do
  @moduledoc false
  import ExUnit.Assertions
  alias Scenarios.{Device, ManagedPlugin}

  def spec do
    %{
      name: "Bundled plugins: no-SD activation, UI cleanup and raw Modbus TCP",
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
      assert [_] = Floki.find(response.body, "a[href='/plugins/tailnet_subrouter']")
      assert [_] = Floki.find(response.body, "a[href='/plugins/modbus_plugin']")
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
             Scenarios.ManagedPlugin.assign(vm, "eth0", true, "tailnet_subrouter")

    assert :ok = ManagedPlugin.assign(vm, "eth1", true, "tailnet_subrouter", true)
    owner = Device.rpc(vm, Process, :whereis, [TailnetSubrouter])
    assert is_pid(owner)

    # A same-owner review does not tear down live plugin processes.
    assert :ok = ManagedPlugin.assign(vm, "eth1", true, "tailnet_subrouter")
    assert Device.rpc(vm, Process, :whereis, [TailnetSubrouter]) == owner

    assert {:ok, stale} =
             ManagedPlugin.plugins(vm, :review_assignment, [
               "eth1",
               true,
               "tailnet_subrouter",
               true
             ])

    assert :ok = ManagedPlugin.assign(vm, "eth1", false, "tailnet_subrouter")

    assert %{ports: %{"eth1" => %{enabled: false, plugin: "tailnet_subrouter"}}} =
             ManagedPlugin.plugins(vm, :hardware, [])

    assert {:error, :review_changed} = ManagedPlugin.plugins(vm, :confirm_assignment, [stale])
    assert :ok = ManagedPlugin.assign(vm, "eth1", true, "tailnet_subrouter", true)
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
    assert :ok = Scenarios.ManagedPlugin.assign(vm, "eth1", false, nil)

    Device.await(vm, "reassignment drains the owning plugin's LAN lease", fn status ->
      status.network.local == nil and
        Enum.any?(status.connections.ports, &(&1.name == "eth1" and &1.addresses == []))
    end)

    {:ok, plugins} = ManagedPlugin.plugins(vm, :list, [])
    refute Enum.find(plugins, &(&1.app == "tailnet_subrouter")).running?
  end

  @modbus_port 15_020
  defp modbus(vm) do
    before = Device.rpc(vm, NervesGate.IO, :definitions)
    assert :ok = ManagedPlugin.plugins(vm, :start, [:modbus_plugin])
    ui_client = ManagedPlugin.client(vm)

    try do
      assert %{storage: nil, connections: []} = Device.rpc(vm, ModbusPlugin, :status)
      assert :ok = Device.rpc(vm, ModbusPlugin, :save, ["server1", modbus_server()])
      assert :ok = Device.rpc(vm, ModbusPlugin, :save, ["client1", modbus_client()])
      version = Device.rpc(vm, Application, :spec, [:modbus_plugin, :vsn]) |> to_string()
      config = "/mnt/plugins/data/modbus_plugin/.nerves_gate/config/#{version}.term"

      assert %{"client1" => _, "server1" => _} =
               config |> then(&Device.rpc(vm, File, :read!, [&1])) |> :erlang.binary_to_term()

      assert :ok = Device.rpc(vm, ModbusPlugin, :start, ["server1"])
      assert :ok = Device.rpc(vm, ModbusPlugin, :start, ["client1"])
      await_raw(vm, "FC03 raw words remain grouped", "holding", [65535, 65436])
      await_raw(vm, "FC04 raw input words", "input", [32768, 0])
      await_raw(vm, "FC01 raw coils", "coil", [true, false])
      await_raw(vm, "FC02 raw discrete inputs", "discrete", [false, true])
      assert Device.rpc(vm, NervesGate.IO, :definitions) == before
      assert :ok = Device.rpc(vm, ModbusPlugin, :write, ["client1", "holding", [0, 42]])
      await_raw(vm, "FC16 writes both words together", "holding", [0, 42])
      assert :ok = Device.rpc(vm, ModbusPlugin, :write, ["client1", "coil", [false, true]])
      await_raw(vm, "FC15 writes raw bits", "coil", [false, true])

      assert {:error, :read_only} =
               Device.rpc(vm, ModbusPlugin, :write, ["client1", "input", [0, 1]])

      assert {:error, :invalid_raw_values} =
               Device.rpc(vm, ModbusPlugin, :write, ["client1", "holding", [-1, 0]])

      assert {:error, :stop_first} =
               Device.rpc(vm, ModbusPlugin, :save, ["client1", modbus_client()])

      assert :ok = Device.rpc(vm, ModbusPlugin, :stop, ["client1"])

      survey = %{
        "units" => [1],
        "ranges" => [%{"table" => "input", "address" => 0, "count" => 2}],
        "delay" => 0
      }

      assert :ok = Device.rpc(vm, ModbusPlugin, :discover, ["client1", survey])

      Device.await(vm, "read-only discovery completes", fn _ ->
        connection(vm, "client1").state == :discovered
      end)

      found = connection(vm, "client1")
      assert found.error == nil
      assert Enum.map(found.discovery.evidence, & &1.raw) == [32768, 0]

      assert {:error, :discovering} =
               Device.rpc(vm, ModbusPlugin, :write, ["client1", "holding", [0, 0]])

      assert :ok = Device.rpc(vm, ModbusPlugin, :stop, ["client1"])
      assert :ok = Device.rpc(vm, ModbusPlugin, :start, ["client1"])
      await_raw(vm, "polling resumes explicitly", "holding", [0, 42])
      assert :ok = Device.rpc(vm, ModbusPlugin, :stop, ["server1"])

      Device.await(vm, "transport loss removes raw values", fn _ ->
        match?(
          %{values: nil, quality: :unknown},
          connection(vm, "client1").observations["holding"]
        )
      end)

      page = guest_page(vm, "/plugins/modbus_plugin")
      assert page.status == 200
      assert page.body |> Floki.find(".ui-help") |> Floki.text() =~ "Connecting to plugin"

      # HTTP deliberately defers loading plugin code. Render the verified
      # component in a tracked guest PID, as the connected host does.
      assert {:ok, ModbusPlugin.UI, _} =
               ManagedPlugin.call(vm, ui_client, NervesGate.Plugins, :mount_ui, ["modbus_plugin"])

      socket = %Phoenix.LiveView.Socket{transport_pid: ui_client, assigns: %{__changed__: %{}}}
      assigns = %{id: "plugin-ui", myself: %Phoenix.LiveComponent.CID{cid: 1}}

      assert {:ok, socket} =
               ManagedPlugin.call(vm, ui_client, ModbusPlugin.UI, :update, [assigns, socket])

      rendered = ManagedPlugin.call(vm, ui_client, ModbusPlugin.UI, :render, [socket.assigns])

      html =
        ManagedPlugin.call(vm, ui_client, Phoenix.HTML.Safe, :to_iodata, [rendered])
        |> IO.iodata_to_binary()

      assert html =~ "Raw ranges"
      refute html =~ "Load Solis"
    after
      assert :ok = ManagedPlugin.plugins(vm, :stop, [:modbus_plugin])
    end

    refute Device.rpc(vm, :erlang, :is_process_alive, [ui_client])
    assert Device.rpc(vm, :code, :is_loaded, [Modbus.Client]) == false
    assert Device.rpc(vm, NervesGate.IO, :definitions) == before
    assert :ok = ManagedPlugin.plugins(vm, :start, [:modbus_plugin])

    try do
      assert %{
               storage: nil,
               connections: [%{id: "client1", state: :stopped}, %{id: "server1", state: :stopped}]
             } = Device.rpc(vm, ModbusPlugin, :status)

      assert :ok = Device.rpc(vm, ModbusPlugin, :delete, ["client1"])
      assert :ok = Device.rpc(vm, ModbusPlugin, :delete, ["server1"])
    after
      assert :ok = ManagedPlugin.plugins(vm, :stop, [:modbus_plugin])
    end
  end

  defp connection(vm, id),
    do: Device.rpc(vm, ModbusPlugin, :status).connections |> Enum.find(&(&1.id == id))

  defp await_raw(vm, phase, id, values) do
    Device.await(vm, phase, fn _ ->
      match?(%{values: ^values, quality: :good}, connection(vm, "client1").observations[id])
    end)
  end

  defp modbus_server do
    %{
      "role" => "server",
      "transport" => "tcp",
      "port" => @modbus_port,
      "unit" => 1,
      "timeout" => 1000,
      "ranges" => [
        %{
          "id" => "holding",
          "table" => "holding",
          "address" => 0,
          "count" => 2,
          "initial" => [65535, 65436]
        },
        %{
          "id" => "input",
          "table" => "input",
          "address" => 0,
          "count" => 2,
          "initial" => [32768, 0]
        },
        %{
          "id" => "coil",
          "table" => "coil",
          "address" => 0,
          "count" => 2,
          "initial" => [true, false]
        },
        %{
          "id" => "discrete",
          "table" => "discrete",
          "address" => 0,
          "count" => 2,
          "initial" => [false, true]
        }
      ]
    }
  end

  defp modbus_client do
    server = modbus_server()

    ranges =
      Enum.map(server["ranges"], fn range ->
        range
        |> Map.delete("initial")
        |> Map.put("writable", range["table"] in ["holding", "coil"])
      end)

    Map.merge(server, %{
      "role" => "client",
      "host" => "127.0.0.1",
      "interval" => 200,
      "timeout" => 500,
      "ranges" => ranges
    })
  end

  # Disposable guests are replaced without closing host sockets: do not pool HTTP connections.
  defp guest_page(vm, path),
    do: Req.get!(Scenarios.Qemu.ui_url(vm) <> path, headers: [connection: "close"], retry: false)
end
