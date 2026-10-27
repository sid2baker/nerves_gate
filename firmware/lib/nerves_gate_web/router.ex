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

  scope("/", NervesGateWeb) do
    pipe_through(:browser)

    live_session(:management,
      session: {NervesGateWeb.Access, :session, []},
      layout: {NervesGateWeb.Layouts, :app}
    ) do
      live("/", DashboardLive, :overview)
      live("/network", NetworkLive, :network)
      live("/network/details", NetworkLive, :details)
      live("/remote", RemoteLive, :remote)
      live("/apps", AppsLive, :apps)
      live("/apps/:app", AppLive, :app)
      live("/hardware", HardwareLive, :hardware)
      live("/hardware/lan/:id", LanLive, :lan)
      live("/hardware/rs485/:id", BusesLive, :rs485)
      live("/hardware/can/:id", BusesLive, :can)
      live("/settings", SettingsLive, :settings)
      live("/settings/storage", StorageLive, :storage)
    end
  end
end
