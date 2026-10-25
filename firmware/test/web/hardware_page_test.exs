defmodule NervesGateWeb.HardwarePageTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  require Phoenix.LiveViewTest
  alias NervesGateWeb.{Endpoint, NetworkForm}
  @endpoint Endpoint

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
    assert Floki.text(document) =~ "Internet uplink"
    assert [_] = Floki.find(document, "#hardware-lan-1")
    assert [_] = Floki.find(document, "#hardware-lan-2")
    port = page("/hardware/lan/2")
    assert [_] = Floki.find(port, "#application-port-form")
    assert [_, _] = Floki.find(port, "input[name='network[enabled]']")

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

  test "remote and legacy distribution addresses share a credential-hidden workspace" do
    for path <- ["/remote", "/distribution"] do
      document = page(path)
      assert [_] = Floki.find(document, "#tailscale-settings")
      assert [_] = Floki.find(document, "#erlang-distribution")
      assert [] = Floki.find(document, "#distribution-cookie")
    end
  end

  test "legacy hardware links remain usable without equipment configuration forms" do
    for path <- ["/equipment", "/hardware/lan/1", "/equipment/rs485/1", "/hardware/can/1"] do
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

  test "claimed serial hardware disables administrative use and has no protocol editor" do
    port = %{
      name: "ttyS3",
      transport: "rs485",
      present: true,
      enabled: true,
      profile: "9600 8N1",
      claimed: true,
      subscribers: 0
    }

    buses = %{
      available: true,
      simulated: false,
      ports: [port],
      operation: nil,
      error: nil,
      result: nil
    }

    document =
      Phoenix.LiveViewTest.render_component(&NervesGateWeb.BusesLive.render/1,
        projection: %{buses: buses},
        forms: %{},
        port_name: "ttyS3",
        title: "RS485 1",
        live_action: :rs485
      )
      |> Floki.parse_document!()

    assert Floki.text(document) =~ "In use by applications"
    assert [_] = Floki.find(document, "#configure-ttyS3 button[type=submit][disabled]")
    assert [_] = Floki.find(document, "#capture-ttyS3[disabled]")
    assert [] = Floki.find(document, "#modbus-form, input[name='modbus[unit]']")
  end

  test "removed equipment actions cannot trigger protocol requests or label writes" do
    socket =
      %Phoenix.LiveView.Socket{private: %{live_temp: %{}}} |> Phoenix.LiveView.clear_flash()

    assert {:noreply, rejected} = NervesGateWeb.BusesLive.handle_event("modbus-read", %{}, socket)
    assert rejected.assigns.flash["error"] =~ "hardware diagnostic action"

    assert {:noreply, ^socket} =
             NervesGateWeb.LanLive.handle_event("edit-label", %{"id" => "anything"}, socket)
  end

  test "application enablement configures no IP and Internet edits preserve it" do
    base = %{
      "mode" => "ports",
      "eth0" => %{"role" => "internet", "address" => NervesGate.Config.address_defaults()},
      "eth1" => nil
    }

    assert {:ok, enabled} =
             NetworkForm.to_network(%{"enabled" => "true"}, [], base, {:application, "eth1"})

    assert enabled["eth1"] == %{"role" => "application", "address" => nil}
    params = NetworkForm.from_settings(enabled, :internet)
    assert {:ok, preserved} = NetworkForm.to_network(params, [], enabled, :internet)
    assert preserved["eth1"] == enabled["eth1"]

    assert {:error, _} =
             NetworkForm.to_network(%{params | "internet_port" => "eth1"}, [], enabled, :internet)

    assert {:error, _} =
             NetworkForm.to_network(%{"enabled" => "true"}, [], base, {:application, "eth0"})
  end

  test "joining local Ethernet preserves 4G policy and requires no Internet route" do
    base = %{
      "mode" => "ports",
      "eth0" => nil,
      "eth1" => nil,
      "internet" => %{"mode" => "cellular", "apn" => ""}
    }

    params = NetworkForm.from_settings(base, :ports)

    params =
      Map.merge(params, %{
        "mode" => "shared",
        "shared_method" => "static",
        "shared_ip" => "192.168.10.2",
        "shared_mask" => "255.255.255.0",
        "shared_gateway" => "",
        "shared_dns" => ""
      })

    assert {:ok, network} = NetworkForm.to_network(params, [], base, :ports)
    assert network["internet"] == base["internet"]
    assert network["mode"] == "shared"
    assert network["equipment"]["gateway"] == nil
  end

  defp page(path), do: build_conn() |> get(path) |> html_response(200) |> Floki.parse_document!()
end
