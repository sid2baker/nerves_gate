defmodule Scenarios.Cases.ProjectionStream do
  @moduledoc false
  import ExUnit.Assertions
  alias NervesGate.{Projection, ProjectionServer}
  alias Scenarios.Qemu, as: Qemu

  alias NervesGateWeb.{
    NetworkEditor,
    NetworkForm,
    Observations,
    SettingsLive,
    TailscaleLive
  }

  alias Phoenix.LiveView.{Lifecycle, Socket}

  # Restart and distribution-loss checks reserve the whole bench.
  def spec,
    do: %{
      :name =>
        "UI reducers follow the device stream, survive restart and reconnect, and keep drafts",
      :devices => :all,
      requires: %{device: [], fixture: [:qemu]}
    }

  def run(%{device: vm}) do
    assert Scenarios.Device.status(vm).system.node == vm.node
    assert ProjectionServer.snapshot({ProjectionServer, vm.node}).status.system.node == vm.node

    for service <- [NervesGate.Network, ProjectionServer, Tailscaled.Supervisor],
        do: assert(Process.whereis(service) == nil)

    for app <- [:tailscaled_ex, :nerves_runtime, :vintage_net],
        do: refute(app in Application.spec(:nerves_gate, :applications))

    assert_http_pages(vm)

    clients =
      for editor <- [:network, :lan, :ports, :remote, :settings],
          do: spawn_link(fn -> client(editor, {ProjectionServer, vm.node}) end)

    try do
      initial = converged(vm, clients)
      assert initial.status.system.target == "x86_64"
      assert initial.status.system.node == vm.node
      assert {:ok, _} = Jason.encode(initial.status)
      assert Process.whereis(ProjectionServer) == nil

      Qemu.network(vm, %{cables: %{lan1: false}})

      Scenarios.Device.await(vm, "both projections observe cable loss", fn _ ->
        Enum.all?(clients, fn pid ->
          state = client_state(pid)

          Enum.any?(
            state.projection.status.connections.ports,
            &match?(%{name: "eth0", link: false}, &1)
          )
        end)
      end)

      converged(vm, clients)
      Qemu.network(vm, %{cables: %{lan1: true}})
      Scenarios.Device.await(vm, "cable restored", &Scenarios.Device.addressed?/1)
      converged(vm, clients)
      assert_drafts(clients)

      old_server = client_state(hd(clients)).server
      assert node(old_server) == vm.node
      Scenarios.Device.rpc(vm, Process, :exit, [old_server, :kill])

      Scenarios.Device.await(vm, "UI clients resubscribe after server restart", fn _ ->
        Enum.all?(clients, fn pid ->
          state = client_state(pid)
          state.server != nil and state.server != old_server and state.disconnects > 0
        end)
      end)

      before = converged(vm, clients)
      for pid <- clients, do: send(pid, {:projection, old_server, {:replace, :system, %{}}})
      assert converged(vm, clients).inputs.system == before.inputs.system
      assert_drafts(clients)

      disconnects = Map.new(clients, &{&1, client_state(&1).disconnects})
      assert Node.disconnect(vm.node)

      Scenarios.Device.await(vm, "UI clients resubscribe after distribution disconnect", fn _ ->
        Enum.all?(clients, fn pid ->
          state = client_state(pid)
          state.server != nil and state.disconnects > disconnects[pid]
        end)
      end)

      converged(vm, clients)
      assert_drafts(clients)
    after
      Qemu.network(vm, %{cables: %{lan1: true}})
      for pid <- clients, do: send(pid, :stop)
    end

    Scenarios.Device.await(vm, "server releases dead subscribers", fn _ ->
      state = Scenarios.Device.rpc(vm, :sys, :get_state, [ProjectionServer])
      Enum.all?(clients, &(not Map.has_key?(state.clients, &1)))
    end)
  end

  # Called by the real, unenrolled Tailscale scenario after its private URL is ready.

  # Real pages from the device's own Endpoint, through the bench's management
  # forward. That peer is not USB and must never count as USB management access.
  # The device serves the release UI; it has no development pages.
  defp assert_http_pages(vm) do
    device = Req.new(base_url: Qemu.ui_url(vm), retry: false)
    assert Req.get!(device, url: "/tests").status == 404

    for path <- [
          "/",
          "/network",
          "/network/details",
          "/equipment/lan/1",
          "/equipment/lan/2",
          "/remote",
          "/settings",
          "/distribution"
        ] do
      response = Req.get!(device, url: path)
      assert response.status == 200
      assert response.body =~ "data-phx-main"
      refute response.body =~ "Use a trusted network."
      refute response.body =~ "Network changes have a 60-second undo window."
      refute response.body =~ "Configure equipment addressing under"
      refute response.body =~ ~s(href="/tests")

      if path == "/network" do
        page = Floki.parse_document!(response.body)

        assert [_] = Floki.find(page, "#main-content > #internet-editor")

        if Floki.find(page, "#network-form") == [] do
          assert [_] = Floki.find(page, "#internet-change-setup")
          assert [_] = Floki.find(page, "a[href='/network/details']")
          assert Floki.find(page, "#internet-uplink-summary h2") |> Floki.text() == "Internet"
        else
          assert [_] =
                   Floki.find(page, "#network-form input[name='network[internet_mode]'][checked]")

          assert Floki.text(Floki.find(page, "#network-form")) =~ "Internet source"
        end

        assert [] =
                 Floki.find(
                   page,
                   "#advanced-network, [name='network[mode]'], [name='network[shared_ip]']"
                 )

        assert [] =
                 Floki.find(
                   page,
                   "[name='network[equipment_port]'], [name='network[equipment_ip]']"
                 )
      end

      if path == "/network/details" do
        page = Floki.parse_document!(response.body)
        assert [_] = Floki.find(page, "#internet-settings-editor #network-form")

        assert [] =
                 Floki.find(
                   page,
                   "#internet-settings-editor details, #internet-settings-editor summary"
                 )
      end

      if path == "/equipment/lan/2" do
        page = Floki.parse_document!(response.body)
        assert [_] = Floki.find(page, "#equipment-network-form")
        assert [] = Floki.find(page, "[name='network[internet_port]']")
      end

      if path == "/remote" do
        page = Floki.parse_document!(response.body)
        assert [_] = Floki.find(page, "#gateway-remote-access ~ #tailscale-settings")
        assert [_] = Floki.find(page, "#gateway-remote-access #tailscale-details")
        assert [] = Floki.find(page, "details#tailscale-details, #tailscale-login-popup")
        assert [_] = Floki.find(page, "#remote-method option[value='auth_key']")
      end

      if path == "/settings" do
        page = Floki.parse_document!(response.body)
        assert [_] = Floki.find(page, "#lan-ports-form")
        assert [_, _] = Floki.find(page, "#lan-ports-form [name='network[mode]']")
        assert [] = Floki.find(page, "#lan-ports-form [name='network[internet_port]']")
        assert response.body =~ "x86_64"
        assert response.body =~ "SSH access"
        assert response.body =~ "ssh-key-form"
      end
    end
  end

  defp converged(vm, clients) do
    Scenarios.Device.await(vm, "client reducers equal the device reducer", fn _ ->
      projection = NervesGate.ProjectionServer.snapshot({ProjectionServer, vm.node})
      Enum.all?(clients, &(client_state(&1).projection == projection))
    end)

    NervesGate.ProjectionServer.snapshot({ProjectionServer, vm.node})
  end

  defp assert_drafts(clients) do
    for pid <- clients do
      state = client_state(pid)
      assert state.dirty

      assert state.draft in [
               "192.0.2.123",
               "10.44.0.123",
               "shared",
               "unsaved-gateway",
               "unsaved-public-key"
             ]

      assert state.operations > 0
    end
  end

  # Real UI subscription hooks and editor callbacks against the real QEMU.
  # Only the browser transport is omitted; no hardware or domain is simulated.
  defp client(editor, source) do
    socket =
      %Socket{transport_pid: self(), private: %{lifecycle: %Lifecycle{}, live_temp: %{}}}
      |> Phoenix.LiveView.clear_flash()

    refresh =
      case editor do
        editor when editor in [:network, :lan, :ports] -> &NetworkEditor.refresh_observations/2
        :remote -> &TailscaleLive.refresh_observations/2
        :settings -> &Phoenix.Component.assign(&1, :projection, &2)
      end

    socket = Observations.subscribe(socket, refresh, source)
    socket = draft(socket, editor)
    assert_pending_reply(socket, editor)
    client_loop(socket, editor, 0, 0)
  end

  # An unrelated operation queued before a command reply must not complete or
  # abandon the editor's pending save against an unchanged domain snapshot.
  defp assert_pending_reply(socket, editor) when editor in [:network, :lan, :ports] do
    socket = Phoenix.Component.assign(socket, own_save: true, saving_network: socket.assigns.base)
    updated = NetworkEditor.refresh_observations(socket, socket.assigns.projection)
    assert updated.assigns.own_save
    assert updated.assigns.dirty
  end

  defp assert_pending_reply(socket, :remote) do
    socket = Phoenix.Component.assign(socket, pending_name: "unsaved-gateway")
    updated = TailscaleLive.refresh_observations(socket, socket.assigns.projection)
    assert updated.assigns.pending_name == "unsaved-gateway"
    assert updated.assigns.dirty
  end

  defp assert_pending_reply(_, :settings), do: :ok

  defp draft(socket, :settings) do
    {:ok, socket} = SettingsLive.mount(%{}, %{}, socket)

    {:noreply, socket} =
      SettingsLive.handle_event(
        "key-draft",
        %{"ssh" => %{"public_key" => "unsaved-public-key"}},
        socket
      )

    Phoenix.Component.assign(socket, :dirty, true)
  end

  defp draft(socket, editor) when editor in [:network, :lan, :ports] do
    settings = socket.assigns.projection.network.desired

    {editor, field, value} =
      case editor do
        :network -> {:internet, "internet_ip", "192.0.2.123"}
        :lan -> {{:equipment, "eth1"}, "equipment_ip", "10.44.0.123"}
        :ports -> {:ports, "mode", "shared"}
      end

    params = NetworkForm.from_settings(settings, editor) |> Map.put(field, value)

    Phoenix.Component.assign(socket,
      editor: editor,
      form: Phoenix.Component.to_form(params, as: :network),
      base: settings,
      dirty: true,
      own_save: false,
      saving_network: nil,
      initial: false
    )
  end

  defp draft(socket, :remote) do
    Phoenix.Component.assign(socket,
      form: Phoenix.Component.to_form(%{"hostname" => "unsaved-gateway"}, as: :remote),
      base: socket.assigns.projection.remote.hostname,
      dirty: true,
      pending_name: nil,
      request: nil,
      login_open: false,
      login_url: nil,
      login_requested: false
    )
  end

  defp client_loop(socket, editor, disconnects, operations) do
    receive do
      :stop ->
        :ok

      {:state, from, ref} ->
        fields = %{
          network: "internet_ip",
          lan: "equipment_ip",
          ports: "mode",
          remote: "hostname",
          settings: "public_key"
        }

        form = if editor == :settings, do: socket.assigns.key_form, else: socket.assigns.form
        draft = form.params[Map.fetch!(fields, editor)]

        send(
          from,
          {ref,
           %{
             projection: socket.assigns.projection_state,
             server: socket.assigns.projection_server,
             disconnects: disconnects,
             operations: operations,
             draft: draft,
             dirty: socket.assigns.dirty
           }}
        )

        client_loop(socket, editor, disconnects, operations)

      message ->
        available = socket.assigns.projection.device.available
        {:halt, socket} = Lifecycle.handle_info(message, socket)
        lost = available and not socket.assigns.projection.device.available

        if lost do
          assert socket.assigns.projection_state == Projection.disconnected()

          assert Enum.all?(socket.assigns.projection.actions, fn {_, action} ->
                   not action.enabled
                 end)
        end

        client_loop(
          socket,
          editor,
          disconnects + if(lost, do: 1, else: 0),
          operations + if(match?({:projection, _, _}, message), do: 1, else: 0)
        )
    end
  end

  defp client_state(pid) do
    ref = make_ref()
    send(pid, {:state, self(), ref})
    assert_receive {^ref, state}, 10_000
    state
  end
end
