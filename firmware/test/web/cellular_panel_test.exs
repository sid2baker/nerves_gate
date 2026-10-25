defmodule NervesGateWeb.CellularPanelTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]
  alias NervesGateWeb.CellularPanel

  test "happy path only shows SIM readiness and the detected carrier" do
    document = panel(%{sim: :ready, provider: %{name: "Example carrier", apn: "example.apn"}})
    assert Floki.text(document) =~ "SIM ready"
    assert Floki.text(document) =~ "Example carrier"
    assert [] = Floki.find(document, "details, summary, input, select")
    refute Floki.text(document) =~ "example.apn"
    refute Floki.text(document) =~ "RSSI"
  end

  test "PIN form is a single attempt, before connecting, without draft/recovery or values" do
    document = panel(%{sim: :pin_required, pin_attempts_remaining: 3}, connect: true)
    assert [_] = Floki.find(document, "form[phx-submit=unlock-connect][phx-auto-recover=ignore]")
    assert [_] = Floki.find(document, "input[type=password][name=pin]:not([value])")
    assert [] = Floki.find(document, "[phx-change], input[name=username], details")
    assert Floki.text(document) =~ "Unlock and connect"
    assert Floki.text(document) =~ "3 attempts remaining"
    assert Floki.text(document) =~ "remembered privately"
  end

  test "locked SIMs can be commissioned while cellular data is disabled" do
    document = panel(%{sim: :pin_required, enabled: false}, connect: true)
    assert [_] = Floki.find(document, "form[phx-submit=unlock-connect]")
    refute Floki.text(document) =~ "Enable and save"
  end

  test "unprotected or blocked SIMs never get an inappropriate PIN form" do
    assert [] =
             Floki.find(
               panel(%{sim: :ready, pin_lock: :disabled}, settings: true),
               "form[phx-submit=save_pin], form[phx-submit=unlock]"
             )

    for sim <- [:puk_required, :pin2_required, :puk2_required] do
      document = panel(%{sim: sim})
      assert Floki.text(document) =~ "Do not guess"
      assert [] = Floki.find(document, "input")
    end
  end

  test "diagnostics are plain content and PIN changes stay out of the web flow" do
    document =
      panel(
        %{
          sim: :ready,
          pin_lock: :enabled,
          auto_unlock: :blocked,
          signal_dbm: -71,
          access_technology: "LTE"
        },
        settings: true
      )

    assert Floki.text(document) =~ "-71 dBm"
    assert Floki.text(document) =~ "LTE"
    assert [_] = Floki.find(document, "form[phx-submit=save_pin]")

    assert [] =
             Floki.find(
               document,
               "details, summary, form[phx-submit=change_pin], form[phx-submit=set_pin_lock]"
             )

    assert [] = Floki.find(document, "input[type=password][value]")
  end

  test "private PAP is only offered for a deliberately chosen custom plan" do
    changes = %{sim: :ready, authentication: :pap, authentication_apn: "private.example"}
    assert [] = Floki.find(panel(changes, settings: true), "form[phx-submit=save_authentication]")
    document = panel(changes, settings: true, custom: true, apn: "private.example")

    assert [_] =
             Floki.find(document, "form[phx-submit=save_authentication][phx-auto-recover=ignore]")

    assert [] =
             Floki.find(
               document,
               "input[name=username][value], input[name=password][value], [phx-change]"
             )

    assert Floki.text(document) =~ "not your SIM PIN"
    assert Floki.text(document) =~ "Saving does not reconnect"
  end

  test "failure remains visible after an observation refresh" do
    error = %{code: "cellular_incorrect_pin", message: "PIN rejected; no retry was sent."}
    document = panel(%{sim: :ready, result: %{operation: :unlock, error: error}})
    assert Floki.text(Floki.find(document, "[role=alert]")) =~ error.message
  end

  defp panel(changes, options \\ []) do
    cellular =
      NervesGate.Cellular.empty()
      |> Map.merge(%{supported: true, enabled: true, present: true})
      |> Map.merge(changes)

    actions =
      Map.new(
        ~w(refresh unlock save_pin forget_pin save_authentication forget_authentication reconnect),
        &{"cellular.#{&1}", %{enabled: true}}
      )

    render_component(
      &CellularPanel.sim/1,
      Keyword.merge(
        [
          projection: %{cellular: cellular, actions: actions},
          target: %Phoenix.LiveComponent.CID{cid: 1}
        ],
        options
      )
    )
    |> Floki.parse_fragment!()
  end
end
