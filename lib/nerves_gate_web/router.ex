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
      live("/equipment", EquipmentLive, :equipment)
      live("/equipment/buses", BusesLive, :buses)
      live("/remote", RemoteLive, :remote)
      live("/settings", SettingsLive, :settings)
      live("/settings/network", NetworkLive, :network_settings)
      live("/settings/tailscale", TailscaleLive, :tailscale_settings)
      live("/settings/buses", BusesLive, :bus_settings)
    end
  end
end
