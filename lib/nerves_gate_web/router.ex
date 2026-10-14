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

    if Application.compile_env(:nerves_gate, :dev_tests, false) do
      scope "/tests" do
        live("/", TestsLive)
        get("/state", TestsController, :state)
        post("/run", TestsController, :run)
      end
    end

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
      live("/device", DeviceLive, :device)
    end
  end
end
