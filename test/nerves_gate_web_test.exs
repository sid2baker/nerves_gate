defmodule NervesGateWebTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias NervesGate.DeviceState.Server

  @endpoint NervesGateWeb.Endpoint

  test "unconfigured gateways start the three-step commissioning flow with Internet" do
    with_configured(false, fn ->
      {:ok, view, html} = live(build_conn(), "/commissioning")

      assert html =~ "Configure gateway"
      assert html =~ "Gateway name"
      assert html =~ "Connect to the Internet"
      assert html =~ ~s(phx-submit="configure-internet")
      assert html =~ ~s(phx-disable-with="Verifying Internet…")
      assert html =~ ~r/<div(?=[^>]*id="configuration-static-fields")(?=[^>]*hidden)[^>]*>/
      refute html =~ "Tailscale auth key"
      refute html =~ "Cluster group"
      refute html =~ "Initialize this gateway"
      refute render(view) =~ "Change settings</button>"
    end)
  end

  test "configured gateways start with only change settings and a revert time" do
    with_configured(true, fn ->
      {:ok, view, html} = live(build_conn(), "/commissioning")

      assert html =~ "Change settings"
      assert html =~ "Auto-revert after"
      assert html =~ ~s(value="1")
      refute html =~ "Apply configuration"

      html =
        view
        |> form("form", %{"configuration" => %{"revert_minutes" => "3"}})
        |> render_submit()

      assert html =~ "Connect to the Internet"
      assert html =~ ~s(phx-submit="configure-internet")
      refute html =~ "Tailscale auth key"
      refute html =~ "Cluster group"
    end)
  end

  test "completed Internet and Tailnet settings remain accessible" do
    with_pending_phase(:tailnet, fn ->
      {:ok, view, html} = live(build_conn(), "/commissioning")

      assert html =~ "Join the tailnet"
      assert html =~ "Tailscale auth key"
      assert html =~ ~s(phx-submit="configure-tailnet")
      refute html =~ "Cluster group"

      html = view |> element(~s(button[phx-value-step="internet"])) |> render_click()
      assert html =~ "Connect to the Internet"
    end)

    with_pending_phase(:cluster, fn ->
      {:ok, view, html} = live(build_conn(), "/commissioning")

      assert html =~ "Choose cluster mode"
      assert html =~ "Cluster group"
      assert html =~ ~s(phx-submit="configure-cluster")

      html = view |> element(~s(button[phx-value-step="tailnet"])) |> render_click()
      assert html =~ "Tailscale auth key"

      html = view |> element(~s(button[phx-value-step="internet"])) |> render_click()
      assert html =~ "Connect to the Internet"
    end)
  end

  test "a complete candidate has one Tailnet acceptance action" do
    with_pending_phase(:confirmation, fn ->
      {:ok, _view, html} = live(build_conn(), "/commissioning")

      assert html =~ "Ready to accept"
      assert html =~ "Accept settings"
      assert html =~ ~s(href="/commissioning?accept=candidate-test")
      refute html =~ "Reconnect to accept"
      refute html =~ ~s(phx-click="accept-configuration")
    end)
  end

  test "commissioning access accepts through the candidate Tailnet address" do
    with_tailnet_ipv4("100.84.12.7", fn ->
      with_pending_phase(:confirmation, fn ->
        connection = %{build_conn() | remote_ip: {192, 168, 77, 20}}
        {:ok, _view, html} = live(connection, "/commissioning")

        assert html =~
                 ~s(href="http://100.84.12.7/commissioning?accept=candidate-test")
      end)
    end)
  end

  test "acceptance redirects both the fresh request and an open editor to status" do
    with_acceptance_candidate(fn id ->
      {:ok, editor, _html} = live(build_conn(), "/commissioning")
      connection = build_conn() |> get("/commissioning?accept=#{id}")

      assert redirected_to(connection) == "/"
      assert_redirect(editor, "/")
      assert Server.configured?()
      assert Server.configuration().pending == nil
    end)
  end

  test "first-time setup candidates have no automatic revert timer" do
    with_pending_phase(:tailnet, nil, fn ->
      {:ok, _view, html} = live(build_conn(), "/commissioning")

      assert html =~ "First-time setup has no automatic revert timer."
      refute html =~ "Revert in"
    end)
  end

  test "the old settings and setup API routes are gone" do
    assert build_conn() |> get("/settings") |> response(404)
    assert build_conn() |> post("/api/setup/internet", %{}) |> response(404)
    assert build_conn() |> get("/api/setup/status") |> response(404)
  end

  test "the status page redirects unconfigured gateways to commissioning" do
    with_configured(false, fn ->
      assert redirected_to(build_conn() |> get("/")) == "/commissioning"
    end)
  end

  test "the dashboard keeps remote-access settings guarded and exposes subnet routing" do
    body =
      render_component(&NervesGateWeb.StatusLive.dashboard/1, view: dashboard_view(), flash: %{})

    assert body =~ "Gateway state"
    assert body =~ "Known gateways"
    assert body =~ "Active alarms"
    assert body =~ "Internet checks"
    assert body =~ "Remote IEx"
    assert body =~ "Tailnet only"
    assert body =~ "Subnet router"
    assert body =~ ~s(phx-submit="enable-subnet-router")
    assert body =~ ~s(href="/commissioning")
    refute body =~ "apply-configuration"
    refute body =~ "auth_token"
    refute body =~ "Enable recovery access"
  end

  test "subnet routing can be enabled and disabled from the dashboard" do
    with_subnet_dashboard(fn ->
      {:ok, view, html} = live(build_conn(), "/")
      assert html =~ "Enable subnet router"

      html =
        view
        |> form("#subnet-router-form", %{
          "subnet_router" => %{"routes" => "192.168.50.42/24, 10.20.0.0/16"}
        })
        |> render_submit()

      assert html =~ "Subnet router enabled."
      assert html =~ "Disable subnet router"
      assert html =~ "192.168.50.0/24, 10.20.0.0/16"

      html = view |> element(~s(button[phx-click="disable-subnet-router"])) |> render_click()
      assert html =~ "Subnet router disabled. Remote gateway access is unchanged."
      assert html =~ "Enable subnet router"

      assert Server.current()["subnet_router"] == %{
               "enabled" => false,
               "routes" => ["192.168.50.0/24", "10.20.0.0/16"]
             }
    end)
  end

  test "Remote IEx can be enabled and disabled from the dashboard" do
    with_subnet_dashboard(fn ->
      {:ok, view, html} = live(build_conn(), "/")
      assert html =~ "Enable Remote IEx"
      assert html =~ "Disabled"

      html = view |> element(~s(button[phx-click="enable-ssh"])) |> render_click()
      assert html =~ "Remote IEx enabled for Tailnet clients."
      assert html =~ "Waiting for Tailnet"
      assert html =~ "Disable Remote IEx"
      assert Server.current()["ssh_enabled"]

      html = view |> element(~s(button[phx-click="disable-ssh"])) |> render_click()
      assert html =~ "Remote IEx disabled."
      assert html =~ "Enable Remote IEx"
      refute Server.current()["ssh_enabled"]
    end)
  end

  test "stale replicas expose last-known alarms with an explicit warning" do
    alarm = %{id: "Remote.Alarm", description: "Remote gateway needs attention", level: :warning}

    remote_data =
      NervesGate.DeviceState.Data.new(
        device_id: "remote-gateway",
        name: "Remote gateway",
        firmware_version: "1.0.0",
        subnet_router: %{
          enabled: true,
          routes: ["192.168.60.0/24"],
          advertised: ["192.168.60.0/24"],
          approved: ["192.168.60.0/24"],
          primary: ["192.168.60.0/24"],
          error: nil
        },
        alarms: [alarm]
      )

    replica = %{
      data: remote_data,
      node: :"nervesgate@100.64.0.20",
      boot_id: "remote-boot",
      revision: 7,
      connected: false,
      last_seen_at: ~U[2026-08-22 10:00:00Z]
    }

    body =
      render_component(&NervesGateWeb.StatusLive.dashboard/1,
        view: dashboard_view(%{"remote-gateway" => replica}, "remote-gateway"),
        flash: %{}
      )

    assert body =~ "last successfully replicated alarms"
    assert body =~ "Remote gateway needs attention"
    assert body =~ "Approved routes"
    assert body =~ "192.168.60.0/24"
    assert body =~ "Showing revision 7"
  end

  test "ordinary uplink addresses cannot visit management routes" do
    connection = %{build_conn() | remote_ip: {192, 168, 1, 50}}
    assert connection |> get("/api/status") |> response(403)
  end

  test "development setup network can observe status but not peer discovery" do
    previous = Application.get_env(:nerves_gate, :local_dashboard)
    Application.put_env(:nerves_gate, :local_dashboard, true)

    try do
      with_configured(true, fn ->
        connection = %{build_conn() | remote_ip: {192, 168, 77, 2}}
        assert connection |> get("/api/status") |> json_response(200)

        connection = %{build_conn() | remote_ip: {192, 168, 77, 2}}
        assert connection |> get("/api/discovery") |> response(403)
      end)
    after
      if is_nil(previous),
        do: Application.delete_env(:nerves_gate, :local_dashboard),
        else: Application.put_env(:nerves_gate, :local_dashboard, previous)
    end
  end

  test "status API exposes one versioned, canonical, secret-free schema" do
    body = build_conn() |> get("/api/status") |> json_response(200)

    assert body["schema"] == "nerves_gate.status.v1"
    assert is_binary(body["observed_at"])
    assert is_map(body["configuration"]["current"]["subnet_router"])
    assert is_boolean(body["configuration"]["current"]["ssh_enabled"])
    refute Map.has_key?(body["configuration"], "last_error")
    refute Map.has_key?(body["configuration"], "pending")
    assert is_map(body["local"]["data"]["ssh"])
    assert is_list(body["local"]["data"]["alarms"])
    assert is_map(body["replicas"])
    assert is_map(body["runtime"]["tailscale"])
    refute Map.has_key?(body["runtime"]["tailscale"], "last_error")
    refute Map.has_key?(body["runtime"]["tailscale"], "last_daemon_exit")
    refute Map.has_key?(body, "device_state")
    refute Map.has_key?(body, "network")
    refute inspect(body) =~ "auth_token"
    refute inspect(body) =~ "password"
  end

  test "status API explicitly serializes the canonical SSH address" do
    original = :sys.get_state(Server)

    data = %{
      original.data
      | ssh: %{enabled: true, state: :listening, address: {100, 64, 0, 10}, port: 22}
    }

    :sys.replace_state(Server, &%{&1 | data: data})

    try do
      body = build_conn() |> get("/api/status") |> json_response(200)
      assert get_in(body, ["local", "data", "ssh", "address"]) == "100.64.0.10"
    after
      :sys.replace_state(Server, fn _state -> original end)
    end
  end

  test "discovery API exposes the public cluster group" do
    body = build_conn() |> get("/api/discovery") |> json_response(200)

    assert is_binary(body["gateway_id"])
    assert Map.has_key?(body, "cluster_group")
  end

  defp with_tailnet_ipv4(ipv4, function) do
    observer = NervesGate.Tailnet.Observer
    original = :sys.get_state(observer)

    :sys.replace_state(observer, fn state ->
      %{state | status: state.status |> Map.put(:online, true) |> Map.put(:ipv4, ipv4)}
    end)

    try do
      function.()
    after
      :sys.replace_state(observer, fn _state -> original end)
    end
  end

  defp with_acceptance_candidate(function) do
    original = :sys.get_state(Server)
    root = NervesGate.TestScenario.temporary_root(:acceptance_redirect)
    id = "candidate-acceptance"

    candidate =
      original.current
      |> Map.put("configured", true)
      |> Map.put("internet", persisted_dhcp())
      |> Map.put("tailnet", %{"profile_id" => "profile-1"})
      |> Map.put("cluster", %{"group" => nil})
      |> NervesGate.Gateway.Settings.touch()

    pending = %{
      id: id,
      phase: :confirmation,
      source_connection: "source-connection",
      timeout: nil,
      deadline: nil,
      timer_token: nil,
      candidate: candidate
    }

    ops =
      original.ops
      |> Map.put(:commit_tailnet, fn _metadata -> :ok end)
      |> Map.put(:subnet_router, fn _enabled, routes -> {:ok, routes} end)
      |> Map.put(:access, fn _mode, _interface -> {:ok, []} end)
      |> Map.put(:disable_access, fn -> :ok end)

    active_slot = original.firmware.active
    :ok = NervesGate.Storage.initialize(root)
    :ok = NervesGate.Gateway.Persistence.write_slot(original.current, active_slot, root)
    :ok = NervesGate.Gateway.Persistence.write_candidate(candidate, root)

    :sys.replace_state(Server, fn state ->
      %{
        state
        | root: root,
          pending: pending,
          timer: nil,
          ops: ops,
          keep_local_access: true
      }
    end)

    try do
      function.(id)
    after
      :sys.replace_state(Server, fn _state -> original end)
      NervesGate.Commissioning.Alarms.required(not original.current["configured"])
      File.rm_rf!(root)
    end
  end

  defp with_pending_phase(phase, function) do
    with_pending_phase(phase, System.monotonic_time(:millisecond) + 60_000, function)
  end

  defp with_pending_phase(phase, deadline, function) do
    original = :sys.get_state(Server)

    pending = %{
      id: "candidate-test",
      phase: phase,
      source_connection: "source-connection",
      deadline: deadline,
      candidate: original.current
    }

    :sys.replace_state(Server, &%{&1 | pending: pending, timer: nil})

    try do
      function.()
    after
      :sys.replace_state(Server, fn _state -> original end)
    end
  end

  defp with_subnet_dashboard(function) do
    original = :sys.get_state(Server)
    root = NervesGate.TestScenario.temporary_root(:subnet_dashboard)

    current =
      original.current
      |> Map.put("configured", true)
      |> Map.put("internet", persisted_dhcp())
      |> Map.put("subnet_router", %{"enabled" => false, "routes" => []})
      |> Map.put("ssh_enabled", false)
      |> put_in(["tailnet", "profile_id"], "profile-1")

    :ok = NervesGate.Storage.initialize(root)
    :ok = NervesGate.Gateway.Persistence.write_slot(current, "a", root)

    subnet_router = fn enabled, routes ->
      canonical =
        Enum.map(routes, fn
          "192.168.50.42/24" -> "192.168.50.0/24"
          route -> route
        end)

      {:ok, if(enabled, do: canonical, else: routes)}
    end

    ops =
      original.ops
      |> Map.put(:subnet_router, subnet_router)
      |> Map.put(:ssh, fn _enabled -> :ok end)
      |> Map.put(:tailnet_restore, fn _profile -> :ok end)

    :sys.replace_state(Server, fn state ->
      %{state | root: root, current: current, pending: nil, ops: ops}
    end)

    try do
      function.()
    after
      :sys.replace_state(Server, fn _state -> original end)
      File.rm_rf!(root)
    end
  end

  defp with_configured(configured, function) do
    original = :sys.get_state(Server)

    current =
      original.current
      |> Map.put("configured", configured)
      |> Map.put("internet", if(configured, do: persisted_dhcp(), else: nil))
      |> put_in(["tailnet", "profile_id"], if(configured, do: "profile-1"))

    :sys.replace_state(Server, &%{&1 | current: current, pending: nil})

    try do
      function.()
    after
      :sys.replace_state(Server, fn _state -> original end)
    end
  end

  defp persisted_dhcp do
    NervesGate.TestScenario.dhcp() |> NervesGate.Internet.Config.to_persisted()
  end

  defp dashboard_view(replicas \\ %{}, selected_device_id \\ nil) do
    snapshot = NervesGate.DeviceState.Server.snapshot()

    state = %{
      data: snapshot.data,
      boot_id: snapshot.boot_id,
      revision: snapshot.revision,
      replicas: replicas
    }

    context = %{
      configuration: NervesGate.DeviceState.Server.configuration(),
      internet: NervesGate.Internet.Monitor.status(),
      network_configuration: NervesGate.Internet.Manager.status(),
      tailnet: NervesGate.Tailnet.Observer.status(),
      cluster: NervesGate.Cluster.Manager.status(),
      people_count: NervesGateWeb.Presence.count(),
      diagnostics: %{
        target: Nerves.Runtime.mix_target(),
        uptime_seconds: 0,
        otp_release: List.to_string(:erlang.system_info(:otp_release)),
        memory_bytes: :erlang.memory(:total)
      }
    }

    NervesGateWeb.StatusLive.View.build(
      state,
      context,
      selected_device_id || snapshot.data.device_id
    )
  end
end
