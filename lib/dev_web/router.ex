defmodule DevWeb.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html", "json"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {NervesGateWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", DevWeb do
    pipe_through(:browser)
    get("/api/state", Api, :state)
    get("/api/console/:device", Api, :console)
    post("/api/run", Api, :run)
    post("/api/control", Api, :control)
    post("/api/install", Api, :install)
    post("/api/operation", Api, :operation)
    post("/api/application", Api, :application)
    post("/api/firmware/review", Api, :review_firmware)
    post("/api/firmware/confirm", Api, :confirm_firmware)

    live_session :workbench,
      on_mount: [DevWeb.WorkbenchLive],
      layout: {DevWeb.Layouts, :app} do
      live("/", OverviewLive, :overview)
      live("/devices", DevicesLive, :devices)
      live("/devices/physical/:address", PhysicalDeviceLive, :devices)
      live("/devices/:id", DeviceLive, :devices)
      live("/apps", ApplicationsLive, :apps)
      live("/apps/:id", ApplicationsLive, :apps)
      live("/firmware", FirmwareLive, :firmware)
      live("/simulator", SimulatorLive, :simulator)
    end
  end
end
