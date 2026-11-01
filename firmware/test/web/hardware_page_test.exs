defmodule NervesGateWeb.HardwarePageTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  require Phoenix.LiveViewTest
  alias NervesGateWeb.{Endpoint, NetworkForm}
  @endpoint Endpoint

  defmodule PluginComponent do
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
  defmodule PluginHost do
    use Phoenix.LiveView, layout: false

    def mount(_, _, socket) do
      if connected?(socket), do: :ok = NervesGate.Plugins.UI.join("web_ui_fixture", self())

      {:ok,
       assign(socket,
         plugin: "web_ui_fixture",
         component: if(connected?(socket), do: PluginComponent),
         connecting?: not connected?(socket),
         manager_ref: nil
       )}
    end

    defdelegate render(assigns), to: NervesGateWeb.PluginLive
    defdelegate handle_info(message, socket), to: NervesGateWeb.PluginLive
  end

  # EM300's real declaration: four RS485 ports and an expansion bus.
  @em300 "config/em300.exs"
         |> Config.Reader.read!(env: :dev, target: :em300)
         |> get_in([:nerves_gate, :board, :ports])

  setup do
    previous = Application.fetch_env(:nerves_gate, :board)
    Application.put_env(:nerves_gate, :board, %{ports: @em300})

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:nerves_gate, :board, value)
        :error -> Application.delete_env(:nerves_gate, :board)
      end
    end)

    start_supervised!({PropertyTable, name: NervesGate.Properties})
    start_supervised!(NervesGate.Hardware)
    start_supervised!(NervesGate.ProjectionServer)
    NervesGate.WebFixture.start_endpoint("hardware-page-test")
    :ok
  end

  test "Hardware lists the board's declared resources by ID, grouped by kind" do
    put_inventory(@em300)
    document = page("/hardware")
    assert Floki.text(document) =~ "Plugins configure connected equipment"

    for port <- @em300 do
      assert [_] = Floki.find(document, "#hardware-#{port.kind} a[href='/hardware/#{port.id}']")
      assert Floki.text(Floki.find(document, "#hardware-#{port.id}")) =~ port.label
    end

    assert Floki.text(Floki.find(document, "#hardware-iotrouter_expansion")) =~ "Expansion bus"

    # Routes carry board IDs; undeclared IDs return to the list.
    assert {:error, {:live_redirect, %{to: "/hardware"}}} = live("/hardware/ttyS9")

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
    assert [] = Floki.find(document, "#hardware-eth0")
    assert [_] = Floki.find(document, "#hardware-eth1")
    port = page("/hardware/eth1")
    assert [_] = Floki.find(port, "#hardware-assignment-form")
    assert [_] = Floki.find(port, "select[name='assignment[plugin]']")
    assert [] = Floki.find(port, "#application-port-form")
    reserved = page("/hardware/eth0")
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
    assert Phoenix.LiveViewTest.has_element?(view, "#plugin-ui-unavailable")
  end

  test "host renders a plugin component and cleanup terminates its LiveView before unloading" do
    # LiveViewTest links its proxy to the test; shutdown is the behavior under test.
    Process.flag(:trap_exit, true)
    unless Process.whereis(NervesGate.Plugins.UI), do: start_supervised!(NervesGate.Plugins.UI)
    {:ok, view, html} = Phoenix.LiveViewTest.live_isolated(build_conn(), PluginHost)
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

  test "hardware routes highlight Hardware navigation" do
    for path <- [
          "/hardware",
          "/hardware/eth1",
          "/hardware/ttyS1",
          "/hardware/ttyS5"
        ] do
      assert [_] =
               Floki.find(
                 page(path),
                 "nav[aria-label='Main navigation'] a[aria-current=page][href='/hardware']"
               )
    end
  end

  test "RS485 hardware offers kind-eligible plugins and no built-in protocol controls" do
    port = %{
      id: "ttyS1",
      kind: :rs485,
      label: "RS485 1",
      assignable: true,
      present: true,
      enabled: true,
      path: "/dev/ttyS1",
      gpios: %{}
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
          ports: %{"ttyS1" => %{enabled: true, plugin: "modbus_plugin"}},
          capabilities: %{
            "modbus_plugin" => [:rs485],
            "expansion_plugin" => [:iotrouter_expansion]
          },
          error: nil,
          operation: false
        },
        busy: false,
        uncertain?: false,
        outcome: nil,
        draft: nil,
        port_name: "ttyS1",
        kind: :rs485,
        title: "RS485 1",
        live_action: :port
      )
      |> Floki.parse_document!()

    assert Floki.text(document) =~ "Assigned plugin: modbus_plugin"
    assert [] = Floki.find(document, "select[name='assignment[enabled]']")
    assert [_] = Floki.find(document, "#hardware-advanced")

    assert [_] =
             Floki.find(
               document,
               "input[type='checkbox'][name='assignment[start_plugin]']:not([checked])"
             )

    assert [_] = Floki.find(document, "a[href='/plugins/modbus_plugin']")

    assert [_] =
             Floki.find(
               document,
               "select[name='assignment[plugin]'] option[value='modbus_plugin'][selected]"
             )

    assert [] =
             Floki.find(
               document,
               "select[name='assignment[plugin]'] option[value='expansion_plugin']"
             )

    assert [] =
             Floki.find(document, "[phx-click=capture], #modbus-form, input[name='modbus[unit]']")
  end

  test "assignment edits are effect-free drafts retained across refresh" do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, busy: false, uncertain?: false, draft: %{old: :review}}
    }

    params = %{"plugin" => "tailnet_subrouter", "start_plugin" => "true"}

    assert {:noreply, edited} =
             NervesGateWeb.HardwarePortLive.handle_event(
               "edit_assignment",
               %{"assignment" => params},
               socket
             )

    assert edited.assigns.assignment_form == params
    assert edited.assigns.draft == nil

    assert {:noreply, refreshed} =
             NervesGateWeb.HardwarePortLive.handle_event("refresh", %{}, edited)

    assert refreshed.assigns.assignment_form == params
  end

  test "refresh does not clear an unknown assignment outcome" do
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, busy: false, uncertain?: true}}

    assert {:noreply, refreshed} =
             NervesGateWeb.HardwarePortLive.handle_event("refresh", %{}, socket)

    assert refreshed.assigns.uncertain?

    assert {:noreply, ^refreshed} =
             NervesGateWeb.HardwarePortLive.handle_event("confirm", %{}, refreshed)
  end

  test "plugin ports configure no IP and Internet edits preserve them" do
    base = %{
      "mode" => "ports",
      "eth0" => %{"role" => "internet", "address" => NervesGate.Config.address_defaults()},
      "eth1" => nil
    }

    enabled = Map.put(base, "eth1", %{"role" => "plugin", "address" => nil})
    params = NetworkForm.from_settings(enabled, :internet)
    assert {:ok, preserved} = NetworkForm.to_network(params, [], enabled, :internet)
    assert preserved["eth1"] == enabled["eth1"]

    # Form construction is not admission: Network checks exclusive ownership.
    assert {:ok, _} =
             NetworkForm.to_network(%{params | "internet_port" => "eth1"}, [], enabled, :internet)
  end

  defp page(path), do: build_conn() |> get(path) |> html_response(200) |> Floki.parse_document!()
  defp live(path), do: Phoenix.LiveViewTest.live(build_conn(), path)

  # Change only this test's read model: every declared resource present and free.
  defp put_inventory(ports) do
    hardware = %{
      NervesGate.Hardware.unavailable()
      | available: true,
        ports: Enum.map(ports, &Map.merge(&1, %{present: true, enabled: false, gpios: %{}}))
    }

    :sys.replace_state(NervesGate.ProjectionServer, fn state ->
      %{
        state
        | projection:
            NervesGate.Projection.apply(state.projection, {:replace, :hardware, hardware})
      }
    end)
  end
end
