defmodule NervesGateWebTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint NervesGateWeb.Endpoint

  test "commissioning has its own connected LiveView" do
    {:ok, view, html} = live(build_conn(), "/commissioning")

    assert html =~ "Initialize this gateway"
    assert render(view) =~ "Current step"
  end

  test "the commissioning page shows only the current setup step" do
    body = build_conn() |> get("/commissioning") |> html_response(200)

    assert body =~ "Initialize this gateway"
    assert body =~ "Connect to the Internet"
    assert body =~ ~r/<div(?=[^>]*id="static-internet-fields")(?=[^>]*hidden)[^>]*>/
    assert body =~ "DHCP obtains the IP address, subnet, gateway, and DNS settings automatically."
    assert body =~ ~s(phx-disable-with="Verifying Internet…")
    refute body =~ "Join the tailnet"
    refute body =~ "Start the cluster"
    assert body =~ "/assets/app.css"
    assert body =~ "/assets/app.js"
    refute body =~ "https://cdn"
  end

  test "each phase renders only its required action" do
    steps = [
      internet: "Connect to the Internet",
      tailscale: "Join the tailnet",
      cluster: "Choose cluster mode",
      ready: "Gateway ready"
    ]

    Enum.each(steps, fn {phase, expected} ->
      current = put_in(view(), [:setup], %{view().setup | phase: phase, ready: phase == :ready})

      body =
        render_component(&NervesGateWeb.SetupComponents.current/1,
          view: current,
          flash: %{}
        )

      assert body =~ expected

      steps
      |> Keyword.values()
      |> List.delete(expected)
      |> Enum.each(fn heading -> refute body =~ heading end)
    end)
  end

  test "the status page redirects unfinished gateways to commissioning" do
    local = %{build_conn() | remote_ip: {192, 168, 77, 20}}
    assert redirected_to(local |> get("/")) == "/commissioning"

    local = %{build_conn() | remote_ip: {192, 168, 77, 20}}
    assert local |> get("/commissioning") |> html_response(200) =~ "Initialize this gateway"

    local = %{build_conn() | remote_ip: {192, 168, 77, 20}}
    assert redirected_to(local |> get("/settings")) == "/commissioning"
  end

  test "tailnet users can open the same commissioning page" do
    tailnet = %{build_conn() | remote_ip: {100, 64, 0, 20}}
    assert tailnet |> get("/commissioning") |> html_response(200) =~ "Connect to the Internet"
  end

  test "the completed dashboard renders the fleet and selected canonical state" do
    view = put_in(view(), [:setup], %{view().setup | phase: :ready, ready: true})
    body = render_component(&NervesGateWeb.StatusLive.dashboard/1, view: view, flash: %{})

    assert body =~ "Gateway state"
    assert body =~ "Known gateways"
    assert body =~ "Active alarms"
    assert body =~ "Internet checks"
    assert body =~ "Settings"
    refute body =~ "Reconfigure this gateway"
    refute body =~ "configure-internet"
    refute body =~ "configure-tailscale"
    refute body =~ "configure-cluster"
  end

  test "guarded forms live on the dedicated settings UI component" do
    current = view()

    body =
      render_component(&NervesGateWeb.SettingsComponents.forms/1,
        view: current,
        disabled: false
      )

    assert body =~ "Guarded change"
    assert body =~ "stage-internet"
    assert body =~ "stage-tailnet"
    assert body =~ "stage-cluster"
    assert body =~ "Candidate cluster group"
  end

  test "an unconfirmed settings change renders confirmation and rollback actions" do
    pending = %{
      id: "change-1",
      kind: :internet,
      phase: :awaiting_confirmation,
      started_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      remaining_seconds: 120,
      confirmable: true
    }

    body =
      render_component(&NervesGateWeb.SettingsComponents.change_guard/1,
        view: view(),
        settings: %{pending: pending, last_error: nil}
      )

    assert body =~ "Keep changes"
    assert body =~ "Revert now"
    assert body =~ "Rollback in 2m 0s"
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

    view = view(%{"remote-gateway" => replica}, "remote-gateway")
    body = render_component(&NervesGateWeb.StatusLive.dashboard/1, view: view, flash: %{})

    assert body =~ "last successfully replicated alarms"
    assert body =~ "Remote gateway needs attention"
    assert body =~ "Showing revision 7"
  end

  test "ordinary uplink addresses cannot visit management routes" do
    connection = %{build_conn() | remote_ip: {192, 168, 1, 50}}
    assert connection |> get("/api/status") |> response(403)
  end

  test "setup endpoints are POST-only and return useful validation" do
    response =
      build_conn()
      |> post("/api/setup/internet", %{"ip_address" => "not-an-ip"})
      |> json_response(422)

    assert response["ok"] == false
    assert response["error"]["address"]
    assert build_conn() |> get("/api/setup/tailscale?auth_token=secret") |> response(404)
  end

  test "Tailscale tokens are filtered from request logs" do
    token = "tskey-auth-super-secret-value"

    log =
      capture_log(fn ->
        build_conn()
        |> post("/api/setup/tailscale", %{"auth_token" => token})
        |> json_response(409)
      end)

    refute log =~ token
  end

  test "status API exposes device and tailnet state without credential fields" do
    body = build_conn() |> get("/api/status") |> json_response(200)

    assert body["identity"]["hostname"] =~ "nervesgate-"
    assert is_map(body["device"])
    assert is_map(body["tailnet"])
    refute inspect(body) =~ "auth_token"
    refute inspect(body) =~ "password"
  end

  test "discovery API exposes the public cluster group" do
    body = build_conn() |> get("/api/discovery") |> json_response(200)

    assert is_binary(body["gateway_id"])
    assert Map.has_key?(body, "cluster_group")
  end

  defp view(replicas \\ %{}, selected_device_id \\ nil) do
    snapshot = NervesGate.DeviceState.Server.snapshot()
    status = NervesGate.Status.snapshot()

    state = %{
      data: snapshot.data,
      boot_id: snapshot.boot_id,
      revision: snapshot.revision,
      replicas: replicas
    }

    context = %{
      setup: status.setup,
      profile: status.device,
      identity: status.identity,
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
