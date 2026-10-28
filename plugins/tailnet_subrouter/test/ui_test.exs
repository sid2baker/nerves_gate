defmodule TailnetSubrouter.UITest do
  use ExUnit.Case, async: false
  import Phoenix.LiveViewTest
  alias TailnetSubrouter.UI
  alias NervesGateSDK.Network.Interface

  test "app-owned controls render disabled until explicit configuration" do
    html = render_component(UI, id: "subrouter")
    assert html =~ "Share a local subnet"
    assert html =~ "State: disabled"
    assert html =~ "Configure address"
    assert html =~ "Enable sharing"
    assert html =~ "Tailscale admin console"
    assert TailnetSubrouter.status() == %{state: :disabled}
  end

  test "Internet port is explained and disabled; eligible Ethernet is selected even without a link" do
    html =
      render_component(UI,
        id: "subrouter",
        interfaces:
          {:ok,
           [
             port("eth0", internet?: true, addresses: ["192.168.1.2"]),
             port("eth1", plugin_enabled?: true)
           ]}
      )

    assert html =~
             ~r/<option[^>]*value="eth0"[^>]*disabled[^>]*>eth0 — Used for Internet<\/option>/

    assert html =~ ~r/<option[^>]*value="eth1"[^>]*selected[^>]*>eth1<\/option>/
    refute html =~ ~r/<button[^>]*disabled[^>]*>Configure address<\/button>/
  end

  test "claimed, addressed and operator-disabled ports cannot be selected" do
    for {attributes, reason} <- [
          {[claimed?: true, plugin_enabled?: true], "Already claimed"},
          {[plugin_enabled?: true, addresses: ["192.168.50.2"]], "Already has an address"},
          {[], "Disabled under Hardware"},
          {[plugin_enabled?: true, assigned_plugin: nil], "Not assigned to this plugin"},
          {[plugin_enabled?: true, assigned_plugin: "another_plugin"],
           "Not assigned to this plugin"}
        ] do
      html = render_component(UI, id: "subrouter", interfaces: {:ok, [port("eth1", attributes)]})
      assert html =~ ~r/<option[^>]*value="eth1"[^>]*disabled/
      assert html =~ reason
      assert html =~ "No application interface is available"
      assert html =~ ~r/<button[^>]*disabled[^>]*>Configure address<\/button>/
    end
  end

  test "unavailable or empty observations fail closed rather than inventing interfaces" do
    for interfaces <- [{:error, :unavailable}, {:ok, []}, {:ok, [port("usb0", kind: :usb)]}] do
      html = render_component(UI, id: "subrouter", interfaces: interfaces)
      refute html =~ ~r/<option[^>]*value="(?:eth0|eth1|usb0)"/
      assert html =~ ~r/<button[^>]*disabled[^>]*>Configure address<\/button>/
    end
  end

  test "editing a selection updates eligibility without configuring the interface" do
    interfaces = {:ok, [port("eth0", internet?: true), port("eth1", plugin_enabled?: true)]}

    {:ok, socket} =
      UI.update(%{id: "subrouter", interfaces: interfaces}, %Phoenix.LiveView.Socket{})

    for {interface, disabled?} <- [{"eth0", true}, {"eth1", false}] do
      assert {:noreply, edited} =
               UI.handle_event(
                 "edit_config",
                 %{
                   "config" => %{
                     "interface" => interface,
                     "address" => "192.168.50.2",
                     "prefix" => "24"
                   }
                 },
                 socket
               )

      html =
        render_component(UI, id: "subrouter", interfaces: interfaces, form: edited.assigns.form)

      assert Regex.match?(~r/<button[^>]*disabled[^>]*>Configure address<\/button>/, html) ==
               disabled?

      assert TailnetSubrouter.status() == %{state: :disabled}
    end
  end

  test "forged unavailable selection is rejected and refresh preserves address drafts" do
    {:ok, socket} =
      UI.update(
        %{id: "subrouter", interfaces: {:ok, [port("eth0", internet?: true)]}},
        %Phoenix.LiveView.Socket{}
      )

    assert {:noreply, rejected} =
             UI.handle_event(
               "configure",
               %{
                 "config" => %{
                   "interface" => "eth0",
                   "address" => "192.168.50.2",
                   "prefix" => "24"
                 }
               },
               socket
             )

    assert rejected.assigns.message =~ "Select an available"
    assert TailnetSubrouter.status() == %{state: :disabled}
    assert {:noreply, refreshed} = UI.handle_event("refresh", %{}, rejected)
    assert {:error, reason} = refreshed.assigns.interfaces
    assert reason in [:runtime_unavailable, :unavailable]
    assert refreshed.assigns.form[:address].value == "192.168.50.2"
    assert refreshed.assigns.form[:interface].value == "eth0"
  end

  defp port(id, attributes) do
    struct!(
      %Interface{id: id, kind: :ethernet, state: :down, assigned_plugin: "tailnet_subrouter"},
      attributes
    )
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
