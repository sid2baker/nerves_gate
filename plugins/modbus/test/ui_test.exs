defmodule ModbusPlugin.UITest do
  use ExUnit.Case, async: false
  import Phoenix.LiveViewTest

  setup do
    :ok = Application.stop(:modbus_plugin)
    {:ok, _} = Application.ensure_all_started(:modbus_plugin)
    :ok
  end

  test "UI drafts definitions and reports blocked storage without starting anything" do
    html = render_component(ModbusPlugin.UI, id: "modbus")
    assert html =~ "Modbus TCP"
    assert html =~ "Save definition · no connection"
    assert html =~ "Saved configuration blocked"
    refute html =~ ">Start<"
    {:ok, socket} = ModbusPlugin.UI.update(%{id: "modbus"}, %Phoenix.LiveView.Socket{})
    assert socket.assigns.form.params["role"] == "server"

    assert {:noreply, malformed} =
             ModbusPlugin.UI.handle_event(
               "save",
               %{"connection" => %{"id" => "bad", "mappings" => "{"}},
               socket
             )

    assert malformed.assigns.message =~ "JSON list"

    # Validation and persistence belong to the controller, not the component.
    params = %{socket.assigns.form.params | "transport" => "tcp", "port" => "1502"}

    assert {:noreply, refused} =
             ModbusPlugin.UI.handle_event("save", %{"connection" => params}, socket)

    assert refused.assigns.message =~ "storage_unavailable"
    assert ModbusPlugin.Connection.pid("server1") == nil
  end

  test "unassigned saved RTU drafts offer review but cannot start" do
    {:ok, socket} = ModbusPlugin.UI.update(%{id: "modbus"}, %Phoenix.LiveView.Socket{})
    defaults = socket.assigns.form.params
    {:ok, mappings} = JSON.decode(defaults["mappings"])

    {:ok, %{"server1" => config}} =
      ModbusPlugin.Store.put(
        %{},
        "server1",
        Map.merge(defaults, %{
          "mappings" => mappings,
          "authorized" => "true",
          "serial_port" => "ttyS1"
        })
      )

    connection = Map.merge(config, %{state: :stopped, values: nil, error: nil, read_at: nil})

    port = %NervesGateSDK.Hardware.Candidate{
      id: "ttyS1",
      label: "RS485 1",
      kind: :rs485,
      present?: true,
      enabled?: false
    }

    html =
      render_component(ModbusPlugin.UI,
        id: "modbus",
        ports: [port],
        status: %{storage: nil, connections: [connection]}
      )

    assert html =~ "RS485 1 (ttyS1)"
    assert html =~ "Available for assignment"
    assert html =~ "/hardware/ttyS1?plugin=modbus_plugin"
    assert html =~ ~r/<button[^>]*phx-click="start"[^>]*disabled/
    assert ModbusPlugin.Connection.pid("server1") == nil
  end

  test "discovery controls render and promotion and templates only change a draft" do
    {:ok, socket} = ModbusPlugin.UI.update(%{id: "modbus"}, %Phoenix.LiveView.Socket{})

    defaults =
      socket.assigns.form.params
      |> Map.merge(%{
        "role" => "client",
        "transport" => "tcp",
        "host" => "localhost",
        "mappings" => [%{"id" => "point", "table" => "input", "address" => 0}]
      })

    {:ok, config} = ModbusPlugin.Config.validate("client1", defaults)

    evidence = %{
      unit: 2,
      table: :input,
      address: 33139,
      raw: 80,
      hex: "0050",
      observed_at: "2026-11-04T00:00:00Z"
    }

    model = %{id: 1, address: 40002, length: 66}

    survey = %{
      requests: 8,
      budget: 100,
      remaining: 0,
      units: [],
      sunspec: [%{unit: 2, base: 40000, models: [model]}],
      evidence: [evidence]
    }

    connection =
      Map.merge(config, %{
        state: :discovered,
        values: nil,
        error: nil,
        read_at: nil,
        discovery: survey
      })

    status = %{storage: nil, connections: [connection]}
    socket = Phoenix.Component.assign(socket, :status, status)
    html = render_component(ModbusPlugin.UI, id: "modbus", status: status)
    assert html =~ "Raw discovery evidence"
    assert html =~ "0050"
    assert html =~ "Promote to draft"
    assert html =~ "Common-model strings"

    {:noreply, promoted} =
      ModbusPlugin.UI.handle_event(
        "promote",
        %{"id" => "client1", "unit" => "2", "table" => "input", "address" => "33139"},
        socket
      )

    assert promoted.assigns.form.params["unit"] == "2"

    assert JSON.decode!(promoted.assigns.form.params["mappings"]) == [
             ModbusPlugin.Discovery.mapping(evidence)
           ]

    assert promoted.assigns.status == status
    assert promoted.assigns.message =~ "draft only"

    {:noreply, sun} =
      ModbusPlugin.UI.handle_event(
        "sunspec",
        %{"id" => "client1", "unit" => "2", "address" => "40002"},
        socket
      )

    assert length(JSON.decode!(sun.assigns.form.params["mappings"])) == 3
    {:noreply, solis} = ModbusPlugin.UI.handle_event("solis", %{}, promoted)
    assert JSON.decode!(solis.assigns.form.params["mappings"]) == ModbusPlugin.Profiles.solis()
    assert ModbusPlugin.Connection.pid("client1") == nil
  end

  test "Edit loads a saved definition into a separate draft; role switches keep user edits" do
    {:ok, socket} = ModbusPlugin.UI.update(%{id: "modbus"}, %Phoenix.LiveView.Socket{})
    defaults = socket.assigns.form.params

    {:ok, mappings} = JSON.decode(defaults["mappings"])

    {:ok, %{"server1" => config}} =
      ModbusPlugin.Store.put(%{}, "server1", %{
        defaults
        | "transport" => "tcp",
          "port" => "1502",
          "mappings" => mappings
      })

    connection = Map.merge(config, %{state: :stopped, values: nil, error: nil, read_at: nil})

    saved = %{
      socket
      | assigns: %{socket.assigns | status: %{storage: nil, connections: [connection]}}
    }

    assert {:noreply, loaded} = ModbusPlugin.UI.handle_event("load", %{"id" => "server1"}, saved)
    assert loaded.assigns.form.params["port"] == "1502"
    assert loaded.assigns.form.params["mappings"] =~ "holding0"

    assert {:noreply, client} =
             ModbusPlugin.UI.handle_event(
               "edit",
               %{"connection" => %{defaults | "role" => "client"}},
               socket
             )

    assert client.assigns.form.params["mappings"] =~ "holding0_set"
    edited = %{defaults | "mappings" => "[{}]"}
    {:noreply, drafted} = ModbusPlugin.UI.handle_event("edit", %{"connection" => edited}, socket)

    assert {:noreply, kept} =
             ModbusPlugin.UI.handle_event(
               "edit",
               %{"connection" => %{edited | "role" => "client"}},
               drafted
             )

    assert kept.assigns.form.params["mappings"] == "[{}]"
  end
end
