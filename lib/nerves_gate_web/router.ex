defmodule NervesGateWeb.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  # Volt's development error overlay injects styles. Firmware keeps a strict CSP.
  @style_src if Application.compile_env(
                  :nerves_gate,
                  [NervesGateWeb.Endpoint, :code_reloader],
                  false
                ),
                do: "'self' 'unsafe-inline'",
                else: "'self'"

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {NervesGateWeb.Layouts, :root})
    plug(:protect_from_forgery)

    plug(:put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; script-src 'self'; style-src #{@style_src}; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'self'; form-action 'self'"
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
      live("/remote", TailscaleLive, :remote)
      live("/distribution", DistributionLive, :distribution)
      live("/equipment", EquipmentLive, :equipment)
      live("/equipment/lan/:id", LanLive, :lan)
      live("/equipment/rs485/:id", BusesLive, :rs485)
      live("/equipment/can/:id", BusesLive, :can)
      live("/settings", SettingsLive, :settings)
    end
  end
end
