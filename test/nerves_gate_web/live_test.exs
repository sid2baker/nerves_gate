defmodule NervesGateWeb.LiveTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias NervesGate.Network
  @endpoint NervesGateWeb.Endpoint
  @shared %{"mode" => "shared", "equipment" => NervesGate.Config.address_defaults()}

  defmodule PanelHost do
    use Phoenix.LiveView

    def mount(_, _, socket) do
      socket = NervesGateWeb.Observations.subscribe(socket, &__MODULE__.refresh/1)
      {:ok, socket |> assign(panels: ["one", "two"]) |> refresh()}
    end

    def refresh(socket), do: assign(socket, projection: NervesGate.status())

    def handle_event("remove", %{"id" => id}, socket),
      do: {:noreply, assign(socket, :panels, socket.assigns.panels -- [id])}

    def handle_event("show", _, socket), do: {:noreply, assign(socket, :panels, ["one", "two"])}

    def render(assigns) do
      ~H"""
      <div>
        <div :for={id <- @panels}>
          <.live_component module={NervesGateWeb.ConnectionPanel} id={id} projection={@projection} />
          <button phx-click="remove" phx-value-id={id}>Remove {id}</button>
        </div>
        <button phx-click="show">Show panels</button>
      </div>
      """
    end
  end

  setup do
    Supervisor.terminate_child(NervesGate.Supervisor, Network)
    Network.Host.reset()
    start_supervised!({Network, poll_ms: 10})

    on_exit(fn ->
      Network.Host.reset()
      Supervisor.restart_child(NervesGate.Supervisor, Network)
    end)

    :ok
  end

  test "connected views retry failed subscriptions after a domain becomes available" do
    stop_supervised!(Network)
    {:ok, view, _} = live(build_conn(), "/")
    start_supervised!({Network, poll_ms: 10})
    registry = PropertyTable.Supervisor.registry_name(NervesGate.Observations.table())

    eventually(
      fn ->
        Enum.count(Registry.lookup(registry, :subscriptions), fn {pid, _} -> pid == view.pid end) ==
          4
      end,
      200
    )

    assert Process.alive?(view.pid)
  end

  test "saved offline settings do not label a detected cable as the Internet port" do
    offline = %{"mode" => "ports", "eth0" => nil, "eth1" => nil}

    {:ok, id} = NervesGate.network_propose(offline)

    :ok = NervesGate.network_confirm(id)

    Network.Host.simulate(%{
      ports: [
        %{
          name: "eth0",
          present: true,
          link: true,
          master: nil,
          method: "disabled",
          state: :configured,
          addresses: [%{address: "192.0.2.10", prefix_length: 24}]
        }
      ]
    })

    eventually(fn -> NervesGate.status().connections.suggested_internet_port == "eth0" end)
    {:ok, view, _} = live(build_conn(), "/")
    refute has_element?(view, "#connection-internet", "Port 1")
    assert has_element?(view, "#connection-internet", "Choose an Internet connection")
  end

  test "one screen detects the connected port and equipment is optional" do
    {:ok, view, html} = live(build_conn(), "/setup")
    assert html =~ "Set up your gateway"
    assert has_element?(view, "#internet-summary", "Port 1")
    refute has_element?(view, "#internet-options")
    refute has_element?(view, "#network_equipment_ip")
    refute html =~ "Review before changing"
    refute html =~ "Mobile Internet"
    assert view |> form("#network-form") |> render_submit() =~ "Keep these changes?"
    assert Network.status().trial.network["eth1"] == nil
    assert Network.status().trial.network["eth0"]["role"] == "internet"
    refute Network.status().config["setup_completed"]
    view |> element("#confirm-settings") |> render_click()
    assert_redirect(view, "/")
    assert Network.status().config["setup_completed"]
    assert {:error, {:live_redirect, %{to: "/settings"}}} = live(build_conn(), "/setup")
    {:ok, settings, _} = live(build_conn(), "/settings")
    assert has_element?(settings, "h1", "Network")
    assert has_element?(settings, "#apply-settings", "Apply changes")
  end

  test "first setup really through USB saves without a confirmation screen" do
    usb_observation()
    {:ok, view, html} = live(usb_conn(), "/setup")
    assert html =~ "Settings save directly"
    refute html =~ "60-second undo window"
    render_submit(form(view, "#network-form"))
    assert_redirect(view, "/")
    assert NervesGate.Network.status().config["setup_completed"]
    refute NervesGate.Network.status().trial
    {:ok, settings, html} = live(usb_conn(), "/settings")
    assert html =~ "60-second undo window"
    assert render_submit(form(settings, "#network-form")) =~ "Keep these changes?"
    refute NervesGate.Network.status().trial.auto_save
  end

  test "Internet uses a button and other disclosures preserve open state" do
    {:ok, view, _} = live(build_conn(), "/setup")

    assert has_element?(
             view,
             "button.ui-button--secondary[aria-controls=internet-options][aria-expanded=false]",
             "Change Internet connection"
           )

    refute has_element?(view, "#internet-options")
    view |> element("button", "Change Internet connection") |> render_click()
    assert has_element?(view, "#internet-options")

    for id <- ["advanced-network", "connection-details"] do
      assert has_element?(view, "##{id}[phx-mounted*=ignore_attrs]")
    end

    view |> form("#network-form", network: %{internet_method: "static"}) |> render_change()
    assert has_element?(view, "#network_internet_ip[value='192.0.2.10']")
    assert has_element?(view, "#internet-options")
    view |> element("button", "Add equipment") |> render_click()
    assert has_element?(view, "#network_equipment_ip[value='192.168.10.2']")
  end

  test "USB present and forged browser hints do not bypass confirmation over LAN" do
    usb_observation()

    conn =
      build_conn()
      |> Plug.Conn.put_req_header("x-forwarded-for", "10.13.0.2")
      |> put_connect_params(%{"usb" => true, "local_address" => "10.13.0.1"})

    {:ok, view, _} = live(conn, "/setup")

    render_submit(view, "save", %{
      "network" => %{"usb" => "true", "auto_save" => "true"}
    })

    assert has_element?(view, "#confirm-settings")
    refute Network.status().trial.auto_save
  end

  test "equipment addresses are validated without another review step" do
    {:ok, view, _} = live(build_conn(), "/setup")
    view |> element("button", "Add equipment") |> render_click()
    assert has_element?(view, "label[for=network_equipment_ip]")
    assert has_element?(view, "#network_equipment_ip[aria-describedby=network_equipment_ip-help]")

    assert view |> form("#network-form", network: %{equipment_ip: "bad"}) |> render_submit() =~
             "Equipment needs an unused manual address"

    refute Network.status().trial
    view |> form("#network-form", network: %{equipment_ip: "192.168.50.10"}) |> render_submit()
    assert Network.status().trial.network["eth1"]["address"]["static_ip"] == "192.168.50.10"
    view |> element("#confirm-settings") |> render_click()
    assert_redirect(view, "/")
    {:ok, equipment, _} = live(build_conn(), "/")
    assert render(equipment) =~ "192.168.50.10"
  end

  test "shared network remains an explicit warned advanced choice and supports manual DNS" do
    {:ok, view, _} = live(build_conn(), "/setup")

    assert view |> form("#network-form", network: %{mode: "shared"}) |> render_change() =~
             "Both Ethernet ports will be joined"

    view |> form("#network-form", network: %{shared_method: "static"}) |> render_change()

    view
    |> form("#network-form",
      network: %{
        shared_ip: "192.168.50.2",
        shared_gateway: "192.168.50.1",
        shared_dns: "1.1.1.1, 9.9.9.9"
      }
    )
    |> render_submit()

    assert Network.status().trial.network["equipment"]["nameservers"] == ["1.1.1.1", "9.9.9.9"]
    assert Network.status().trial.network["equipment"]["gateway"] == "192.168.50.1"
  end

  test "live discovery updates suggestions without overwriting explicit choices or equipment drafts" do
    {:ok, view, _} = live(build_conn(), "/setup")
    ports = Network.status().observed.ports

    changed = [
      %{hd(ports) | link: false, addresses: []},
      %{
        List.last(ports)
        | link: true,
          addresses: [%{address: "10.3.0.2", prefix_length: 24}],
          connection: :internet
      }
    ]

    Network.Host.simulate(%{ports: changed})
    eventually(fn -> has_element?(view, "#internet-summary", "Port 2 · Internet connected") end)
    view |> element("button", "Change Internet connection") |> render_click()
    view |> form("#network-form", network: %{internet_port: "eth0"}) |> render_change()
    view |> element("button", "Add equipment") |> render_click()
    view |> form("#network-form", network: %{equipment_ip: "10.46.0.2"}) |> render_change()
    Network.Host.simulate(%{})
    eventually(fn -> has_element?(view, "#internet-summary", "Port 1") end)
    assert has_element?(view, "#network_equipment_ip[value='10.46.0.2']")
    assert has_element?(view, "#network_internet_port-eth0:checked")
    refute Network.status().trial
  end

  test "two connected networks need a choice, including the option to finish offline" do
    ports =
      Enum.map(Network.status().observed.ports, fn port ->
        %{
          port
          | link: true,
            addresses: [
              %{
                address: if(port.name == "eth0", do: "10.1.0.2", else: "10.2.0.2"),
                prefix_length: 24
              }
            ],
            connection: :internet
        }
      end)

    Network.Host.simulate(%{ports: ports})
    eventually(fn -> NervesGate.status().connections.suggested_internet_port == nil end)
    {:ok, view, _} = live(build_conn(), "/setup")
    assert view |> form("#network-form") |> render_submit() =~ "More than one network"
    refute Network.status().trial
    Network.Host.simulate(%{})
    eventually(fn -> has_element?(view, "#internet-summary", "Port 1") end)
    view |> form("#network-form", network: %{internet_port: ""}) |> render_submit()
    assert Network.status().trial.network == %{"mode" => "ports", "eth0" => nil, "eth1" => nil}
  end

  test "dirty draft cannot overwrite settings saved by another session" do
    {:ok, view, _} = live(build_conn(), "/settings")
    view |> element("button", "Change Internet connection") |> render_click()
    view |> form("#network-form", network: %{internet_port: "eth1"}) |> render_change()

    {:ok, id} = NervesGate.network_propose(@shared)

    assert :ok = NervesGate.network_confirm(id)
    eventually(fn -> has_element?(view, "#apply-settings[disabled]") end)

    render_submit(view, "save", %{
      "network" => %{"internet_port" => "eth1"}
    })

    refute Network.status().trial
    assert render(view) =~ "Settings changed in another session"
    view |> element("button", "Reload saved settings") |> render_click()
    assert has_element?(view, "#network_mode-shared:checked")
    refute has_element?(view, "#apply-settings[disabled]")
  end

  test "trial survives browser reconnection and can be cancelled" do
    {:ok, id} = NervesGate.network_propose(@shared)

    {:ok, view, _} = live(build_conn(), "/settings")
    assert has_element?(view, "#confirm-settings")
    assert Network.status().trial.id == id
    view |> element("button", "Restore previous settings") |> render_click()
    refute Network.status().trial
  end

  test "three product pages work offline without claiming equipment reachability" do
    for {path, heading} <- [
          {"/", "Gateway"},
          {"/remote", "Tailscale"},
          {"/settings", "Set up your gateway"},
          {"/setup", "Set up your gateway"}
        ] do
      {:ok, view, html} = live(build_conn(), path)
      assert has_element?(view, "h1", heading)
      assert html =~ "This interface has no sign-in protection"
      refute html =~ "Remote access ready"
      refute html =~ "Internet &amp; backup"
    end

    for path <- ["/equipment", "/internet"] do
      assert {:error, {:live_redirect, %{to: "/settings"}}} = live(build_conn(), path)
    end
  end

  test "gateway shows three actionable summaries and keeps diagnostics collapsed" do
    {:ok, view, _} = live(build_conn(), "/")
    assert has_element?(view, "#connection-internet[href='/settings']")
    assert has_element?(view, "#connection-equipment[href='/settings']", "Not configured")
    assert has_element?(view, "#connection-tailscale[href='/remote']")
    refute has_element?(view, "#connection-details[open]")
    refute has_element?(view, ".ui-hero")
  end

  test "a CLI command and two browsers share trial state; old broadcasts do not regress it" do
    {:ok, setup, _} = live(build_conn(), "/setup")
    {:ok, dashboard, _} = live(build_conn(), "/")

    {:ok, id} = NervesGate.network_propose(@shared)
    projection = NervesGate.status()

    eventually(fn -> has_element?(setup, "#confirm-settings:not([disabled])") end)
    eventually(fn -> render(dashboard) =~ "Network changes are not saved yet" end)
    assert :ok = NervesGate.network_confirm(id)
    eventually(fn -> not has_element?(setup, "#confirm-settings") end)
    eventually(fn -> not (render(dashboard) =~ "Network changes are not saved yet") end)

    for view <- [setup, dashboard],
        do: send(view.pid, %PropertyTable.Event{property: ["network"], value: projection})

    refute has_element?(setup, "#confirm-settings")
    refute render(dashboard) =~ "Network changes are not saved yet"
  end

  test "an old browser click cannot confirm a newer client's trial" do
    {:ok, old} = NervesGate.network_propose(@shared)

    {:ok, view, _} = live(build_conn(), "/setup")
    assert :ok = NervesGate.network_cancel(old)

    {:ok, current} = NervesGate.network_propose(@shared)

    assert render_click(view, "confirm", %{"trial_id" => old}) =~ "This trial has ended"
    assert NervesGate.status().network.pending.id == current
    refute NervesGate.status().network.setup_completed
  end

  test "connected LiveViews use only property subscriptions and death cleans them up" do
    registry = PropertyTable.Supervisor.registry_name(NervesGate.Observations.table())

    subscriptions = fn pid ->
      Enum.filter(Registry.lookup(registry, :subscriptions), fn {p, _} -> p == pid end)
    end

    for path <- ["/", "/setup", "/remote"] do
      assert build_conn() |> get(path) |> response(200) != ""
      assert subscriptions.(self()) == []
      {:ok, view, _} = live(build_conn(), path)
      pid = view.pid
      assert [_, _, _, _] = subscriptions.(pid)

      for topic <- ["network:events", "remote:events"] do
        assert [] ==
                 Registry.lookup(NervesGate.PubSub, topic)
                 |> Enum.filter(fn {subscriber, _} -> subscriber == pid end)
      end

      GenServer.stop(pid)

      eventually(fn ->
        Registry.keys(NervesGate.PubSub, pid) == [] and subscriptions.(pid) == []
      end)
    end
  end

  test "connection panels share their parent's observed view without extra subscriptions" do
    {:ok, view, _} = live_isolated(build_conn(), PanelHost)
    pid = view.pid
    registry = PropertyTable.Supervisor.registry_name(NervesGate.Observations.table())

    subscriptions = fn ->
      Registry.lookup(registry, :subscriptions) |> Enum.filter(fn {p, _} -> p == pid end)
    end

    assert [_, _, _, _] = subscriptions.()
    old = NervesGate.status()
    assert {:ok, _} = NervesGate.network_propose(@shared)

    for id <- ["one", "two"] do
      eventually(fn -> has_element?(view, "##{id}", "Shared network") end)
    end

    send(pid, %PropertyTable.Event{property: ["network"], value: old})
    refute has_element?(view, "#one", "Unassigned")
    refute has_element?(view, "#two", "Unassigned")
    render_click(view, "remove", %{"id" => "one"})
    refute has_element?(view, "#one")
    assert [_, _, _, _] = subscriptions.()
    Network.Host.simulate(%{ports: [%{name: "eth0", present: false, link: false, master: nil}]})
    eventually(fn -> has_element?(view, "#two", "Not installed") end)
    render_click(view, "remove", %{"id" => "two"})
    view |> element("button", "Show panels") |> render_click()
    assert [_, _, _, _] = subscriptions.()
    assert has_element?(view, "#one", "Not installed")
    GenServer.stop(pid)
    eventually(fn -> subscriptions.() == [] end)
  end

  test "navigation marks the current page" do
    for path <- ["/", "/remote", "/settings"] do
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

  defp usb_observation do
    Network.Host.simulate(%{
      usb: %{present: true, link: true, addresses: [%{address: "10.13.0.1", prefix_length: 30}]}
    })

    eventually(fn ->
      Network.Access.usb?(NervesGate.status().network.observed, %{
        local: "10.13.0.1",
        peer: {10, 13, 0, 2}
      })
    end)
  end

  defp usb_conn do
    conn = build_conn()
    {adapter, payload} = conn.adapter

    %{
      conn
      | adapter:
          {adapter,
           %{
             payload
             | sock_data: %{address: {10, 13, 0, 1}, port: 4000},
               peer_data: %{address: {10, 13, 0, 2}, port: 5000, ssl_cert: nil}
           }}
    }
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
