defmodule WorkbenchWeb.Router do
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

  scope "/", WorkbenchWeb do
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
      on_mount: [WorkbenchWeb.WorkbenchLive],
      layout: {WorkbenchWeb.Layouts, :app} do
      live("/", OverviewLive, :overview)
      live("/devices", DevicesLive, :devices)
      live("/devices/physical/:address", PhysicalDeviceLive, :devices)
      live("/devices/:id", DeviceLive, :devices)
      live("/develop", ApplicationsLive, :apps)
      live("/develop/applications", ApplicationsLive, :apps)
      live("/develop/applications/:id", ApplicationsLive, :apps)
      live("/develop/firmware", FirmwareLive, :firmware)
      live("/develop/firmware/scenarios/:id", DeviceLive, :scenarios)
      live("/develop/firmware/manual/:id", DeviceLive, :manual)
      live("/test-lab/scenarios", FirmwareLive, :firmware)
      live("/test-lab/manual", FirmwareLive, :firmware)
      live("/test-lab/scenarios/:id", DeviceLive, :scenarios)
      live("/test-lab/manual/:id", DeviceLive, :manual)
      live("/test-lab/bench", FirmwareLive, :firmware)
      live("/provision", FactoryLive, :factory)
      live("/firmware", FirmwareLive, :firmware)
      live("/factory", FactoryLive, :factory)
      live("/simulator", FirmwareLive, :firmware)
    end
  end
end
