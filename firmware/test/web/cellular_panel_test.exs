defmodule NervesGateWeb.CellularPanelTest do
  use ExUnit.Case, async: false
  import Phoenix.LiveViewTest, only: [render_component: 2]
  alias NervesGate.Cellular
  alias NervesGateWeb.CellularPanel

  test "unlock form explains private storage and never uses change events or credential values" do
    html = panel(%{sim: :pin_required})
    assert html =~ "Unlock and save PIN"
    assert html =~ "stored privately"
    assert html =~ "type=\"password\""
    refute html =~ "phx-change"
    refute html =~ "phx-auto-recover"
    refute html =~ "name=\"current_pin\""
    assert {:ok, document} = Floki.parse_fragment(html)
    assert Floki.find(document, "input[type=password][value]") == []
  end

  test "ready SIM offers explicit verification, changes and protection but not unlock" do
    html = panel(%{sim: :ready, pin_saved: true, auto_unlock: :blocked})
    assert html =~ "Verify and save PIN"
    assert html =~ "one PIN attempt"
    assert html =~ "Change SIM PIN"
    assert html =~ "name=\"acknowledged\""
    assert html =~ "Automatic unlock is blocked"
    refute html =~ "phx-submit=\"unlock\""
    assert {:ok, document} = Floki.parse_fragment(html)
    assert Floki.find(document, "input[type=password][value]") == []
  end

  test "SIM controls need no USB access observations" do
    html = panel(%{sim: :pin_required, pin_saved: true})
    assert html =~ "phx-submit=\"unlock\""
    assert html =~ "phx-click=\"forget_pin\""
    assert html =~ "type=\"password\""
    refute html =~ "direct USB"

    html = panel(%{sim: :ready})
    assert html =~ "phx-submit=\"save_pin\""
    assert html =~ "phx-submit=\"change_pin\""
    assert html =~ "phx-submit=\"set_pin_lock\""
  end

  test "disabled modem preserves stored PIN and permits forgetting without changing protection" do
    html = panel(%{enabled: false, pin_saved: true, auto_unlock: :blocked})
    assert html =~ "Cellular is disabled"
    assert html =~ "Stored on this device"
    assert html =~ "Forget saved PIN (keep SIM protection)"
    assert html =~ "not encrypted"
    assert html =~ "full data-partition backups"
    refute html =~ "type=\"password\""
  end

  test "no modem does not tell the user to select a disabled 4G source" do
    html = panel(%{enabled: false, present: false})
    assert html =~ "No 4G modem detected"
    refute html =~ "Apply and save a 4G Internet source"
    refute html =~ "type=\"password\""
  end

  test "a different SIM and missing identity never claim automatic unlock is ready" do
    assert panel(%{auto_unlock: :different_sim}) =~ "belongs to another SIM"
    assert panel(%{auto_unlock: :identity_unknown}) =~ "Automatic unlock will not send a PIN"
    assert panel(%{sim: :puk_required}) =~ "Never guess a code"
    refute panel(%{sim: :puk_required}) =~ "type=\"password\""
    assert panel(%{supported: false}) =~ "not supported on this target"
  end

  test "credential commands and events need no USB access and never retain submitted PINs" do
    assert Process.whereis(NervesGate.Network) == nil

    for result <- [
          NervesGate.Cellular.unlock("invalid"),
          NervesGate.Cellular.save_pin("invalid"),
          NervesGate.Cellular.forget_pin(),
          NervesGate.Cellular.change_pin("invalid", "invalid"),
          NervesGate.Cellular.set_pin_lock(true, "invalid")
        ] do
      assert {:error, %{code: "unavailable"}} = result
    end

    for {event, params} <- [
          {"unlock", %{"pin" => "invalid"}},
          {"save_pin", %{"pin" => "invalid"}},
          {"forget_pin", %{}},
          {"change_pin",
           %{"current_pin" => "invalid", "new_pin" => "invalid", "repeat_pin" => "invalid"}},
          {"set_pin_lock", %{"enabled" => "true", "pin" => "invalid"}}
        ] do
      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, generation: 0, message: nil}}
      assert {:noreply, updated} = CellularPanel.handle_event(event, params, socket)
      assert updated.assigns.generation == 1
      assert is_binary(updated.assigns.message)
      refute inspect(updated.assigns) =~ "invalid"
    end
  end

  defp panel(changes) do
    cellular =
      Cellular.empty()
      |> Map.merge(%{supported: true, enabled: true, present: true})
      |> Map.merge(changes)

    actions =
      Map.new(~w(refresh unlock save_pin forget_pin change_pin set_pin_lock), fn name ->
        {"cellular.#{name}", %{enabled: true}}
      end)

    render_component(&CellularPanel.render/1,
      id: "cellular-test",
      projection: %{actions: actions, cellular: cellular},
      myself: %Phoenix.LiveComponent.CID{cid: 1},
      generation: 0,
      message: nil
    )
  end
end
