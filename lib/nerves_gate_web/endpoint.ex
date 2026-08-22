defmodule NervesGateWeb.Endpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :nerves_gate

  @session_options [
    store: :cookie,
    key: "_nerves_gate_key",
    signing_salt: "nervesgate-session",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false
  )

  plug(Plug.Static,
    at: "/assets",
    from: :nerves_gate,
    gzip: false,
    only: ~w(app.css app.js)
  )

  plug(Plug.Static,
    at: "/vendor/phoenix",
    from: :phoenix,
    gzip: false,
    only: ~w(phoenix.mjs)
  )

  plug(Plug.Static,
    at: "/vendor/live_view",
    from: :phoenix_live_view,
    gzip: false,
    only: ~w(phoenix_live_view.esm.js)
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(NervesGateWeb.LocalAccess, mode: :management)
  plug(NervesGateWeb.Router)
end
