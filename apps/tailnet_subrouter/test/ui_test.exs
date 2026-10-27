defmodule TailnetSubrouter.UITest do
  use ExUnit.Case, async: false
  import Phoenix.LiveViewTest
  alias TailnetSubrouter.UI

  test "app-owned controls render disabled until explicit configuration" do
    html = render_component(UI, id: "subrouter")
    assert html =~ "Share a local subnet"
    assert html =~ "State: disabled"
    assert html =~ "Configure address"
    assert html =~ "Enable sharing"
    assert html =~ "Tailscale admin console"
    assert TailnetSubrouter.status() == %{state: :disabled}
    assert Application.get_env(:nerves_gate_sdk, :backend) == nil
  end

  test "invalid prefix stays a draft and enable still uses the supervised app's validation" do
    {:ok, socket} = UI.update(%{id: "subrouter"}, %Phoenix.LiveView.Socket{})

    assert {:noreply, draft} =
             UI.handle_event(
               "configure",
               %{
                 "config" => %{
                   "interface" => "eth1",
                   "address" => "192.168.50.2",
                   "prefix" => "invalid"
                 }
               },
               socket
             )

    assert draft.assigns.message =~ "prefix length"
    assert draft.assigns.form[:address].value == "192.168.50.2"
    assert TailnetSubrouter.status() == %{state: :disabled}
    assert {:noreply, rejected} = UI.handle_event("enable", %{}, socket)
    assert rejected.assigns.message == "configure first"
  end
end
