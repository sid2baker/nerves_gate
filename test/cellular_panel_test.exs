defmodule Dev.CellularPanelTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]
  alias NervesGate.Network.Cellular
  alias NervesGateWeb.{Backend, CellularPanel}

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

  test "non-USB UI has no credential or forgetting controls" do
    for sim <- [:ready, :pin_required] do
      html = panel(%{sim: sim, pin_saved: true}, false)
      refute html =~ "type=\"password\""
      refute html =~ "phx-submit=\"unlock\""
      refute html =~ "phx-click=\"forget_pin\""
      assert html =~ "direct USB"
    end
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

  test "credential admission requires local backend and independently verified USB endpoints" do
    observed = %{
      usb: %{
        present: true,
        link: true,
        addresses: [%{address: "172.31.10.1", prefix_length: 30}]
      },
      ports: [],
      bridge: %{}
    }

    access = %{local: "172.31.10.1", peer: {172, 31, 10, 2}}
    assert Backend.cellular_credentials_allowed?(observed, access, :local)
    refute Backend.cellular_credentials_allowed?(observed, access, :remote_node)
    refute Backend.cellular_credentials_allowed?(observed, access, nil)
    refute Backend.cellular_credentials_allowed?(observed, %{usb: true}, :local)
    refute Backend.cellular_credentials_allowed?(nil, access, :local)

    refute Backend.cellular_credentials_allowed?(
             observed,
             %{access | peer: {10, 1, 1, 2}},
             :local
           )

    overlapping = %{
      observed
      | ports: [%{addresses: [%{address: "172.31.10.2", prefix_length: 24}]}]
    }

    refute Backend.cellular_credentials_allowed?(overlapping, access, :local)
  end

  defp panel(changes, allowed \\ true) do
    cellular =
      Cellular.empty()
      |> Map.merge(%{supported: true, enabled: true, present: true})
      |> Map.merge(changes)

    actions =
      Map.new(~w(refresh unlock save_pin forget_pin change_pin set_pin_lock), fn name ->
        {"cellular.#{name}", %{enabled: true}}
      end)

    render_component(&CellularPanel.content/1,
      id: "cellular-test",
      cellular: cellular,
      credentials_allowed: allowed,
      projection: %{actions: actions},
      myself: %Phoenix.LiveComponent.CID{cid: 1},
      generation: 0,
      message: nil
    )
  end
end
