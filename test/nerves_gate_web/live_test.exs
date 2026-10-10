defmodule NervesGateWeb.LiveTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias NervesGate.Device
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
    assert {:ok, %{result: %{trial_id: id}}} =
             Device.dispatch("network.propose", %{"network" => %{"ip_method" => "dhcp"}})

    {:ok, view, _} = live(build_conn(), "/setup")
    assert has_element?(view, "#confirm-settings")
    assert NervesGate.Network.status().trial.id == id
    view |> element("button", "Restore previous settings") |> render_click()
    refute NervesGate.Network.status().trial
  end

  test "discovery publishes live updates" do
    {:ok, view, _} = live(build_conn(), "/")
    Device.subscribe()

    NervesGate.Network.Host.simulate(%{
      ports: [%{name: "eth0", present: false, link: false, master: nil}]
    })

    assert_receive {:device, projection}
    refute hd(projection.network.observed.ports).present
    eventually(fn -> render(view) =~ "Not installed" end)
  end

  test "dashboard and setup work without internet" do
    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Your local network"
    assert has_element?(view, "a[href='/setup']")
    {:ok, _view, html} = live(build_conn(), "/setup")
    assert html =~ "Welcome to Nerves Gate"
  end

  test "a CLI command and two browsers share the trial and action availability" do
    {:ok, setup, _} = live(build_conn(), "/setup")
    {:ok, dashboard, _} = live(build_conn(), "/")

    assert {:ok, %{result: %{trial_id: id}, projection: projection}} =
             Device.dispatch("network.propose", %{"network" => %{"ip_method" => "dhcp"}})

    eventually(fn -> has_element?(setup, "#confirm-settings:not([disabled])") end)
    eventually(fn -> render(dashboard) =~ "Settings are being tried" end)

    assert {:ok, _} = Device.dispatch("network.confirm", %{"trial_id" => id})

    eventually(fn -> not has_element?(setup, "#confirm-settings") end)
    eventually(fn -> not (render(dashboard) =~ "Settings are being tried") end)

    # Exercise the real LiveView subscription callback with a delayed old snapshot.
    Phoenix.PubSub.broadcast(NervesGate.PubSub, Device.topic(), {:device, projection})
    refute has_element?(setup, "#confirm-settings")
    refute render(dashboard) =~ "Settings are being tried"
  end

  test "an old browser click cannot confirm a newer client's trial" do
    {:ok, %{result: %{trial_id: old}}} =
      Device.dispatch("network.propose", %{"network" => %{"ip_method" => "dhcp"}})

    {:ok, view, _} = live(build_conn(), "/setup")
    assert {:ok, _} = Device.dispatch("network.cancel", %{"trial_id" => old})

    {:ok, %{result: %{trial_id: current}}} =
      Device.dispatch("network.propose", %{"network" => %{"ip_method" => "dhcp"}})

    assert render_click(view, "confirm", %{"trial_id" => old}) =~ "This trial has ended"
    assert Device.projection().network.pending.id == current
    refute Device.projection().network.setup_completed
  end

  test "LiveView manages projection subscriptions only while connected" do
    topic = Device.topic()

    for path <- ["/", "/setup"] do
      assert build_conn() |> get(path) |> response(200) != ""
      refute topic in Registry.keys(NervesGate.PubSub, self())

      {:ok, view, _} = live(build_conn(), path)
      pid = view.pid

      assert [{^pid, [Phoenix.LiveView.PubSub | ref]}] =
               Registry.lookup(NervesGate.PubSub, topic)
               |> Enum.filter(fn {subscriber, _} -> subscriber == pid end)

      assert is_reference(ref)
      GenServer.stop(pid)
      eventually(fn -> Registry.keys(NervesGate.PubSub, pid) == [] end)
    end
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

  defp eventually(fun, remaining \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, remaining) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      eventually(fun, remaining - 1)
    end
  end
end
