defmodule NervesGateWeb.Router do
  @moduledoc false
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:put_remote_access)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {NervesGateWeb.Layouts, :root})
    plug(:protect_from_forgery)

    plug(:put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self' ws: wss:; form-action 'self'; frame-ancestors 'none'"
    })
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  pipeline :home_access do
    plug(NervesGateWeb.LocalAccess, mode: :home)
  end

  pipeline :tailnet do
    plug(NervesGateWeb.LocalAccess, mode: :tailnet)
  end

  pipeline :setup_access do
    plug(NervesGateWeb.LocalAccess, mode: :setup)
  end

  scope "/", NervesGateWeb do
    pipe_through([:browser, :home_access])
    live("/", StatusLive, :index)
    live("/settings", SettingsLive, :index)
  end

  scope "/", NervesGateWeb do
    pipe_through([:browser, :setup_access])
    live("/commissioning", CommissioningLive, :index)
  end

  scope "/api/setup", NervesGateWeb do
    pipe_through([:api, :setup_access])
    get("/status", StatusController, :show)
    post("/internet", ConfigureController, :internet)
    post("/tailscale", ConfigureController, :tailscale)
    post("/cluster", ConfigureController, :cluster)
  end

  scope "/api", NervesGateWeb do
    pipe_through([:api, :tailnet])
    get("/status", StatusController, :show)
    get("/discovery", DiscoveryController, :show)
  end

  defp put_remote_access(connection, _options) do
    connection
    |> Plug.Conn.put_session(
      :remote_ip,
      NervesGateWeb.LocalAccess.ip_string(connection.remote_ip)
    )
    |> Plug.Conn.put_session(
      :dashboard_access,
      NervesGateWeb.LocalAccess.dashboard?(connection.remote_ip)
    )
  end
end
