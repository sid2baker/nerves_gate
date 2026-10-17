defmodule NervesGateWeb.Simulator.Router do
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

  scope "/", NervesGateWeb.Simulator do
    pipe_through(:browser)
    get("/api/state", Api, :state)
    post("/api/run", Api, :run)
    post("/api/control", Api, :control)
    live("/", OverviewLive)
    live("/devices/:id", DeviceLive)
  end
end
