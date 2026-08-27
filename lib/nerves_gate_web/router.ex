defmodule NervesGateWeb.Router do
  @moduledoc false
  use Phoenix.Router
  import Phoenix.LiveView.Router

  @frame_ancestors Application.compile_env(:nerves_gate, :frame_ancestors, "'none'")

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:put_remote_access)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {NervesGateWeb.Layouts, :root})
    plug(:protect_from_forgery)

    plug(:put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self' ws: wss:; frame-src 'self'; form-action 'self'; frame-ancestors #{@frame_ancestors}"
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
  end

  scope "/", NervesGateWeb do
    pipe_through([:browser, :setup_access])
    live("/commissioning", CommissioningLive, :index)
  end

  scope "/", NervesGateWeb do
    pipe_through([:browser, :tailnet])
    live("/update", UpdateLive, :index)
  end

  scope "/api", NervesGateWeb do
    pipe_through([:api, :home_access])
    get("/status", StatusController, :show)
  end

  scope "/api", NervesGateWeb do
    pipe_through([:api, :tailnet])
    get("/discovery", DiscoveryController, :show)
  end

  scope "/api/firmware", NervesGateWeb do
    pipe_through([:api, :tailnet])
    post("/check", FirmwareController, :check)
    post("/prepare", FirmwareController, :prepare)
    post("/install", FirmwareController, :install)
    post("/accept", FirmwareController, :accept)
    post("/rollback", FirmwareController, :rollback)
  end

  scope "/api/configuration", NervesGateWeb do
    pipe_through([:api, :setup_access])
    post("/internet", ConfigurationController, :internet)
    post("/tailnet", ConfigurationController, :tailnet)
    post("/cluster", ConfigurationController, :cluster)
    post("/update/:scope", ConfigurationController, :update)
    post("/keep", ConfigurationController, :keep)
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
    |> Plug.Conn.put_session(
      :tailnet_access,
      NervesGateWeb.LocalAccess.tailnet?(connection.remote_ip)
    )
  end
end
