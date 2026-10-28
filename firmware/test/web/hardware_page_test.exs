defmodule NervesGateWeb.HardwarePageTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  require Phoenix.LiveViewTest
  alias NervesGateWeb.{Endpoint, NetworkForm}
  @endpoint Endpoint

  defmodule AppComponent do
    use Phoenix.LiveComponent
    def mount(socket), do: {:ok, assign(socket, :count, 0)}

    def render(assigns) do
      ~H"""
      <button id="app-counter" phx-click="count" phx-target={@myself}>App count: {@count}</button>
      """
    end

    def handle_event("count", _, socket),
      do: {:noreply, assign(socket, :count, socket.assigns.count + 1)}
  end

  # Exercise the actual host renderer and close callback without a hardware backend.
  defmodule AppHost do
    use Phoenix.LiveView, layout: false

    def mount(_, _, socket) do
      if connected?(socket), do: :ok = NervesGate.Plugins.UI.join("web_ui_fixture", self())

      {:ok,
       assign(socket,
         app: "web_ui_fixture",
         component: if(connected?(socket), do: AppComponent),
         connecting?: not connected?(socket),
         manager_ref: nil
       )}
    end

    defdelegate render(assigns), to: NervesGateWeb.PluginLive
    defdelegate handle_info(message, socket), to: NervesGateWeb.PluginLive
  end

  setup do
    previous = Application.get_env(:nerves_gate, Endpoint)

    Application.put_env(:nerves_gate, Endpoint,
      server: false,
      secret_key_base: Base.encode64(:crypto.strong_rand_bytes(64)),
      live_view: [signing_salt: "hardware-page-test"]
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:nerves_gate, Endpoint, previous),
        else: Application.delete_env(:nerves_gate, Endpoint)
    end)

    start_supervised!(NervesGate.ProjectionServer)
    start_supervised!(Endpoint)
    :ok
  end

  test "Hardware keeps all fixed ports visible without topology or local address editors" do
    document = page("/hardware")
    assert Floki.text(document) =~ "Applications configure connected equipment"

    for path <- ["/hardware/lan/1", "/hardware/lan/2", "/hardware/rs485/1", "/hardware/can/2"],
        do: assert(Floki.find(document, "a[href='#{path}']") != [])

    assert [] = Floki.find(document, "#ethernet-arrangement, #lan-ports-editor, #lan-ports-form")

    assert [_] =
             Floki.find(
               document,
               "nav[aria-label='Main navigation'] a[aria-current=page][href='/hardware']"
             )

    # Change only this test's read model, never a Network process or actual interface.
    configured =
      NervesGate.Config.from_network(%{
        "mode" => "ports",
        "eth0" => %{"role" => "internet", "address" => NervesGate.Config.address_defaults()},
        "eth1" => nil
      })

    :sys.replace_state(NervesGate.ProjectionServer, fn state ->
      network = %{
        config: configured,
        trial: nil,
        observed: nil,
        cellular: NervesGate.Cellular.empty(),
        error: nil,
        recovering: false,
        ready: false,
        phase: :idle,
        sharing_admission: :ok
      }

      %{
        state
        | projection: NervesGate.Projection.apply(state.projection, {:replace, :network, network})
      }
    end)

    document = page("/hardware")
    assert [] = Floki.find(document, "#hardware-lan-1")
    assert [_] = Floki.find(document, "#hardware-lan-2")
    port = page("/hardware/lan/2")
    assert [_] = Floki.find(port, "#hardware-assignment-form")
    assert [_] = Floki.find(port, "select[name='assignment[plugin]']")
    assert [] = Floki.find(port, "#application-port-form")
    reserved = page("/hardware/lan/1")
    assert [_] = Floki.find(reserved, "#hardware-reserved")
    assert [] = Floki.find(reserved, "#hardware-assignment-form")

    assert [] =
             Floki.find(
               port,
               "input[name='network[equipment_ip]'], input[name='network[shared_ip]'], #local-network-sharing"
             )
  end

  test "Overview has one Remote access destination; storage administration belongs to Settings" do
    document = page("/")
    assert [_] = Floki.find(document, "#connection-internet")
    assert [_] = Floki.find(document, "#connection-remote[href='/remote']")
    assert [] = Floki.find(document, "#connection-distribution, #connection-storage")
    settings = page("/settings")
    assert [_] = Floki.find(settings, "#storage-settings a[href='/settings/storage']")
    assert [] = Floki.find(settings, "#lan-ports-form")
    storage = page("/settings/storage")

    assert [_] =
             Floki.find(
               storage,
               "nav[aria-label='Main navigation'] a[aria-current=page][href='/settings']"
             )
  end

  test "application routes use the management shell and fail closed without a running UI" do
    index = page("/plugins")
    assert [_] = Floki.find(index, "nav a[aria-current=page][href='/plugins']")
    assert Floki.text(index) =~ "Plugin management unavailable"
    {:ok, view, html} = Phoenix.LiveViewTest.live(build_conn(), "/plugins/not_installed")
    assert html =~ "Plugin page unavailable"
    refute html =~ "phx-target=\"1\""
    assert Phoenix.LiveViewTest.has_element?(view, "#app-ui-unavailable")
  end

  test "host renders an app component and cleanup terminates its LiveView before unloading" do
    # LiveViewTest links its proxy to the test; shutdown is the behavior under test.
    Process.flag(:trap_exit, true)
    unless Process.whereis(NervesGate.Plugins.UI), do: start_supervised!(NervesGate.Plugins.UI)
    {:ok, view, html} = Phoenix.LiveViewTest.live_isolated(build_conn(), AppHost)
    assert html =~ "App count: 0"

    assert view
           |> Phoenix.LiveViewTest.element("#app-counter")
           |> Phoenix.LiveViewTest.render_click() =~ "App count: 1"

    assert :ok = NervesGate.Plugins.UI.close("web_ui_fixture")
    refute Process.alive?(view.pid)
  end

  test "remote access keeps credentials hidden" do
    document = page("/remote")
    assert [_] = Floki.find(document, "#tailscale-settings")
    assert [_] = Floki.find(document, "#erlang-distribution")
    assert [] = Floki.find(document, "#distribution-cookie")
  end

  test "hardware routes expose resources without equipment configuration forms" do
    for path <- ["/hardware", "/hardware/lan/1", "/hardware/rs485/1", "/hardware/can/1"] do
      document = page(path)

      assert [_] =
               Floki.find(
                 document,
                 "nav[aria-label='Main navigation'] a[aria-current=page][href='/hardware']"
               )

      assert [] =
               Floki.find(
                 document,
                 "#equipment-label-form, #modbus-form, #equipment-network-form, input[name='network[equipment_ip]']"
               )
    end
  end

  test "replaced routes have no aliases" do
    for path <- [
          "/equipment",
          "/equipment/lan/1",
          "/equipment/rs485/1",
          "/equipment/can/1",
          "/distribution",
          "/storage"
        ] do
      assert Phoenix.Router.route_info(NervesGateWeb.Router, "GET", path, "localhost") == :error
    end
  end

  test "serial hardware offers assignments and no built-in protocol or capture controls" do
    port = %{
      name: "ttyS3",
      transport: "rs485",
      present: true,
      enabled: true,
      profile: "9600 8N1",
      claimed: true,
      subscribers: 0
    }

    hardware = %{
      available: true,
      simulated: false,
      ports: [port],
      operation: nil,
      error: nil,
      result: nil
    }

    document =
      Phoenix.LiveViewTest.render_component(&NervesGateWeb.HardwarePortLive.render/1,
        projection: %{hardware: hardware},
        hardware: %{
          ports: %{"ttyS3" => %{enabled: true, plugin: "modbus_plugin"}},
          capabilities: %{"modbus_plugin" => [:serial]},
          error: nil,
          operation: false
        },
        busy: false,
        uncertain?: false,
        outcome: nil,
        draft: nil,
        port_name: "ttyS3",
        title: "RS485 1",
        live_action: :rs485
      )
      |> Floki.parse_document!()

    assert Floki.text(document) =~ "Assigned plugin: modbus_plugin"

    assert [_] =
             Floki.find(
               document,
               "select[name='assignment[plugin]'] option[value='modbus_plugin'][selected]"
             )

    assert [] =
             Floki.find(document, "[phx-click=capture], #modbus-form, input[name='modbus[unit]']")
  end

  test "removed equipment actions cannot trigger protocol requests or label writes" do
    socket =
      %Phoenix.LiveView.Socket{private: %{live_temp: %{}}} |> Phoenix.LiveView.clear_flash()

    assert {:noreply, ^socket} =
             NervesGateWeb.HardwarePortLive.handle_event("modbus-read", %{}, socket)

    assert {:noreply, ^socket} =
             NervesGateWeb.HardwarePortLive.handle_event(
               "edit-label",
               %{"id" => "anything"},
               socket
             )
  end

  test "application enablement configures no IP and Internet edits preserve it" do
    base = %{
      "mode" => "ports",
      "eth0" => %{"role" => "internet", "address" => NervesGate.Config.address_defaults()},
      "eth1" => nil
    }

    enabled = Map.put(base, "eth1", %{"role" => "application", "address" => nil})
    params = NetworkForm.from_settings(enabled, :internet)
    assert {:ok, preserved} = NetworkForm.to_network(params, [], enabled, :internet)
    assert preserved["eth1"] == enabled["eth1"]

    # Form construction is not admission: Network checks exclusive ownership.
    assert {:ok, _} =
             NetworkForm.to_network(%{params | "internet_port" => "eth1"}, [], enabled, :internet)

    assert {:error, _} =
             NetworkForm.to_network(%{"enabled" => "true"}, [], base, {:application, "eth0"})
  end

  test "removed joined and equipment forms cannot submit network settings" do
    base = %{
      "mode" => "ports",
      "eth0" => nil,
      "eth1" => nil,
      "internet" => %{"mode" => "cellular", "apn" => ""}
    }

    for editor <- [:ports, {:equipment, "eth1"}, {:application, "eth1"}] do
      assert {:error, _} =
               NetworkForm.to_network(
                 %{"mode" => "shared", "enabled" => "true"},
                 [],
                 base,
                 editor
               )
    end
  end

  defp page(path), do: build_conn() |> get(path) |> html_response(200) |> Floki.parse_document!()
end
