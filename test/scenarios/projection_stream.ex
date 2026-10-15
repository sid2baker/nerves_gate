defmodule NervesGate.Scenarios.ProjectionStream do
  @moduledoc false
  import ExUnit.Assertions
  alias NervesGate.{Projection, ProjectionServer}
  alias NervesGate.TestQemu, as: Qemu

  alias NervesGateWeb.{
    DistributionLive,
    NetworkEditor,
    NetworkForm,
    Observations,
    SettingsLive,
    TailscaleLive
  }

  alias Phoenix.LiveView.{Lifecycle, Socket}

  @guest :"nerves_gate@192.168.77.2"
  @server {ProjectionServer, @guest}

  def name,
    do: "UI reducers follow the device stream, survive restart and reconnect, and keep drafts"

  def run(vm) do
    assert Qemu.status(vm).system.node == @guest
    assert_runtime_backend()
    assert_http_pages()
    assert_distribution_cookie_cached()
    assert_network_forms(vm)
    assert_settings_commands()

    clients =
      for editor <- [:network, :lan, :ports, :remote, :settings],
          do: spawn_link(fn -> client(editor) end)

    try do
      initial = converged(vm, clients)
      assert initial.status.system.target == "x86_64"
      assert initial.status.system.node == @guest
      assert {:ok, _} = Jason.encode(initial.status)
      assert Process.whereis(ProjectionServer) == nil

      Qemu.disconnect_wan(vm)

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
      Qemu.reconnect_wan(vm)
      Qemu.await(vm, "cable restored", &NervesGate.ScenarioHelpers.addressed?/1)
      converged(vm, clients)
      assert_drafts(clients)

      old_server = client_state(hd(clients)).server
      assert node(old_server) == @guest
      :erpc.call(@guest, Process, :exit, [old_server, :kill])

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
      assert Node.disconnect(@guest)

      Qemu.await(vm, "UI clients resubscribe after distribution disconnect", fn _ ->
        Enum.all?(clients, fn pid ->
          state = client_state(pid)
          state.server != nil and state.disconnects > disconnects[pid]
        end)
      end)

      converged(vm, clients)
      assert_drafts(clients)
    after
      Qemu.reconnect_wan(vm)
      for pid <- clients, do: send(pid, :stop)
    end

    Qemu.await(vm, "server releases dead subscribers", fn _ ->
      state = :erpc.call(@guest, :sys, :get_state, [ProjectionServer])
      Enum.all?(clients, &(not Map.has_key?(state.clients, &1)))
    end)
  end

  defp assert_runtime_backend do
    assert NervesGateWeb.Backend.status().system.node == @guest
    assert Process.whereis(NervesGate.Network) == nil
    assert Process.whereis(ProjectionServer) == nil
    backend = Application.fetch_env!(:nerves_gate, :backend_node)

    try do
      Application.put_env(:nerves_gate, :backend_node, nil)
      refute NervesGateWeb.Backend.status().backend.available
      refute NervesGateWeb.Backend.projection().status.backend.available
      assert {:error, :unavailable} = NervesGateWeb.Backend.subscribe_projection()
      assert {:error, %{code: "outcome_unknown"}} = NervesGateWeb.Backend.identify()
    after
      Application.put_env(:nerves_gate, :backend_node, backend)
    end

    # The same compiled host code immediately selects the real device again.
    assert NervesGateWeb.Backend.status().system.node == @guest
    assert NervesGateWeb.Backend.projection().status.system.node == @guest
  end

  # Exercise real static mounts through the development Unix socket too. It is
  # not an IP address and must never count as proof of USB management access.
  defp assert_http_pages do
    for path <- [
          "/",
          "/network",
          "/equipment/lan/1",
          "/equipment/lan/2",
          "/remote",
          "/settings",
          "/distribution",
          "/tests"
        ] do
      response =
        Req.get!("http://localhost#{path}",
          unix_socket: System.fetch_env!("QEMU_HTTP_SOCKET"),
          retry: false
        )

      assert response.status == 200
      assert response.body =~ "data-phx-main"
      refute response.body =~ "Use a trusted network."
      refute response.body =~ "Network changes have a 60-second undo window."
      refute response.body =~ "Configure equipment addressing under"
      destination = if path == "/tests", do: "/", else: "/tests"
      assert [link] = Regex.run(~r/<a\b[^>]*href="#{destination}"[^>]*>/, response.body)
      refute link =~ "data-phx-link"

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
      projection = ProjectionServer.snapshot(@server)
      Enum.all?(clients, &(client_state(&1).projection == projection))
    end)

    ProjectionServer.snapshot(@server)
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
    socket = %Socket{transport_pid: self(), private: %{lifecycle: %Lifecycle{}}}

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
