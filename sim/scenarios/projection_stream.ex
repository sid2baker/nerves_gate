defmodule NervesGateSim.Scenarios.ProjectionStream do
  @moduledoc false
  import ExUnit.Assertions
  alias NervesGate.{Projection, ProjectionServer}
  alias NervesGateSim.TestQemu, as: Qemu

  alias NervesGateWeb.{
    DistributionLive,
    NetworkEditor,
    NetworkForm,
    Observations,
    SettingsLive,
    TailscaleLive
  }

  alias Phoenix.LiveView.{Lifecycle, Socket}

  # The workstation UI's backend is VM-wide, so this scenario holds every device.
  def spec,
    do: %{
      :name =>
        "UI reducers follow the device stream, survive restart and reconnect, and keep drafts",
      :devices => :all
    }

  def run(%{device: vm}) do
    # Select the device exactly as mix dev.ui does for the in-process UI checks.
    Application.put_env(:nerves_gate, :backend_node, vm.node)

    try do
      check(vm)
    after
      Application.delete_env(:nerves_gate, :backend_node)
    end
  end

  defp check(vm) do
    assert Qemu.status(vm).system.node == vm.node
    assert_runtime_backend(vm)
    assert_remote_events()
    assert_discovery_observations(vm)
    assert_http_pages(vm)
    assert_distribution_cookie_cached()
    assert_network_forms(vm)
    assert_settings_commands()
    assert_remote_ui()

    clients =
      for editor <- [:network, :lan, :ports, :remote, :settings],
          do: spawn_link(fn -> client(editor) end)

    try do
      initial = converged(vm, clients)
      assert initial.status.system.target == "x86_64"
      assert initial.status.system.node == vm.node
      assert {:ok, _} = Jason.encode(initial.status)
      assert Process.whereis(ProjectionServer) == nil

      Qemu.network(vm, %{cables: %{lan1: false}})

      Qemu.await(vm, "both projections observe cable loss", fn _ ->
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
      Qemu.await(vm, "cable restored", &NervesGateSim.ScenarioHelpers.addressed?/1)
      converged(vm, clients)
      assert_drafts(clients)

      old_server = client_state(hd(clients)).server
      assert node(old_server) == vm.node
      :erpc.call(vm.node, Process, :exit, [old_server, :kill])

      Qemu.await(vm, "UI clients resubscribe after server restart", fn _ ->
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

      Qemu.await(vm, "UI clients resubscribe after distribution disconnect", fn _ ->
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

    Qemu.await(vm, "server releases dead subscribers", fn _ ->
      state = :erpc.call(vm.node, :sys, :get_state, [ProjectionServer])
      Enum.all?(clients, &(not Map.has_key?(state.clients, &1)))
    end)
  end

  defp assert_discovery_observations(vm) do
    projection = NervesGate.ProjectionServer.snapshot({ProjectionServer, vm.node})
    network = projection.inputs.network

    # Pure interpretation regression: two observed uplinks are online even when
    # discovery correctly refuses to suggest one role. No device state is changed.
    ports =
      Enum.map(network.observed.ports, fn port ->
        address = if port.name == "eth0", do: "192.0.2.15", else: "198.51.100.15"

        %{
          port
          | present: true,
            link: true,
            connection: :internet,
            addresses: [%{address: address, prefix_length: 24}]
        }
      end)

    network = %{
      network
      | config: NervesGate.Config.defaults(),
        trial: nil,
        observed: %{network.observed | ports: ports}
    }

    status = Projection.apply(projection, {:replace, :network, network}).status
    assert status.connections.internet.health == "online"
    assert status.connections.internet.link
    assert status.connections.internet.addressed
    assert status.connections.internet.selected == nil
    assert status.connections.suggested_internet_port == nil

    page =
      %{__changed__: nil, projection: status}
      |> NervesGateWeb.DashboardLive.render()
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()
      |> Floki.parse_document!()

    card = page |> Floki.find("#connection-internet") |> Floki.text()
    assert card =~ "Online"
    refute card =~ "Not connected"

    [lan1, lan2] = ports

    waiting = [
      %{lan1 | link: false, connection: :disconnected, addresses: []},
      %{lan2 | connection: :unknown, addresses: []}
    ]

    network = %{network | observed: %{network.observed | ports: waiting}}
    status = Projection.apply(projection, {:replace, :network, network}).status
    assert status.connections.internet.link
    refute status.connections.internet.addressed
    assert status.connections.internet.health == "unverified"
  end

  @doc false
  def assert_bench_controls(vm) do
    bench = put_in(NervesGateSim.QemuTests.snapshot(), [:devices, vm.id, :owner], :manual)

    id = Atom.to_string(vm.id)

    page =
      %{
        __changed__: nil,
        projection: NervesGate.ProjectionServer.snapshot({ProjectionServer, vm.node}).status,
        id: id,
        error: nil,
        confirm_run: nil
      }
      |> Map.merge(DevWeb.DeviceLive.bench_assigns(bench, id))
      |> DevWeb.DeviceLive.render()
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()
      |> Floki.parse_document!()

    for id <- ~w(connect_lan1 connect_lan2 connect_off lan1_down lan2_down) do
      assert [_] = Floki.find(page, "#manual-#{id}")
    end

    for {port, network} <- bench.devices[vm.id].topology do
      text = page |> Floki.find("#bench-#{port}-network") |> Floki.text()

      assert text ==
               if(network == :internet, do: "Internet router", else: "Isolated equipment network")
    end
  end

  @doc false
  def assert_remote_events do
    # A dirty domain avoids scheduling a timer in this protocol-routing check.
    state = %{dirty: MapSet.new([:system])}

    event =
      {Tailscaled, ["auth", "state"], :needs_login, :authenticating,
       %{old_timestamp: 1, new_timestamp: 2}}

    assert {:noreply, updated} = ProjectionServer.handle_info(event, state)
    assert updated.dirty == MapSet.new([:system, :remote, :network])
  end

  @doc false
  def assert_remote_ui do
    socket = remote_socket()
    projection = socket.assigns.projection

    projection = %{
      projection
      | remote_access: %{
          projection.remote_access
          | state: "offline",
            available: true,
            auth_state: "needs_login",
            operation: nil,
            error: nil
        }
    }

    socket = Phoenix.Component.assign(socket, projection: projection, request: :connect)
    page = remote_page(socket)
    assert [_] = Floki.find(page, "#tailscale-save[disabled][aria-busy='true'] .ui-spinner")

    socket = Phoenix.Component.assign(socket, request: nil)

    {:noreply, keyed} =
      TailscaleLive.handle_event("method", %{"remote" => %{"method" => "auth_key"}}, socket)

    page = remote_page(keyed)
    assert [_] = Floki.find(page, "input[type='password'][name='remote[auth_key]'][value='']")

    assert [] =
             Floki.find(page, "#tailscale-form[phx-change], input[type='password'][phx-change]")

    # The device rejects a stale submission before any write; the page never retains a key.
    stale = Phoenix.Component.assign(keyed, base: "not-the-current-hostname")
    secret = "tskey-auth-ui-test-only"

    {:noreply, rejected} =
      TailscaleLive.handle_event(
        "save",
        %{"remote" => %{"hostname" => "gateway", "auth_key" => secret}},
        stale
      )

    assert rejected.assigns.key_revision == keyed.assigns.key_revision + 1
    refute inspect(rejected.assigns) =~ secret
    refute inspect(Phoenix.Logger.filter_values(%{"remote" => %{"auth_key" => secret}})) =~ secret
    assert Phoenix.Flash.get(rejected.assigns.flash, :error)

    waiting = Phoenix.Component.assign(socket, request: :connect, login_requested: true)

    starting = %{
      projection
      | remote_access: %{projection.remote_access | operation: "connect", auth_state: "stopped"}
    }

    starting = TailscaleLive.refresh_observations(waiting, starting)
    assert starting.assigns.login_requested
    assert starting.assigns.request == :connect

    failed = put_in(projection.remote_access.auth_state, "error")
    failed = TailscaleLive.refresh_observations(waiting, failed)
    assert failed.assigns.request == nil
    refute failed.assigns.login_requested
    assert Phoenix.Flash.get(failed.assigns.flash, :error)

    notifications =
      NervesGateWeb.CoreComponents.notifications(%{__changed__: nil, flash: failed.assigns.flash})
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()
      |> Floki.parse_document!()

    assert [_] =
             Floki.find(
               notifications,
               "#notification-error[role='alert'] button[phx-click='lv:clear-flash']"
             )

    saving = Phoenix.Component.assign(socket, request: :configure, pending_name: "gateway")

    configuring = %{
      projection
      | remote_access: %{
          projection.remote_access
          | state: "online",
            hostname: "gateway",
            operation: "configure"
        }
    }

    saving = TailscaleLive.refresh_observations(saving, configuring)
    assert saving.assigns.request == :configure
    saved = put_in(configuring.remote_access.operation, nil)
    saved = TailscaleLive.refresh_observations(saving, saved)
    assert saved.assigns.request == nil
    assert Phoenix.Flash.get(saved.assigns.flash, :info) == "Device name saved."
  end

  # Called by the real, unenrolled Tailscale scenario after its private URL is ready.
  @doc false
  def assert_remote_sign_in(vm) do
    # The simulator has no global gateway backend. Keep the snapshot and private
    # login query on the same selected guest without changing application config.
    projection_state = NervesGateWeb.Backend.projection(vm.node)

    observer =
      Phoenix.Component.assign(remote_socket(),
        projection_backend: vm.node,
        projection_state: projection_state,
        projection: projection_state.status
      )

    projection = observer.assigns.projection
    previous = put_in(projection.remote_access.operation, "connect")

    requester =
      Phoenix.Component.assign(observer,
        projection: previous,
        request: :connect,
        login_requested: true
      )

    disconnected = Phoenix.Component.assign(requester, :projection_backend, nil)
    disconnected = TailscaleLive.refresh_observations(disconnected, projection)
    private = disconnected.assigns.login_url == nil and not disconnected.assigns.login_open
    assert private

    ready = TailscaleLive.refresh_observations(requester, projection)
    url = ready.assigns.login_url

    # Only assert booleans here: failed assertions must not print the private URL/HTML.
    available = is_binary(url) and ready.assigns.login_open and ready.assigns.request == nil
    assert available
    page = remote_page(ready)
    link = Floki.find(page, "#tailscale-login-dialog[role='dialog'] #tailscale-login-link")
    linked = Floki.attribute(link, "href") == [url] and Floki.text(link) == url
    assert linked

    safe =
      :binary.match(
        :erlang.term_to_binary(Map.take(ready.assigns, [:projection, :flash, :form])),
        url
      ) == :nomatch

    assert safe

    {:noreply, closed} = TailscaleLive.handle_event("close-login", %{}, ready)
    # Another changed observation rechecks the same URL without reopening the popup.
    changed = put_in(projection.remote_access.version, "changed-observation")
    closed = TailscaleLive.refresh_observations(closed, changed)
    refute closed.assigns.login_open
    {:noreply, reopened} = TailscaleLive.handle_event("show-login", %{}, closed)
    assert reopened.assigns.login_open

    observer = TailscaleLive.refresh_observations(observer, changed)
    assert observer.assigns.login_url == nil
    refute observer.assigns.login_open

    online = %{
      projection
      | remote_access: %{projection.remote_access | state: "online", auth_state: "authenticated"}
    }

    connected = TailscaleLive.refresh_observations(reopened, online)
    assert connected.assigns.login_url == nil
    refute connected.assigns.login_open
    assert Phoenix.Flash.get(connected.assigns.flash, :info) == "Connected to Tailscale."
  end

  defp remote_socket do
    socket =
      %Socket{private: %{lifecycle: %Lifecycle{}, live_temp: %{}}}
      |> Phoenix.LiveView.clear_flash()

    {:ok, socket} = TailscaleLive.mount(%{}, %{}, socket)
    socket
  end

  defp remote_page(socket) do
    socket.assigns
    |> TailscaleLive.render()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
    |> Floki.parse_document!()
  end

  defp assert_runtime_backend(vm) do
    assert NervesGateWeb.Backend.projection().status.system.node == vm.node

    assert :erpc.call(vm.node, NervesGateWeb.Backend, :projection, []).status.system.node ==
             vm.node

    assert Process.whereis(NervesGate.Network) == nil
    assert Process.whereis(ProjectionServer) == nil
    assert Process.whereis(Tailscaled.Supervisor) == nil
    # Compiled for the host, but never started there.
    for app <- [:tailscaled_ex, :nerves_runtime, :vintage_net],
        do: refute(app in Application.spec(:nerves_gate, :applications))

    backend = Application.fetch_env!(:nerves_gate, :backend_node)

    try do
      Application.put_env(:nerves_gate, :backend_node, nil)
      refute NervesGateWeb.Backend.projection().status.backend.available
      assert {:error, :unavailable} = NervesGateWeb.Backend.subscribe_projection()
      assert {:error, %{code: "outcome_unknown"}} = NervesGateWeb.Backend.identify()
    after
      Application.put_env(:nerves_gate, :backend_node, backend)
    end

    # The same compiled host code immediately selects the real device again.
    assert NervesGateWeb.Backend.projection().status.system.node == vm.node
  end

  # Real pages from the device's own Endpoint, through the bench's management
  # forward. That peer is not USB and must never count as USB management access.
  # The device serves the release UI; it has no development pages.
  defp assert_http_pages(vm) do
    device = Req.new(base_url: Qemu.ui_url(vm), retry: false)
    assert Req.get!(device, url: "/tests").status == 404

    for path <- [
          "/",
          "/network",
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

        assert [_] =
                 Floki.find(
                   page,
                   "#main-content > #network-connections ~ #internet-editor #network-form"
                 )

        assert [] = Floki.find(page, "details #network-connections")

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

        assert Floki.find(page, "#network-connections h2") |> Floki.text() == "Your connections"
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

  @doc false
  def assert_network_forms(vm) do
    status = Qemu.status(vm)
    base = status.network.desired
    ports = status.connections.ports
    equipment = {:equipment, "eth1"}
    params = NetworkForm.from_settings(base, equipment)
    params = Map.merge(params, %{"enabled" => "true", "equipment_ip" => "10.44.0.1"})
    assert {:ok, with_equipment} = NetworkForm.to_network(params, ports, base, equipment)
    assert with_equipment["eth0"] == base["eth0"]
    assert with_equipment["internet"] == base["internet"]
    assert with_equipment["eth1"]["role"] == "equipment"

    internet = NetworkForm.from_settings(with_equipment, :internet)
    refute Map.has_key?(internet, "equipment_ip")
    assert {:ok, unchanged} = NetworkForm.to_network(internet, ports, with_equipment, :internet)
    assert unchanged == with_equipment

    assert {:error, _} =
             NetworkForm.to_network(
               Map.put(internet, "internet_port", "eth1"),
               ports,
               with_equipment,
               :internet
             )

    assert {:error, _} = NetworkForm.to_network(params, ports, base, {:equipment, "eth0"})
    assert {:error, _} = NetworkForm.to_network(params, ports, %{"mode" => "shared"}, equipment)

    cellular = Map.put(with_equipment, "internet", %{"mode" => "backup", "apn" => "test.apn"})

    assert {:ok, without_equipment} =
             NetworkForm.to_network(%{"enabled" => "false"}, ports, cellular, equipment)

    assert without_equipment["eth1"] == nil
    assert without_equipment["eth0"] == base["eth0"]
    assert without_equipment["internet"] == cellular["internet"]
    assert_port_forms(with_equipment, ports)

    for {editor, field, value, foreign_field} <- [
          {:internet, "internet_ip", "192.0.2.123", "equipment_ip"},
          {equipment, "equipment_ip", "10.44.0.123", "internet_port"},
          {:ports, "mode", "shared", "internet_port"}
        ] do
      assigns = %{id: "draft-check", editor: editor, projection: status, access: %{}}
      assert {:ok, socket} = NetworkEditor.update(assigns, %Socket{})

      assert {:noreply, socket} =
               NetworkEditor.handle_event(
                 "change",
                 %{"network" => %{field => value, foreign_field => "must-not-be-accepted"}},
                 socket
               )

      assert {:ok, socket} = NetworkEditor.update(assigns, socket)
      assert socket.assigns.form.params[field] == value
      refute Map.has_key?(socket.assigns.form.params, foreign_field)
      assert socket.assigns.dirty
    end
  end

  defp assert_port_forms(base, ports) do
    params = NetworkForm.from_settings(base, :ports)
    assert {:ok, ^base} = NetworkForm.to_network(params, ports, base, :ports)
    refute Map.has_key?(params, "internet_mode")

    params = Map.put(params, "mode", "shared")
    assert {:ok, shared} = NetworkForm.to_network(params, ports, base, :ports)
    assert shared["mode"] == "shared"
    assert shared["equipment"] == base["eth0"]["address"]
    assert shared["internet"] == base["internet"]

    # Internet cannot change the arrangement or the joined-network address.
    internet = NetworkForm.from_settings(shared, :internet)
    refute Map.has_key?(internet, "mode")
    refute Map.has_key?(internet, "shared_ip")
    forged = Map.merge(internet, %{"mode" => "ports", "shared_ip" => "192.0.2.123"})
    assert {:ok, ^shared} = NetworkForm.to_network(forged, ports, shared, :internet)

    backup = Map.merge(internet, %{"internet_mode" => "backup", "cellular_apn" => "test.apn"})
    assert {:ok, with_backup} = NetworkForm.to_network(backup, ports, shared, :internet)
    assert with_backup["equipment"] == shared["equipment"]
    assert with_backup["internet"] == %{"mode" => "backup", "apn" => "test.apn"}
    assert {:ok, ^with_backup} = NetworkForm.to_network(params, ports, with_backup, :ports)
    assert {:ok, ^shared} = NetworkForm.to_network(internet, ports, with_backup, :internet)

    separate = Map.put(params, "mode", "ports")
    assert {:ok, unassigned} = NetworkForm.to_network(separate, ports, shared, :ports)
    assert unassigned == %{"mode" => "ports", "eth0" => nil, "eth1" => nil}
    assert {:error, _} = NetworkForm.to_network(separate, ports, with_backup, :ports)

    cellular = %{
      "mode" => "ports",
      "eth0" => nil,
      "eth1" => base["eth1"],
      "internet" => %{"mode" => "cellular", "apn" => "test.apn"}
    }

    assert {:error, _} = NetworkForm.to_network(params, ports, cellular, :ports)
  end

  defp assert_distribution_cookie_cached do
    Task.async(fn ->
      socket = %Socket{transport_pid: self(), private: %{lifecycle: %Lifecycle{}}}
      {:ok, socket} = DistributionLive.mount(%{}, %{}, socket)
      refute is_nil(socket.assigns.cookie)
      network = socket.assigns.projection_state.inputs.network

      # An ordinary domain update must keep the view's cached cookie, not read it again.
      socket = Phoenix.Component.assign(socket, :cookie, :cached)

      {:halt, socket} =
        Lifecycle.handle_info(
          {:projection, socket.assigns.projection_server, {:replace, :network, network}},
          socket
        )

      assert socket.assigns.cookie == :cached
    end)
    |> Task.await()
  end

  defp assert_settings_commands do
    Task.async(fn ->
      socket = %Socket{
        transport_pid: self(),
        private: %{lifecycle: %Lifecycle{}, live_temp: %{}}
      }

      {:cont, socket} = Observations.on_mount(:status, %{}, %{}, socket)
      {:ok, socket} = SettingsLive.mount(%{}, %{}, socket)
      socket = Phoenix.LiveView.clear_flash(socket)
      server = socket.assigns.projection_server
      key = :public_key.generate_key({:namedCurve, :ed25519}) |> :ssh_file.extract_public_key()
      line = :ssh_file.encode([{key, [comment: ~c"Settings scenario"]}], :auth_keys)
      fingerprint = to_string(:ssh.hostkey_fingerprint(:sha256, key))

      {:noreply, socket} =
        SettingsLive.handle_event("key-draft", %{"ssh" => %{"public_key" => "invalid"}}, socket)

      {:noreply, socket} =
        SettingsLive.handle_event("add-key", %{"ssh" => %{"public_key" => "invalid"}}, socket)

      assert socket.assigns.key_form[:public_key].value == "invalid"
      assert socket.assigns.flash["error"] =~ "public key"

      {:noreply, socket} =
        SettingsLive.handle_event("add-key", %{"ssh" => %{"public_key" => line}}, socket)

      assert socket.assigns.key_form[:public_key].value == ""
      assert_receive {:projection, ^server, {:replace, :ssh, ssh}}, 2000

      {:halt, socket} =
        Lifecycle.handle_info({:projection, server, {:replace, :ssh, ssh}}, socket)

      assert Enum.any?(socket.assigns.projection.ssh.keys, &(&1.fingerprint == fingerprint))

      {:noreply, socket} =
        SettingsLive.handle_event("remove-key", %{"fingerprint" => fingerprint}, socket)

      assert_receive {:projection, ^server, {:replace, :ssh, ssh}}, 2000

      {:halt, socket} =
        Lifecycle.handle_info({:projection, server, {:replace, :ssh, ssh}}, socket)

      refute Enum.any?(socket.assigns.projection.ssh.keys, &(&1.fingerprint == fingerprint))
    end)
    |> Task.await(15_000)
  end

  defp converged(vm, clients) do
    Qemu.await(vm, "client reducers equal the device reducer", fn _ ->
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
  defp client(editor) do
    socket =
      %Socket{transport_pid: self(), private: %{lifecycle: %Lifecycle{}, live_temp: %{}}}
      |> Phoenix.LiveView.clear_flash()

    refresh =
      case editor do
        editor when editor in [:network, :lan, :ports] -> &NetworkEditor.refresh_observations/2
        :remote -> &TailscaleLive.refresh_observations/2
        :settings -> &Phoenix.Component.assign(&1, :projection, &2)
      end

    socket = Observations.subscribe(socket, refresh)
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
      base: socket.assigns.projection.remote_access.hostname,
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
        available = socket.assigns.projection.backend.available
        {:halt, socket} = Lifecycle.handle_info(message, socket)
        lost = available and not socket.assigns.projection.backend.available

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
