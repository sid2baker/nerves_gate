defmodule NervesGateWeb.ProjectionTest do
  use ExUnit.Case, async: false
  alias NervesGate.{Projection, ProjectionServer}
  alias NervesGateWeb.{NetworkEditor, NetworkForm, RemoteLive}
  alias Phoenix.LiveView.{Lifecycle, Socket}

  setup do
    start_supervised!(ProjectionServer)
    :ok
  end

  test "remote daemon events invalidate both remote and network inputs",
    do: assert_remote_events()

  test "remote drafts, busy state and private auth keys stay view-local", do: assert_remote_ui()

  test "time synchronization enables commissioning without submitting the draft" do
    remote = %{
      NervesGate.Remote.unavailable()
      | available: true,
        state: "offline",
        auth_state: "needs_login"
    }

    projection = Projection.apply(projection(), {:replace, :remote, remote})
    socket = Phoenix.Component.assign(remote_socket(), projection: projection.status)

    {:noreply, socket} =
      RemoteLive.handle_event("change", %{"remote" => %{"hostname" => "my-gateway"}}, socket)

    refute projection.status.actions["remote.connect"].enabled
    page = remote_page(socket)
    assert [_] = Floki.find(page, "#tailscale-save[disabled]")

    assert Floki.text(Floki.find(page, "#tailscale-connect-unavailable")) =~
             "Waiting for system time synchronization."

    synchronized =
      Projection.apply(projection, {:replace, :remote, %{remote | time_synchronized: true}})

    socket = RemoteLive.refresh_observations(socket, synchronized.status)
    assert socket.assigns.projection.actions["remote.connect"].enabled
    assert socket.assigns.form.params["hostname"] == "my-gateway"
    assert socket.assigns.dirty
    assert socket.assigns.request == nil
    refute socket.assigns.login_requested
    assert [] = Floki.find(remote_page(socket), "#tailscale-save[disabled]")
    assert [] = Floki.find(remote_page(socket), "#tailscale-connect-unavailable")

    online =
      Projection.apply(
        synchronized,
        {:replace, :remote, %{remote | state: "online", auth_state: "authenticated"}}
      )

    socket = RemoteLive.refresh_observations(socket, online.status)
    refute socket.assigns.projection.remote.time_synchronized
    assert socket.assigns.projection.actions["remote.configure"].enabled
    assert socket.assigns.projection.actions["remote.disconnect"].enabled
    assert socket.assigns.request == nil
    assert [] = Floki.find(remote_page(socket), "#tailscale-save[disabled]")
    assert [] = Floki.find(remote_page(socket), "#tailscale-connect-unavailable")
  end

  test "network forms preserve unrelated roles and editor drafts",
    do: assert_network_forms(projection().status)

  test "ambiguous observed uplinks are online without a suggested port",
    do: assert_discovery_observations(projection())

  test "runtime credentials require explicit reveal, stay view-local and clear on loss",
    do: assert_distribution_cookie_cached()

  defp projection do
    interface = fn name, addresses ->
      %{
        name: name,
        present: true,
        link: addresses != [],
        state: :configured,
        method: "dhcp",
        connection: if(addresses == [], do: :disconnected, else: :internet),
        addresses: addresses,
        master: nil,
        gateway: nil,
        nameservers: []
      }
    end

    settings = %{
      "mode" => "ports",
      "eth0" => %{"role" => "internet", "address" => NervesGate.Config.address_defaults()},
      "eth1" => nil
    }

    observed = %{
      simulated: false,
      ports: [
        interface.("eth0", [%{address: "192.0.2.15", prefix_length: 24}]),
        interface.("eth1", [])
      ],
      usb: interface.("usb0", [%{address: "172.31.220.1", prefix_length: 30}]),
      bridge: interface.("br0", []),
      cellular: nil,
      cellular_supported: false
    }

    Projection.new(%{
      network: %{
        config: NervesGate.Config.from_network(settings),
        trial: nil,
        observed: observed,
        cellular: NervesGate.Cellular.empty(),
        error: nil,
        recovering: false,
        ready: false,
        phase: :idle,
        sharing_admission: :ok
      },
      remote: NervesGate.Remote.unavailable(),
      indicators: NervesGate.Indicators.unavailable(),
      hardware: NervesGate.Hardware.unavailable(),
      ssh: NervesGate.SSH.unavailable(),
      storage: NervesGate.Storage.unavailable(),
      system: %{
        firmware: "test",
        target: "x86_64",
        node: node(),
        elixir: System.version(),
        otp: System.otp_release()
      }
    })
  end

  defp assert_remote_events do
    # A dirty domain avoids scheduling a timer in this protocol-routing check.
    state = %{dirty: MapSet.new([:system])}

    event =
      {Tailscaled, ["auth", "state"], :needs_login, :authenticating,
       %{old_timestamp: 1, new_timestamp: 2}}

    assert {:noreply, updated} = ProjectionServer.handle_info(event, state)
    assert updated.dirty == MapSet.new([:system, :remote, :network])
  end

  defp assert_remote_ui do
    socket = remote_socket()
    projection = socket.assigns.projection

    projection = %{
      projection
      | remote: %{
          projection.remote
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
      RemoteLive.handle_event("method", %{"remote" => %{"method" => "auth_key"}}, socket)

    page = remote_page(keyed)
    assert [_] = Floki.find(page, "input[type='password'][name='remote[auth_key]'][value='']")

    assert [] =
             Floki.find(page, "#tailscale-form[phx-change], input[type='password'][phx-change]")

    # The device rejects a stale submission before any write; the page never retains a key.
    stale = Phoenix.Component.assign(keyed, base: "not-the-current-hostname")
    secret = "tskey-auth-ui-test-only"

    {:noreply, rejected} =
      RemoteLive.handle_event(
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
      | remote: %{projection.remote | operation: "connect", auth_state: "stopped"}
    }

    starting = RemoteLive.refresh_observations(waiting, starting)
    assert starting.assigns.login_requested
    assert starting.assigns.request == :connect

    failed = put_in(projection.remote.auth_state, "error")
    failed = RemoteLive.refresh_observations(waiting, failed)
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
      | remote: %{
          projection.remote
          | state: "online",
            hostname: "gateway",
            operation: "configure"
        }
    }

    saving = RemoteLive.refresh_observations(saving, configuring)
    assert saving.assigns.request == :configure
    saved = put_in(configuring.remote.operation, nil)
    saved = RemoteLive.refresh_observations(saving, saved)
    assert saved.assigns.request == nil
    assert Phoenix.Flash.get(saved.assigns.flash, :info) == "Device name saved."
  end

  defp assert_network_forms(status) do
    base = status.network.desired
    ports = status.connections.ports
    internet = NetworkForm.from_settings(base, :internet)
    assert {:ok, ^base} = NetworkForm.to_network(internet, ports, base, :internet)

    assert {:error, _} =
             NetworkForm.to_network(%{"enabled" => "true"}, ports, base, {:application, "eth1"})

    assert {:error, _} = NetworkForm.to_network(%{"mode" => "shared"}, ports, base, :ports)
    assigns = %{id: "draft-check", editor: :internet, projection: status, access: %{}}
    assert {:ok, socket} = NetworkEditor.update(assigns, %Socket{})

    assert {:noreply, socket} =
             NetworkEditor.handle_event(
               "change",
               %{"network" => %{"internet_ip" => "192.0.2.123", "enabled" => "forged"}},
               socket
             )

    assert {:ok, socket} = NetworkEditor.update(assigns, socket)
    assert socket.assigns.form.params["internet_ip"] == "192.0.2.123"
    refute Map.has_key?(socket.assigns.form.params, "enabled")
    assert socket.assigns.dirty
  end

  defp assert_discovery_observations(projection) do
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

  defp assert_distribution_cookie_cached do
    Task.async(fn ->
      socket = %Socket{transport_pid: self(), private: %{lifecycle: %Lifecycle{}}}
      {:ok, socket} = RemoteLive.mount(%{}, %{}, socket)
      assert is_nil(socket.assigns.cookie)
      system = %{socket.assigns.projection_state.inputs.system | node: :"gateway@192.0.2.1"}
      projection = Projection.apply(socket.assigns.projection_state, {:replace, :system, system})

      socket =
        Phoenix.Component.assign(socket,
          projection_state: projection,
          projection: projection.status
        )

      assert [] = Floki.find(remote_page(socket), "#distribution-cookie")
      {:noreply, revealed} = RemoteLive.handle_event("show-cookie", %{}, socket)
      refute is_nil(revealed.assigns.cookie)
      assert [_] = Floki.find(remote_page(revealed), "#distribution-cookie")
      refute Map.has_key?(revealed.assigns.projection, :cookie)
      {:noreply, hidden} = RemoteLive.handle_event("hide-cookie", %{}, revealed)
      assert hidden.assigns.cookie == nil

      # An ordinary domain update preserves only this view's explicit reveal.
      network = socket.assigns.projection_state.inputs.network
      socket = Phoenix.Component.assign(revealed, :cookie, :cached)

      {:halt, socket} =
        Lifecycle.handle_info(
          {:projection, socket.assigns.projection_server, {:replace, :network, network}},
          socket
        )

      assert socket.assigns.cookie == :cached

      assert RemoteLive.refresh_observations(
               socket,
               Map.put(socket.assigns.projection, :system, %{
                 socket.assigns.projection.system
                 | node: :nonode@nohost
               })
             ).assigns.cookie == nil

      lost = RemoteLive.refresh_observations(socket, Projection.disconnected().status)
      assert lost.assigns.cookie == nil
      {:noreply, still_lost} = RemoteLive.handle_event("show-cookie", %{}, lost)
      assert still_lost.assigns.cookie == nil
    end)
    |> Task.await()
  end

  defp remote_socket do
    socket =
      %Socket{private: %{lifecycle: %Lifecycle{}, live_temp: %{}}}
      |> Phoenix.LiveView.clear_flash()

    {:ok, socket} = RemoteLive.mount(%{}, %{}, socket)
    socket
  end

  defp remote_page(socket) do
    socket.assigns
    |> RemoteLive.render()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
    |> Floki.parse_document!()
  end
end
