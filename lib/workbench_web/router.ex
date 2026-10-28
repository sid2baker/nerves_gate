defmodule WorkbenchWeb.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {NervesGateWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", WorkbenchWeb do
    pipe_through(:browser)

    live_session :workbench,
      on_mount: [WorkbenchWeb.Live],
      layout: {WorkbenchWeb.Layouts, :app} do
      live("/", OverviewLive, :overview)
      live("/devices", DevicesLive, :devices)
      live("/devices/:node", GatewayLive, :devices)
      live("/devices/:node/scenarios", GatewayLive, :scenarios)
      live("/devices/:node/manual", GatewayLive, :manual)
      live("/develop/plugins", PluginsLive, :plugins)
      live("/develop/plugins/:id", PluginsLive, :plugins)
      live("/develop/firmware", FirmwareLive, :firmware)
      live("/provision", FactoryLive, :factory)
    end
  end
end
