defmodule NervesGateWeb.LiveTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias NervesGate.Device
  @endpoint NervesGateWeb.Endpoint
  @moduletag :tmp_dir
  @shared %{"mode" => "shared", "equipment" => NervesGate.Config.address_defaults()}

  defmodule PanelHost do
    use Phoenix.LiveView

    def mount(_, _, socket), do: {:ok, assign(socket, panels: ["one", "two"])}

    def handle_event("remove", %{"id" => id}, socket),
      do: {:noreply, assign(socket, :panels, socket.assigns.panels -- [id])}

    def handle_event("show", _, socket), do: {:noreply, assign(socket, :panels, ["one", "two"])}

    def render(assigns) do
      ~H"""
      <div>
        <div :for={id <- @panels}>
          <.live_component module={NervesGateWeb.ConnectionPanel} id={id} kind={:ports} />
          <button phx-click="remove" phx-value-id={id}>Remove {id}</button>
        </div>
        <button phx-click="show">Show panels</button>
      </div>
      """
    end
  end

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

  test "USB-first setup validates, trials and saves separate Internet and equipment roles" do
    {:ok, view, html} = live(build_conn(), "/setup")
    assert html =~ "Keep the USB cable connected"
    refute html =~ "Both belong to the same"
    view |> element("button", "Set up connections") |> render_click()

    invalid = %{
      mode: "ethernet",
      internet_port: "eth0",
      ip_method: "static",
      static_ip: "bad",
      subnet_mask: "255.255.255.0"
    }

    assert view |> form("#network-form", network: invalid) |> render_submit() =~
             "Choose an unused manual address"

    valid = %{invalid | static_ip: "192.168.50.10"}

    assert view |> form("#network-form", network: valid) |> render_submit() =~
             "Review before changing"

    refute NervesGate.Network.status().trial
    assert view |> element("#apply-settings") |> render_click() =~ "Check the port assignments"
    refute NervesGate.Network.status().config["setup_completed"]
    html = view |> element("#confirm-settings") |> render_click()
    assert html =~ "Connection settings saved"
    assert html =~ "Remote access is not verified"
    settings = NervesGate.Network.status().config["network"]
    assert settings["equipment"]["static_ip"] == "192.168.50.10"
    assert settings["mode"] == "ethernet"
    assert Enum.all?(NervesGate.Network.status().observed.ports, &is_nil(&1.master))
    {:ok, equipment, _} = live(build_conn(), "/equipment")
    assert render(equipment) =~ "192.168.50.10"
  end

  test "shared network is an explicit warned choice" do
    {:ok, view, _} = live(build_conn(), "/setup")
    view |> element("button", "Set up connections") |> render_click()

    assert view |> form("#network-form", network: %{mode: "shared"}) |> render_change() =~
             "explicitly joins both"

    view
    |> form("#network-form",
      network: %{
        mode: "shared",
        ip_method: "static",
        static_ip: "192.168.50.2",
        subnet_mask: "255.255.255.0",
        gateway: "192.168.50.1"
      }
    )
    |> render_submit()

    assert has_element?(view, ".ui-setting-row", "Router address")
    assert has_element?(view, ".ui-setting-row", "192.168.50.1")
    refute NervesGate.Network.status().trial
    view |> element("button", "Edit settings") |> render_click()

    view
    |> form("#network-form", network: %{mode: "shared", ip_method: "dhcp"})
    |> render_change()

    assert view
           |> form("#network-form", network: %{mode: "shared", ip_method: "dhcp"})
           |> render_submit() =~ "Both ports will be joined"

    refute has_element?(view, ".ui-setting-row", "Router address")
  end

  test "trial survives browser reconnection and can be cancelled" do
    assert {:ok, %{result: %{trial_id: id}}} =
             Device.dispatch("network.propose", %{"network" => @shared})

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

  test "all product pages work offline and never claim remote readiness" do
    for {path, heading} <- [
          {"/", "Equipment access at a glance"},
          {"/equipment", "Equipment network"},
          {"/internet", "Internet &amp; backup"},
          {"/remote", "Private access"},
          {"/settings", "Setup &amp; recovery"},
          {"/setup", "A place for every connection"}
        ] do
      {:ok, _view, html} = live(build_conn(), path)
      assert html =~ heading
      refute html =~ "Remote access ready"

      if path == "/settings" do
        assert html =~ "Firmware listens on every IPv4 interface at port 4000"
        assert html =~ "Anyone who can reach this page can change settings"
        refute html =~ "EC100 uses USB only"
      end
    end
  end

  test "a CLI command and two browsers share the trial and action availability" do
    {:ok, setup, _} = live(build_conn(), "/setup")
    {:ok, dashboard, _} = live(build_conn(), "/")

    assert {:ok, %{result: %{trial_id: id}, projection: projection}} =
             Device.dispatch("network.propose", %{"network" => @shared})

    eventually(fn -> has_element?(setup, "#confirm-settings:not([disabled])") end)
    eventually(fn -> render(dashboard) =~ "Settings are being tried" end)
    assert {:ok, _} = Device.dispatch("network.confirm", %{"trial_id" => id})
    eventually(fn -> not has_element?(setup, "#confirm-settings") end)
    eventually(fn -> not (render(dashboard) =~ "Settings are being tried") end)
    Phoenix.PubSub.broadcast(NervesGate.PubSub, Device.topic(), {:device, projection})
    refute has_element?(setup, "#confirm-settings")
    refute render(dashboard) =~ "Settings are being tried"
  end

  test "an old browser click cannot confirm a newer client's trial" do
    {:ok, %{result: %{trial_id: old}}} =
      Device.dispatch("network.propose", %{"network" => @shared})

    {:ok, view, _} = live(build_conn(), "/setup")
    assert {:ok, _} = Device.dispatch("network.cancel", %{"trial_id" => old})

    {:ok, %{result: %{trial_id: current}}} =
      Device.dispatch("network.propose", %{"network" => @shared})

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

  test "visible radio choices reverse port roles and keep drafts through live observations" do
    {:ok, view, _} = live(build_conn(), "/setup")
    view |> element("button", "Set up connections") |> render_click()
    refute has_element?(view, "select")
    assert has_element?(view, "#network_internet_port-eth0:checked")
    assert has_element?(view, "label[for=network_static_ip]")
    assert has_element?(view, "#network_static_ip[aria-describedby=network_static_ip-help]")

    view
    |> form("#network-form", network: %{internet_port: "eth1", static_ip: "10.46.0.2"})
    |> render_change()

    assert has_element?(view, "#network_internet_port-eth1:checked")
    assert has_element?(view, ".ui-port-tag", "Port 1")
    Device.subscribe()

    NervesGate.Network.Host.simulate(%{
      ports: [%{name: "eth0", present: false, link: false, master: nil}]
    })

    assert_receive {:device, _}
    eventually(fn -> has_element?(view, "#setup-connections", "Not installed") end)
    assert has_element?(view, "#network_static_ip[value='10.46.0.2']")
    assert has_element?(view, "#network_internet_port-eth1:checked")
    refute NervesGate.Network.status().trial

    view |> form("#network-form") |> render_submit()
    assert has_element?(view, ".ui-setting-row", "Port 2")
    view |> element("#apply-settings") |> render_click()
    assert NervesGate.Network.status().trial.network["internet_port"] == "eth1"
  end

  test "components own deduplicated subscriptions and clean up without a subscribing parent" do
    {:ok, view, _} = live_isolated(build_conn(), PanelHost)
    topic = Device.topic()
    pid = view.pid

    subscribers = fn ->
      Enum.filter(Registry.lookup(NervesGate.PubSub, topic), fn {p, _} -> p == pid end)
    end

    assert [{^pid, [Phoenix.LiveView.PubSub | _]}] = subscribers.()

    old = Device.projection()
    assert {:ok, _} = Device.dispatch("network.propose", %{"network" => @shared})

    for id <- ["one", "two"] do
      eventually(fn -> has_element?(view, "##{id}", "Shared network") end)
    end

    Phoenix.PubSub.broadcast(NervesGate.PubSub, topic, {:device, old})
    refute has_element?(view, "#one", "Unassigned")
    refute has_element?(view, "#two", "Unassigned")

    render_click(view, "remove", %{"id" => "one"})
    refute has_element?(view, "#one")
    assert length(subscribers.()) == 1

    NervesGate.Network.Host.simulate(%{
      ports: [%{name: "eth0", present: false, link: false, master: nil}]
    })

    eventually(fn -> has_element?(view, "#two", "Not installed") end)
    render_click(view, "remove", %{"id" => "two"})
    eventually(fn -> subscribers.() == [] end)
    view |> element("button", "Show panels") |> render_click()
    assert length(subscribers.()) == 1
    assert has_element?(view, "#one", "Not installed")
    GenServer.stop(pid)
    eventually(fn -> subscribers.() == [] end)
  end

  test "navigation marks the current page" do
    for path <- ["/", "/equipment", "/internet", "/remote", "/settings"] do
      html = build_conn() |> get(path) |> response(200)
      assert html =~ "href=\"#{path}\" aria-current=\"page\""
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
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, remaining - 1)
        )
  end
end
