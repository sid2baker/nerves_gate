defmodule NervesGateWeb.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {NervesGateWeb.Layouts, :root})
    plug(:protect_from_forgery)

    plug(:put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'self'; form-action 'self'"
    })
  end

  scope "/", NervesGateWeb do
    pipe_through(:browser)
    live("/", DashboardLive, :overview)
    live("/equipment", DashboardLive, :equipment)
    live("/internet", DashboardLive, :internet)
    live("/remote", DashboardLive, :remote)
    live("/settings", DashboardLive, :settings)
    live("/setup", SetupLive)
  end
end
