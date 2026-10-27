defmodule ModbusPlugin.UITest do
  use ExUnit.Case, async: false
  import Phoenix.LiveViewTest

  setup do
    :ok = Application.stop(:modbus_plugin)
    {:ok, _} = Application.ensure_all_started(:modbus_plugin)
    :ok
  end

  test "UI renders configuration without connecting and validates in the controller" do
    html = render_component(ModbusPlugin.UI, id: "modbus")
    assert html =~ "Modbus TCP"
    assert html =~ "Save configuration · no connection"
    refute html =~ "Connect and poll"
    {:ok, socket} = ModbusPlugin.UI.update(%{id: "modbus"}, %Phoenix.LiveView.Socket{})

    assert {:noreply, rejected} =
             ModbusPlugin.UI.handle_event(
               "configure",
               %{"device" => %{"id" => "bad", "host" => ""}},
               socket
             )

    assert rejected.assigns.message =~ "invalid_configuration"
  end
end
