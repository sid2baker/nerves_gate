defmodule NervesGateWeb.Router do
  @moduledoc false
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:put_remote_ip)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {NervesGateWeb.Layouts, :root})
    plug(:protect_from_forgery)

    plug(:put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self' ws: wss:; form-action 'self'; frame-ancestors 'none'"
    })
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  pipeline :tailnet do
    plug(NervesGateWeb.LocalAccess, mode: :tailnet)
  end

  pipeline :setup_access do
    plug(NervesGateWeb.LocalAccess, mode: :setup)
  end

  scope "/", NervesGateWeb do
    pipe_through([:browser, :tailnet])
    live("/", StatusLive, :index)
  end

  scope "/setup", NervesGateWeb do
    pipe_through([:browser, :setup_access])
    live("/", SetupLive, :index)
  end

  scope "/configure", NervesGateWeb do
    pipe_through([:api, :setup_access])
    post("/internet", ConfigureController, :internet)
    post("/tailscale", ConfigureController, :tailscale)
  end

  scope "/configure", NervesGateWeb do
    pipe_through([:api, :tailnet])
    post("/cluster", ConfigureController, :cluster)
  end

  scope "/api", NervesGateWeb do
    pipe_through([:api, :tailnet])
    get("/status", StatusController, :show)
  end

  defp put_remote_ip(connection, _options) do
    Plug.Conn.put_session(
      connection,
      :remote_ip,
      NervesGateWeb.LocalAccess.ip_string(connection.remote_ip)
    )
  end
end
