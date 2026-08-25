defmodule NervesGateQEMUWeb.Router do
  @moduledoc false
  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {NervesGateQEMUWeb.Layouts, :root})
    plug(:protect_from_forgery)

    plug(:put_secure_browser_headers, %{
      "content-security-policy" =>
        "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self' ws: wss:; frame-src http://*.localhost:* http://localhost:*; form-action 'self'; frame-ancestors 'none'"
    })
  end

  scope "/", NervesGateQEMUWeb do
    pipe_through(:browser)
    live("/", QemuLive, :index)
  end
end
