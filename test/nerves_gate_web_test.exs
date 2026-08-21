defmodule NervesGateWebTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  import Phoenix.ConnTest

  @endpoint NervesGateWeb.Endpoint

  test "tailnet dashboard has the cluster menu and summary" do
    body = build_conn() |> get("/") |> html_response(200)

    assert body =~ "Open cluster nodes"
    assert body =~ "Gateway overview"
    assert body =~ "People connected"
    assert body =~ "/assets/app.js"
    refute body =~ "https://cdn"
  end

  test "local commissioning gets setup, but not the tailnet dashboard" do
    local = %{build_conn() | remote_ip: {192, 168, 77, 20}}
    assert local |> get("/setup") |> html_response(200) =~ "Initialize this gateway"

    local = %{build_conn() | remote_ip: {192, 168, 77, 20}}
    assert local |> get("/") |> response(403)
  end

  test "tailnet addresses can visit the dashboard" do
    tailnet = %{build_conn() | remote_ip: {100, 64, 0, 20}}
    assert tailnet |> get("/") |> html_response(200) =~ "Gateway overview"
  end

  test "ordinary uplink addresses cannot visit management routes" do
    connection = %{build_conn() | remote_ip: {192, 168, 1, 50}}
    assert connection |> get("/api/status") |> response(403)
  end

  test "configuration endpoints are POST-only and return useful validation" do
    response =
      build_conn()
      |> post("/configure/internet", %{"ip_address" => "not-an-ip"})
      |> json_response(422)

    assert response["ok"] == false
    assert response["error"]["address"]
    assert build_conn() |> get("/configure/tailscale?auth_token=secret") |> response(404)
  end

  test "Tailscale tokens are filtered from request logs" do
    token = "tskey-auth-super-secret-value"

    log =
      capture_log(fn ->
        build_conn()
        |> post("/configure/tailscale", %{"auth_token" => token})
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
