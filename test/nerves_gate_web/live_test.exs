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
          7
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

  test "cellular source and APN use the existing confirmation flow and update a second browser" do
    {:ok, view, _} = live(build_conn(), "/settings/network")
    {:ok, other, _} = live(build_conn(), "/settings/network")
    assert has_element?(view, "label", "Ethernet with 4G backup")
    view |> form("#network-form", network: %{internet_mode: "cellular"}) |> render_change()
    assert has_element?(view, "#network_cellular_apn")
    refute has_element?(view, "#internet-summary")

    html =
      view
      |> form("#network-form", network: %{cellular_apn: "internet.example"})
      |> render_submit()

    assert html =~ "Keep these changes?"
    assert Network.status().trial.network["eth0"] == nil
    assert Network.status().trial.network["internet"]["mode"] == "cellular"
    eventually(fn -> has_element?(other, "#confirm-settings") end)
    result = other |> element("#confirm-settings") |> render_click()
    assert {:ok, overview, _} = follow_redirect(result, build_conn(), "/")
    assert has_element?(overview, "#connection-internet", "4G modem")
    assert Network.status().config["network"]["internet"]["apn"] == "internet.example"
  end

  test "unsupported firmware explains cellular setup and rejects forged submissions" do
    Network.Host.simulate(%{cellular_supported: false, cellular: nil})
    {:ok, view, _} = live(build_conn(), "/settings/network")
    view |> form("#network-form", network: %{internet_mode: "cellular"}) |> render_change()
    assert has_element?(view, "#apply-settings[disabled]")
    assert render(view) =~ "no qualified cellular setup"

    html =
      render_submit(view, "save", %{
        "network" => %{"internet_mode" => "cellular", "cellular_apn" => "internet.example"}
      })

    assert html =~ "Cellular setup needs a qualified modem driver"
    assert Network.status().trial == nil
  end

  test "one screen detects the connected port and equipment is optional" do
    {:ok, view, html} = live(build_conn(), "/settings/network")
    assert html =~ "First setup"
    assert has_element?(view, "h1", "Network")
    assert has_element?(view, "#internet-summary", "Port 1")
    refute has_element?(view, "#internet-options")
    refute has_element?(view, "#network_equipment_ip")
    refute html =~ "Review before changing"
    refute html =~ "Mobile Internet"
    assert view |> form("#network-form") |> render_submit() =~ "Keep these changes?"
    assert Network.status().trial.network["eth1"] == nil
    assert Network.status().trial.network["eth0"]["role"] == "internet"
    refute Network.status().config["setup_completed"]
    result = view |> element("#confirm-settings") |> render_click()
    assert {:ok, overview, _} = follow_redirect(result, build_conn(), "/")

    assert has_element?(
             overview,
             "nav[aria-label='Main navigation'] a[href='/'][aria-current=page]"
           )

    assert Network.status().config["setup_completed"]

    {:ok, settings, _} = live(build_conn(), "/settings/network")
    assert has_element?(settings, "h1", "Network")
    assert has_element?(settings, "#apply-settings", "Apply changes")
  end

  test "first setup really through USB saves without a confirmation screen" do
    usb_observation()
    {:ok, view, html} = live(usb_conn(), "/settings/network")
    assert html =~ "Settings save directly"
    refute html =~ "60-second undo window"
    render_submit(form(view, "#network-form"))
    assert_redirect(view, "/")
    assert NervesGate.Network.status().config["setup_completed"]
    refute NervesGate.Network.status().trial
    {:ok, settings, html} = live(usb_conn(), "/settings/network")
    assert html =~ "60-second undo window"
    assert render_submit(form(settings, "#network-form")) =~ "Keep these changes?"
    refute NervesGate.Network.status().trial.auto_save
  end

  test "Internet uses a button and other disclosures preserve open state" do
    {:ok, view, _} = live(build_conn(), "/settings/network")

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

    {:ok, view, _} = live(conn, "/settings/network")

    render_submit(view, "save", %{
      "network" => %{"usb" => "true", "auto_save" => "true"}
    })

    assert has_element?(view, "#confirm-settings")
    refute Network.status().trial.auto_save
  end

  test "equipment addresses are validated without another review step" do
    {:ok, view, _} = live(build_conn(), "/settings/network")
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
    {:ok, view, _} = live(build_conn(), "/settings/network")

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
    {:ok, view, _} = live(build_conn(), "/settings/network")
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
    {:ok, view, _} = live(build_conn(), "/settings/network")
    assert view |> form("#network-form") |> render_submit() =~ "More than one network"
    refute Network.status().trial
    Network.Host.simulate(%{})
    eventually(fn -> has_element?(view, "#internet-summary", "Port 1") end)
    view |> form("#network-form", network: %{internet_port: ""}) |> render_submit()
    assert Network.status().trial.network == %{"mode" => "ports", "eth0" => nil, "eth1" => nil}
  end

  test "dirty draft cannot overwrite settings saved by another session" do
    {:ok, view, _} = live(build_conn(), "/settings/network")
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

    {:ok, view, _} = live(build_conn(), "/settings/network")
    assert has_element?(view, "#confirm-settings")
    assert Network.status().trial.id == id
    view |> element("button", "Restore previous settings") |> render_click()
    refute Network.status().trial
  end

  test "operations and settings pages work offline without claiming equipment reachability" do
    for {path, heading} <- [
          {"/", "Overview"},
          {"/equipment", "Equipment"},
          {"/remote", "Remote access"},
          {"/settings", "Settings"},
          {"/settings/network", "Network"},
          {"/settings/tailscale", "Tailscale"}
        ] do
      {:ok, view, html} = live(build_conn(), path)
      assert has_element?(view, "h1", heading)
      assert html =~ "This interface has no sign-in protection"
      refute html =~ "Remote access ready"
      refute html =~ "Internet &amp; backup"
    end

    for path <- ["/setup", "/internet"] do
      assert build_conn() |> get(path) |> response(404) != ""
    end
  end

  test "gateway shows three actionable summaries and keeps diagnostics collapsed" do
    {:ok, view, _} = live(build_conn(), "/")
    assert has_element?(view, "#connection-internet[href='/settings/network']")
    assert has_element?(view, "#connection-equipment[href='/equipment']", "Not configured")
    assert has_element?(view, "#connection-tailscale[href='/remote']")
    refute has_element?(view, "#connection-details[open]")
    refute has_element?(view, ".ui-hero")
  end

  test "a CLI command and two browsers share trial state; old broadcasts do not regress it" do
    {:ok, setup, _} = live(build_conn(), "/settings/network")
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

    {:ok, view, _} = live(build_conn(), "/settings/network")
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

    for path <- [
          "/",
          "/equipment",
          "/remote",
          "/settings",
          "/settings/network",
          "/settings/tailscale"
        ] do
      assert build_conn() |> get(path) |> response(200) != ""
      assert subscriptions.(self()) == []
      {:ok, view, _} = live(build_conn(), path)
      pid = view.pid
      assert [_, _, _, _, _, _, _] = subscriptions.(pid)

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

    assert [_, _, _, _, _, _, _] = subscriptions.()
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
    assert [_, _, _, _, _, _, _] = subscriptions.()
    Network.Host.simulate(%{ports: [%{name: "eth0", present: false, link: false, master: nil}]})
    eventually(fn -> has_element?(view, "#two", "Not installed") end)
    render_click(view, "remove", %{"id" => "two"})
    view |> element("button", "Show panels") |> render_click()
    assert [_, _, _, _, _, _, _] = subscriptions.()
    assert has_element?(view, "#one", "Not installed")
    GenServer.stop(pid)
    eventually(fn -> subscriptions.() == [] end)
  end

  test "navigation keeps settings selected on nested pages" do
    for {path, parent} <- [
          {"/", "/"},
          {"/equipment", "/equipment"},
          {"/remote", "/remote"},
          {"/settings", "/settings"},
          {"/settings/network", "/settings"},
          {"/settings/tailscale", "/settings"}
        ] do
      {:ok, view, _} = live(build_conn(), path)

      assert has_element?(
               view,
               "nav[aria-label='Main navigation'] a[href='#{parent}'][aria-current=page]"
             )

      refute has_element?(
               view,
               "nav[aria-label='Main navigation'] a:not([href='#{parent}'])[aria-current=page]"
             )

      if parent == "/settings",
        do:
          assert(
            has_element?(view, "nav[aria-label='Settings'] a[href='#{path}'][aria-current=page]")
          )
    end
  end

  test "equipment shows gateway observations, not an invented device inventory" do
    {:ok, view, _} = live(build_conn(), "/equipment")
    assert has_element?(view, "#equipment-connection", "No equipment connection is configured")
    refute has_element?(view, "form")
    refute has_element?(view, "button", "Discover devices")

    equipment = %{
      "role" => "equipment",
      "address" => %{
        "ip_method" => "static",
        "static_ip" => "192.168.50.10",
        "subnet_mask" => "255.255.255.0",
        "gateway" => nil
      }
    }

    {:ok, id} =
      NervesGate.network_propose(%{"mode" => "ports", "eth0" => nil, "eth1" => equipment})

    :ok = NervesGate.network_confirm(id)
    eventually(fn -> has_element?(view, "#equipment-connection", "192.168.50.10/24") end)
    assert has_element?(view, "#equipment-connection", "Gateway address on this network")
    assert has_element?(view, "#equipment-connection", "Port 2")
    assert has_element?(view, "#equipment-discovery", "not a complete inventory")
    assert has_element?(view, "#scan-equipment[disabled]")
  end

  test "equipment scan and local label editing use observations without replacing a draft" do
    address = %{
      "ip_method" => "static",
      "static_ip" => "192.168.80.2",
      "subnet_mask" => "255.255.255.0",
      "gateway" => nil
    }

    {:ok, id} = NervesGate.network_propose(%{"mode" => "shared", "equipment" => address})
    :ok = NervesGate.network_confirm(id)

    NervesGate.Equipment.Host.simulate([
      %{ip: "192.168.80.10", mac: "02:00:00:00:80:10", last_seen: nil, source: "simulated"}
    ])

    on_exit(fn -> NervesGate.Equipment.Host.simulate([]) end)
    {:ok, view, _} = live(build_conn(), "/equipment")
    view |> element("#scan-equipment") |> render_click()
    assert render_async(view) =~ "Scan completed"
    assert has_element?(view, "#equipment-discovery", "192.168.80.10")
    assert has_element?(view, "#equipment-discovery", "unknown (no activity timestamp)")
    view |> element("button", "Edit label") |> render_click()
    view |> form("#equipment-label-form", equipment: %{label: "Pump draft"}) |> render_change()
    send(view.pid, %PropertyTable.Event{property: ["equipment"], value: %{}})
    assert has_element?(view, "#equipment_label[value='Pump draft']")

    assert view
           |> form("#equipment-label-form", equipment: %{label: "Pump <A>"})
           |> render_submit() =~ "Label saved"

    assert has_element?(view, "#equipment-discovery h3", "Pump <A>")
    refute has_element?(view, "#equipment-label-form")
    [entry] = NervesGate.status().equipment.entries
    assert :ok = NervesGate.equipment_label(entry.id, "")
  end

  test "equipment handles shared topology and unavailable observations honestly" do
    {:ok, id} = NervesGate.network_propose(@shared)
    :ok = NervesGate.network_confirm(id)
    {:ok, shared, _} = live(build_conn(), "/equipment")
    assert has_element?(shared, "#equipment-connection", "Shared network · Port 1 + Port 2")
    stop_supervised!(Network)
    {:ok, unavailable, _} = live(build_conn(), "/equipment")
    assert has_element?(unavailable, "#equipment-connection", "observations are unavailable")

    refute has_element?(
             unavailable,
             "#equipment-connection",
             "No equipment connection is configured"
           )

    {:ok, overview, _} = live(build_conn(), "/")
    assert has_element?(overview, "#connection-equipment", "Unavailable")
  end

  test "pending network recovery stays accessible from every operational page" do
    views =
      for path <- ["/", "/equipment", "/remote", "/settings", "/settings/tailscale"] do
        {:ok, view, _} = live(build_conn(), path)
        view
      end

    {:ok, id} = NervesGate.network_propose(@shared)

    for view <- views do
      eventually(fn ->
        has_element?(view, "#pending-network-notice a[href='/settings/network']")
      end)
    end

    assert :ok = NervesGate.network_cancel(id)
    for view <- views, do: eventually(fn -> not has_element?(view, "#pending-network-notice") end)
  end

  test "settings index contains configuration links rather than duplicate forms" do
    {:ok, view, _} = live(build_conn(), "/settings")
    assert has_element?(view, "#settings-network[href='/settings/network']")
    assert has_element?(view, "#settings-tailscale[href='/settings/tailscale']")
    refute has_element?(view, "form")
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
