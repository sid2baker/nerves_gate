defmodule NervesGateWebTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

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

  test "the completed dashboard is read-only for connectivity settings" do
    body =
      render_component(&NervesGateWeb.StatusLive.dashboard/1, view: dashboard_view(), flash: %{})

    assert body =~ "Gateway state"
    assert body =~ "Known gateways"
    assert body =~ "Active alarms"
    assert body =~ "Internet checks"
    assert body =~ ~s(href="/commissioning")
    refute body =~ "apply-configuration"
    refute body =~ "auth_token"
    refute body =~ "Enable recovery access"
  end

  test "stale replicas expose last-known alarms with an explicit warning" do
    alarm = %{id: "Remote.Alarm", description: "Remote gateway needs attention", level: :warning}

    remote_data =
      NervesGate.DeviceState.Data.new(
        device_id: "remote-gateway",
        name: "Remote gateway",
        firmware_version: "1.0.0",
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
    assert body =~ "Showing revision 7"
  end

  test "ordinary uplink addresses cannot visit management routes" do
    connection = %{build_conn() | remote_ip: {192, 168, 1, 50}}
    assert connection |> get("/api/status") |> response(403)
  end

  test "status API exposes the slot configuration without credentials" do
    body = build_conn() |> get("/api/status") |> json_response(200)

    assert is_map(body["configuration"])
    assert is_map(body["device"])
    refute inspect(body) =~ "auth_token"
    refute inspect(body) =~ "password"
  end

  test "discovery API exposes the public cluster group" do
    body = build_conn() |> get("/api/discovery") |> json_response(200)

    assert is_binary(body["gateway_id"])
    assert Map.has_key?(body, "cluster_group")
  end

  defp with_pending_phase(phase, function) do
    with_pending_phase(phase, System.monotonic_time(:millisecond) + 60_000, function)
  end

  defp with_pending_phase(phase, deadline, function) do
    original = :sys.get_state(NervesGate.Configuration)

    pending = %{
      id: "candidate-test",
      phase: phase,
      source_connection: "source-connection",
      deadline: deadline,
      candidate: original.current
    }

    :sys.replace_state(NervesGate.Configuration, &%{&1 | pending: pending, timer: nil})

    try do
      function.()
    after
      :sys.replace_state(NervesGate.Configuration, fn _state -> original end)
    end
  end

  defp with_configured(configured, function) do
    original = :sys.get_state(NervesGate.Configuration)

    current =
      original.current
      |> Map.put("configured", configured)
      |> Map.put("internet", if(configured, do: persisted_dhcp(), else: nil))
      |> put_in(["tailnet", "profile_id"], if(configured, do: "profile-1"))

    :sys.replace_state(NervesGate.Configuration, &%{&1 | current: current, pending: nil})

    try do
      function.()
    after
      :sys.replace_state(NervesGate.Configuration, fn _state -> original end)
    end
  end

  defp persisted_dhcp do
    NervesGate.TestScenario.dhcp() |> NervesGate.Internet.Config.to_persisted()
  end

  defp dashboard_view(replicas \\ %{}, selected_device_id \\ nil) do
    snapshot = NervesGate.DeviceState.Server.snapshot()
    status = NervesGate.Status.snapshot()

    state = %{
      data: snapshot.data,
      boot_id: snapshot.boot_id,
      revision: snapshot.revision,
      replicas: replicas
    }

    context = %{
      configuration: status.configuration,
      internet: status.network.connectivity,
      network_configuration: status.network.configuration,
      tailnet: NervesGate.Tailnet.Observer.status(),
      cluster: NervesGate.Cluster.Manager.status(),
      people_count: status.people_count,
      diagnostics: status.diagnostics
    }

    NervesGateWeb.StatusLive.View.build(
      state,
      context,
      selected_device_id || snapshot.data.device_id
    )
  end
end
