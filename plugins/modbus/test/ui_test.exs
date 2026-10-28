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
