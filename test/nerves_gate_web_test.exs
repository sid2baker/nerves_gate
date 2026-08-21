defmodule NervesGateWebTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint NervesGateWeb.Endpoint

  test "the root page shows only the current setup step" do
    body = build_conn() |> get("/") |> html_response(200)

    assert body =~ "Initialize this gateway"
    assert body =~ "Connect to the Internet"
    refute body =~ "Join the tailnet"
    refute body =~ "Start the cluster"
    assert body =~ "/assets/app.js"
    refute body =~ "https://cdn"
  end

  test "each phase renders only its required action" do
    status = NervesGate.Status.snapshot()

    steps = [
      internet: "Connect to the Internet",
      tailscale: "Join the tailnet",
      cluster: "Start the cluster",
      ready: "Gateway ready"
    ]

    Enum.each(steps, fn {phase, expected} ->
      current =
        status
        |> put_in([:setup, :phase], phase)
        |> put_in([:setup, :ready], phase == :ready)

      body = render_component(&NervesGateWeb.SetupPage.current/1, status: current, flash: %{})
      assert body =~ expected

      steps
      |> Keyword.values()
      |> List.delete(expected)
      |> Enum.each(fn heading -> refute body =~ heading end)
    end)
  end

  test "there is one page rather than separate setup and dashboard URLs" do
    local = %{build_conn() | remote_ip: {192, 168, 77, 20}}
    assert local |> get("/") |> html_response(200) =~ "Initialize this gateway"

    local = %{build_conn() | remote_ip: {192, 168, 77, 20}}
    assert local |> get("/setup") |> response(404)
  end

  test "tailnet users see the same current initialization state" do
    tailnet = %{build_conn() | remote_ip: {100, 64, 0, 20}}
    assert tailnet |> get("/") |> html_response(200) =~ "Connect to the Internet"
  end

  test "the completed dashboard has the cluster menu and summary" do
    status =
      NervesGate.Status.snapshot()
      |> put_in([:setup, :ready], true)
      |> put_in([:setup, :phase], :ready)

    body = render_component(&NervesGateWeb.StatusLive.dashboard/1, status: status, flash: %{})

    assert body =~ "Open cluster nodes"
    assert body =~ "Gateway overview"
    assert body =~ "People connected"
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
end
