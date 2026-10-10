defmodule NervesGateWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :nerves_gate

  @session_options [
    store: :cookie,
    key: "_nerves_gate",
    signing_salt: "nerves-gate-session",
    same_site: "Strict",
    http_only: true
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [:peer_data, session: @session_options], check_origin: :conn],
    longpoll: false
  )

  plug(Plug.Static, at: "/assets", from: :nerves_gate, only: ~w(app.css app.js))
  plug(Plug.Static, at: "/vendor/phoenix", from: :phoenix, only: ~w(phoenix.mjs))

  plug(Plug.Static,
    at: "/vendor/live_view",
    from: :phoenix_live_view,
    only: ~w(phoenix_live_view.esm.js)
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])
  plug(Plug.Parsers, parsers: [:urlencoded], pass: [], length: 16_384)
  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(NervesGateWeb.Router)
end
