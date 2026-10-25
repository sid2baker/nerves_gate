defmodule NervesGateWeb.NetworkEditorTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]
  alias NervesGate.Cellular.Providers
  alias NervesGateWeb.{NetworkEditor, NetworkForm}

  @base %{"mode" => "ports", "eth0" => nil, "eth1" => nil}

  test "source choices depend on detected hardware, not unlocked SIM or registration" do
    for {present, supported} <- [{false, true}, {nil, true}, {true, false}] do
      document =
        projection(@base, present, supported)
        |> socket()
        |> Phoenix.Component.assign(step: 1)
        |> page()

      assert [_] = Floki.find(document, "input[value=cellular][disabled]")
      assert [_] = Floki.find(document, "input[value=backup][disabled]")
      assert [_] = Floki.find(document, "input[value=ethernet]:not([disabled])")
    end

    document = projection(@base) |> socket() |> Phoenix.Component.assign(step: 1) |> page()
    assert [_] = Floki.find(document, "input[value=cellular]:not([disabled])")
  end

  test "configured overview is compact, with a settings link rather than expanders" do
    document = projection(cellular("")) |> socket() |> page()
    assert [_] = Floki.find(document, "#internet-uplink-summary")
    assert [_] = Floki.find(document, "a[href='/network/details']")
    assert [_] = Floki.find(document, "#internet-change-setup")
    assert [] = Floki.find(document, "details, summary, #network-form, input[name=username]")
  end

  test "a PIN is requested before any change to the currently applied LAN source" do
    projection = put_in(projection(@base).cellular.sim, :pin_required)
    socket = socket(projection)
    {:noreply, socket} = NetworkEditor.handle_event("start-setup", %{}, socket)

    {:noreply, socket} =
      NetworkEditor.handle_event("save", %{"network" => %{"internet_mode" => "cellular"}}, socket)

    document = page(socket)
    assert socket.assigns.step == 2
    assert socket.assigns.projection.network.desired == @base
    refute socket.assigns.own_save
    assert [_] = Floki.find(document, "form[phx-submit=unlock-connect]")
    assert [] = Floki.find(document, "#network-form input[type=password]")

    assert [] =
             Floki.find(
               document,
               "input[name='network[cellular_apn]'], input[name=username], details"
             )

    {:noreply, blocked} = NetworkEditor.handle_event("save", %{"network" => %{}}, socket)
    assert blocked.assigns.message =~ "Unlock the SIM before connecting"
    refute blocked.assigns.own_save
    assert blocked.assigns.saving_network == nil
  end

  test "Continue for LAN/backup preserves drafts and never applies settings" do
    socket = socket(projection(@base))
    {:noreply, socket} = NetworkEditor.handle_event("start-setup", %{}, socket)

    {:noreply, socket} =
      NetworkEditor.handle_event(
        "save",
        %{"network" => %{"internet_mode" => "backup", "internet_port" => "eth1"}},
        socket
      )

    refute socket.assigns.own_save
    assert socket.assigns.step == 2
    assert socket.assigns.form.params["internet_port"] == "eth1"
    {:noreply, socket} = NetworkEditor.handle_event("back", %{}, socket)
    assert socket.assigns.form.params["internet_mode"] == "backup"
    {:noreply, socket} = NetworkEditor.handle_event("finish-setup", %{}, socket)
    assert socket.assigns.step == 0
    assert socket.assigns.form.params["internet_mode"] == "ethernet"
  end

  test "a readiness observation alone never saves a draft" do
    original = projection(@base)
    socket = socket(original) |> Phoenix.Component.assign(step: 2, dirty: true)

    {:noreply, socket} =
      NetworkEditor.handle_event(
        "change",
        %{"network" => %{"internet_mode" => "cellular"}},
        socket
      )

    ready = put_in(original.cellular.sim, :ready)
    {:ok, updated} = NetworkEditor.update(%{projection: ready}, socket)
    assert updated.assigns.message == nil
    assert updated.assigns.saving_network == nil
    assert updated.assigns.form.params["internet_mode"] == "cellular"
  end

  test "only the exact accepted unlock completion continues once; failures do not apply" do
    original = projection(cellular(""))

    socket =
      socket(original) |> Phoenix.Component.assign(step: 2, dirty: true, awaiting_unlock: 701)

    ready =
      original
      |> put_in([:cellular, :sim], :ready)
      |> put_in([:cellular, :result], %{operation: :unlock, id: 700, error: nil})

    {:ok, unchanged} = NetworkEditor.update(%{projection: ready}, socket)
    assert unchanged.assigns.awaiting_unlock == 701
    assert unchanged.assigns.saving_network == nil

    failed =
      put_in(ready.cellular.result, %{operation: :unlock, id: 701, error: %{message: "No retry."}})

    {:ok, stopped} = NetworkEditor.update(%{projection: failed}, socket)
    assert stopped.assigns.awaiting_unlock == nil
    assert stopped.assigns.saving_network == nil

    # There is deliberately no Network process on the host: an attempted apply
    # reports unavailable rather than touching a modem or inventing a mock driver.
    completed = put_in(ready.cellular.result, %{operation: :unlock, id: 701, error: nil})
    {:ok, continued} = NetworkEditor.update(%{projection: completed}, socket)
    assert continued.assigns.awaiting_unlock == nil
    assert continued.assigns.saving_network == cellular("")
    assert is_binary(continued.assigns.message)
    continued = Phoenix.Component.assign(continued, message: "No replay")
    {:ok, repeated} = NetworkEditor.update(%{projection: completed}, continued)
    assert repeated.assigns.message == "No replay"
  end

  test "disconnect and editing cancel continuation without replaying a PIN" do
    original = projection(cellular(""))

    socket =
      socket(original) |> Phoenix.Component.assign(step: 2, dirty: true, awaiting_unlock: 701)

    disconnected = Map.put(original, :device, %{available: false})
    {:ok, stopped} = NetworkEditor.update(%{projection: disconnected}, socket)
    assert stopped.assigns.awaiting_unlock == nil

    {:noreply, edited} =
      NetworkEditor.handle_event("change", %{"network" => %{"internet_mode" => "backup"}}, socket)

    assert edited.assigns.awaiting_unlock == nil
    assert edited.assigns.saving_network == nil
  end

  test "credential events clear fields and never put submitted secrets into assigns" do
    for {event, params} <- [
          {"unlock", %{"pin" => "private-pin"}},
          {"unlock-connect", %{"pin" => "private-pin"}},
          {"save_pin", %{"pin" => "private-pin"}},
          {"save_authentication",
           %{
             "apn" => "private.example",
             "username" => "private-user",
             "password" => "private-password"
           }}
        ] do
      socket = socket(projection(cellular(""))) |> Phoenix.Component.assign(step: 2)
      {:noreply, updated} = NetworkEditor.handle_event(event, params, socket)
      assert updated.assigns.generation == 1
      assert updated.assigns.awaiting_unlock == nil

      for secret <- ["private-pin", "private-user", "private-password"],
          do: refute(inspect(updated.assigns) =~ secret)
    end
  end

  test "connection settings show manual fields directly, while normal setup has none" do
    projection = projection(cellular("private.example")) |> put_in([:cellular, :sim], :ready)
    normal = projection |> socket() |> Phoenix.Component.assign(step: 2) |> page()

    assert [] =
             Floki.find(
               normal,
               "details, input[name='network[cellular_apn]'], form[phx-submit=save_authentication]"
             )

    settings = projection |> socket(true) |> page()

    assert [_] =
             Floki.find(settings, "input[name='network[cellular_apn]'][value='private.example']")

    assert [_] = Floki.find(settings, "form[phx-submit=save_authentication]")

    assert [] =
             Floki.find(
               settings,
               "details, summary, input[name=username][value], input[name=password][value]"
             )

    assert [_] = Floki.find(settings, "#internet-lan-status")
  end

  test "carrier name selection preserves a stable profile, not just a shared APN" do
    options =
      Providers.resolve(
        {:ok, ["262010000000001"]},
        {:error, :unsupported},
        {:ok, [~s(+CRSM: 144,0,"00000002")]}
      ).options

    option = Enum.find(options, &(&1["name"] == "Congstar"))
    original = NetworkForm.from_settings(cellular(""), :internet)
    selected = Map.put(original, "cellular_profile", "provider:" <> option["id"])
    selected = NetworkForm.defaults_for_change(selected, original, :internet, nil)
    assert selected["cellular_apn"] == option["apn"]
    assert {:ok, network} = NetworkForm.to_network(selected, [], @base, :internet)
    assert network["internet"]["provider"] == option["id"]

    assert NetworkForm.from_settings(network, :internet)["cellular_profile"] ==
             selected["cellular_profile"]

    automatic =
      NetworkForm.defaults_for_change(
        Map.put(selected, "cellular_profile", "auto"),
        selected,
        :internet,
        nil
      )

    assert automatic["cellular_apn"] == ""
    assert {:ok, cleared} = NetworkForm.to_network(automatic, [], @base, :internet)
    refute Map.has_key?(cleared["internet"], "provider")
    assert cleared["internet"]["apn"] == ""
    refute inspect(network) =~ "password"
    refute inspect(network) =~ "username"
  end

  test "observations and trial confirmation preserve drafts and rollback safety" do
    original = projection(cellular(""))
    socket = socket(original) |> Phoenix.Component.assign(step: 2, dirty: true)

    {:noreply, socket} =
      NetworkEditor.handle_event(
        "change",
        %{"network" => %{"internet_mode" => "backup", "internet_port" => "eth1"}},
        socket
      )

    trial = %{
      id: "test-trial",
      auto_save: false,
      expires_at: System.system_time(:millisecond) + 60_000,
      network: cellular("")
    }

    pending = put_in(original.network.pending, trial)
    {:ok, socket} = NetworkEditor.update(%{projection: pending}, socket)
    assert socket.assigns.form.params["internet_port"] == "eth1"
    assert [_] = Floki.find(page(socket), "#confirm-settings:not([disabled])")
    {:noreply, unchanged} = NetworkEditor.handle_event("finish-setup", %{}, socket)
    assert unchanged.assigns.step == 2
    assert unchanged.redirected == nil
  end

  defp page(socket),
    do:
      render_component(
        &NetworkEditor.render/1,
        Map.put(socket.assigns, :myself, %Phoenix.LiveComponent.CID{cid: 1})
      )
      |> Floki.parse_document!()

  defp cellular(apn), do: Map.put(@base, "internet", %{"mode" => "cellular", "apn" => apn})

  defp socket(projection, settings \\ false) do
    {:ok, socket} =
      NetworkEditor.update(
        %{
          id: "internet-editor",
          editor: :internet,
          projection: projection,
          access: nil,
          settings: settings
        },
        %Phoenix.LiveView.Socket{}
      )

    socket
  end

  defp projection(network, present \\ true, supported \\ true) do
    observed = %{
      cellular: %{present: present, connection: :unknown, addresses: [], apn: ""},
      bridge: nil,
      ports: [],
      usb: nil
    }

    actions =
      Map.new(
        ~w(network.propose network.confirm cellular.unlock cellular.refresh cellular.save_pin cellular.forget_pin cellular.save_authentication cellular.forget_authentication cellular.reconnect),
        &{&1, %{enabled: true}}
      )

    %{
      network: %{
        desired: network,
        observed: observed,
        available: true,
        setup_completed: true,
        pending: nil,
        recovering: false,
        error: nil
      },
      cellular:
        Map.merge(NervesGate.Cellular.empty(), %{
          supported: supported,
          present: present,
          enabled: NervesGate.Config.cellular?(network)
        }),
      connections: %{
        mode: network["mode"],
        ports: [],
        suggested_internet_port: nil,
        problems: [],
        cellular: observed.cellular,
        internet: %{
          mode: NervesGate.Config.internet(network)["mode"],
          selected: nil,
          ethernet: :unknown,
          cellular: :unknown
        }
      },
      capabilities: %{mobile: supported},
      actions: actions
    }
  end
end
