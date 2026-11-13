defmodule ModbusPlugin.UITest do
  use ExUnit.Case, async: false
  import Phoenix.LiveViewTest

  test "default TCP client shows simple raw range fields, not register interpretation or RS485" do
    html = render_component(ModbusPlugin.UI, id: "modbus")
    assert html =~ "Device IP / hostname"
    assert html =~ "Start address"
    assert html =~ "Count"
    refute html =~ "Mappings (JSON"
    refute html =~ "Solis"
    refute html =~ "word_order"
    refute html =~ "RS485 port"
    refute html =~ "Parity"
    assert html =~ "block1"
  end

  test "framework component mounting owns the CID and renders the raw controls" do
    rendered =
      Phoenix.LiveView.Diff.component_to_rendered(
        %Phoenix.LiveView.Socket{transport_pid: self()},
        ModbusPlugin.UI,
        %{id: "plugin-ui"},
        %{myself: %Phoenix.LiveComponent.CID{cid: 1}}
      )

    html = rendered |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()
    assert html =~ "Raw ranges"
    assert html =~ ~s(phx-target="1")
    refute html =~ "Load Solis"
  end

  test "range editing, role and transport changes only affect the draft" do
    {:ok, socket} = ModbusPlugin.UI.update(%{id: "modbus"}, %Phoenix.LiveView.Socket{})

    params = %{
      "role" => "client",
      "transport" => "tcp",
      "host" => "192.0.2.10",
      "ranges" => %{
        "0" => %{"id" => "raw", "table" => "input", "address" => "33149", "count" => "2"}
      }
    }

    {:noreply, socket} = ModbusPlugin.UI.handle_event("edit", %{"connection" => params}, socket)
    assert socket.assigns.draft["host"] == "192.0.2.10"
    assert [%{"count" => "2"}] = socket.assigns.draft["ranges"]
    {:noreply, socket} = ModbusPlugin.UI.handle_event("add_range", %{}, socket)
    assert length(socket.assigns.draft["ranges"]) == 2
    {:noreply, socket} = ModbusPlugin.UI.handle_event("remove_range", %{"index" => "1"}, socket)
    assert length(socket.assigns.draft["ranges"]) == 1
    assert ModbusPlugin.Connection.pid("client1") == nil

    html =
      render_component(ModbusPlugin.UI,
        id: "modbus",
        draft: Map.merge(socket.assigns.draft, %{"transport" => "rtu"})
      )

    assert html =~ "RS485 port"
    refute html =~ "Device IP / hostname"
  end

  test "LiveView unused-field metadata never becomes configuration" do
    {:ok, socket} = ModbusPlugin.UI.update(%{id: "modbus"}, %Phoenix.LiveView.Socket{})

    params = %{
      "host" => "192.0.2.10",
      "_unused_host" => "",
      "_unused_port" => "",
      "_unused_ranges" => "",
      "ranges" => %{
        "0" => %{
          "id" => "raw",
          "table" => "input",
          "address" => "0",
          "count" => "2",
          "_unused_address" => ""
        }
      }
    }

    {:noreply, socket} = ModbusPlugin.UI.handle_event("edit", %{"connection" => params}, socket)
    refute Map.has_key?(socket.assigns.draft, "_unused_host")
    refute Map.has_key?(socket.assigns.draft, "_unused_port")
    refute Map.has_key?(socket.assigns.draft, "_unused_ranges")
    {:noreply, socket} = ModbusPlugin.UI.handle_event("save", %{"connection" => params}, socket)
    assert socket.assigns.message =~ "storage_unavailable"
    refute socket.assigns.message =~ "unknown_field"
    assert ModbusPlugin.Connection.pid("client1") == nil
  end

  test "each range has its own right-side remove control and deleting the middle preserves the others" do
    {:ok, socket} = ModbusPlugin.UI.update(%{id: "modbus"}, %Phoenix.LiveView.Socket{})
    {:noreply, socket} = ModbusPlugin.UI.handle_event("add_range", %{}, socket)
    {:noreply, socket} = ModbusPlugin.UI.handle_event("add_range", %{}, socket)
    html = render_component(ModbusPlugin.UI, id: "modbus", draft: socket.assigns.draft)

    for index <- 0..2 do
      assert html =~ ~s(id="modbus-range-#{index}")
      assert html =~ ~s(phx-value-index="#{index}")
      assert html =~ ~s(aria-label="Remove range block#{index + 1}")
    end

    assert html =~ "margin-left: auto"
    {:noreply, socket} = ModbusPlugin.UI.handle_event("remove_range", %{"index" => "1"}, socket)
    assert Enum.map(socket.assigns.draft["ranges"], & &1["id"]) == ["block1", "block3"]
    html = render_component(ModbusPlugin.UI, id: "modbus", draft: socket.assigns.draft)
    assert html =~ ~s(aria-label="Remove range block1")
    assert html =~ ~s(aria-label="Remove range block3")
    refute html =~ ~s(aria-label="Remove range block2")
    {:noreply, socket} = ModbusPlugin.UI.handle_event("add_range", %{}, socket)
    assert Enum.map(socket.assigns.draft["ranges"], & &1["id"]) == ["block1", "block3", "block2"]
  end

  test "saved raw observations and advanced discovery are separate from the draft" do
    {:ok, config} =
      ModbusPlugin.Config.validate("one", %{
        "role" => "client",
        "host" => "localhost",
        "port" => 502,
        "unit" => 1,
        "timeout" => 1000,
        "interval" => 1000,
        "ranges" => [%{"id" => "words", "table" => "input", "address" => 33149, "count" => 2}]
      })

    connection =
      Map.merge(config, %{
        state: :polling,
        error: nil,
        observations: %{
          "words" => %{
            values: [65535, 65436],
            quality: :good,
            error: nil,
            observed_at: "2026-11-04T00:00:00Z"
          }
        }
      })

    status = %{storage: nil, connections: [connection]}
    html = render_component(ModbusPlugin.UI, id: "modbus", status: status)
    assert html =~ "65535"
    assert html =~ "65436"
    # input ranges cannot be writable
    refute html =~ "Allow explicit raw writes</label>"

    {:ok, socket} =
      ModbusPlugin.UI.update(%{id: "modbus", status: status}, %Phoenix.LiveView.Socket{})

    {:noreply, socket} = ModbusPlugin.UI.handle_event("load", %{"id" => "one"}, socket)
    assert socket.assigns.draft["id"] == "one"
    assert [%{"address" => "33149", "count" => "2"}] = socket.assigns.draft["ranges"]
    assert socket.assigns.status == status

    survey = %{
      requests: 4,
      budget: 200,
      remaining: 0,
      units: [],
      failures: [],
      evidence: [%{unit: 1, table: :input, address: 33149, raw: 65535}]
    }

    html =
      render_component(ModbusPlugin.UI,
        id: "modbus",
        status: %{
          status
          | connections: [Map.merge(connection, %{state: :discovered, discovery: survey})]
        }
      )

    assert html =~ "Raw discovery results"
    refute html =~ "Promote"
  end
end
