defmodule NervesGateWeb.LiveTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint NervesGateWeb.Endpoint
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Supervisor.terminate_child(NervesGate.Supervisor, NervesGate.Network)
    NervesGate.Network.Host.simulate(%{})
    start_supervised!({NervesGate.Network, path: Path.join(dir, "nerves_gate.json"), poll_ms: 10})

    on_exit(fn ->
      NervesGate.Network.Host.simulate(%{})
      Supervisor.restart_child(NervesGate.Supervisor, NervesGate.Network)
    end)

    :ok
  end

  test "setup validates, reviews, trials and saves shared domain settings" do
    {:ok, view, _} = live(build_conn(), "/setup")
    view |> element("button", "Configure local access") |> render_click()
    view |> form("#network-form", network: %{ip_method: "static"}) |> render_change()
    invalid = %{ip_method: "static", static_ip: "bad", subnet_mask: "255.255.255.0", gateway: ""}

    assert view |> form("#network-form", network: invalid) |> render_submit() =~
             "Enter a usable IPv4"

    valid = %{invalid | static_ip: "192.168.50.10"}

    assert view |> form("#network-form", network: valid) |> render_submit() =~
             "Review before changing"

    refute NervesGate.Network.status().trial
    assert view |> element("#apply-settings") |> render_click() =~ "Can you still reach"
    refute NervesGate.Network.status().config["setup_completed"]
    assert view |> element("#confirm-settings") |> render_click() =~ "Local setup complete"
    assert NervesGate.Network.status().config["network"]["static_ip"] == "192.168.50.10"
    {:ok, dashboard, _} = live(build_conn(), "/")
    assert render(dashboard) =~ "192.168.50.10"
  end

  test "trial survives browser reconnection and can be cancelled" do
    assert {:ok, id} = NervesGate.Network.propose(%{"ip_method" => "dhcp"})
    {:ok, view, _} = live(build_conn(), "/setup")
    assert has_element?(view, "#confirm-settings")
    assert NervesGate.Network.status().trial.id == id
    view |> element("button", "Restore previous settings") |> render_click()
    refute NervesGate.Network.status().trial
  end

  test "discovery publishes live updates" do
    {:ok, view, _} = live(build_conn(), "/")
    status = NervesGate.Network.status()

    observed =
      put_in(status.observed.ports, [%{name: "eth0", present: false, link: false, master: nil}])

    Phoenix.PubSub.broadcast(NervesGate.PubSub, "network", {:network, observed})
    assert render(view) =~ "Not installed"
  end

  test "dashboard and setup work without internet" do
    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Your local network"
    assert has_element?(view, "a[href='/setup']")
    {:ok, _view, html} = live(build_conn(), "/setup")
    assert html =~ "Welcome to Nerves Gate"
  end

  test "assets are served locally" do
    for path <- [
          "/assets/app.css",
          "/assets/app.js",
          "/vendor/phoenix/phoenix.mjs",
          "/vendor/live_view/phoenix_live_view.esm.js"
        ] do
      assert build_conn() |> get(path) |> response(200) != ""
    end
  end
end
