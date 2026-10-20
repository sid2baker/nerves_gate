defmodule NervesGateWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :nerves_gate

  @session_options [
    store: :cookie,
    key: "_nerves_gate",
    signing_salt: "nerves-gate-session",
    same_site: "Strict",
    http_only: true
  ]

  # LAN, USB and tailnet hosts vary, and Tailscale terminates HTTPS. Validate
  # LiveView's session-bound CSRF token instead of rewriting proxy headers.
  socket("/live", Phoenix.LiveView.Socket,
    websocket: [
      connect_info: [:peer_data, session: @session_options],
      check_origin: false,
      check_csrf: true
    ],
    longpoll: false
  )

  # The simulator's mix dev.ui only; firmware is never compiled with code reloading.
  if code_reloading? do
    plug(Tidewave)
    socket("/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket)
    plug(Phoenix.LiveReloader)
    plug(Phoenix.CodeReloader)
    plug(Volt.DevServer, root: Application.compile_env(:volt, :root, "assets"))
  end

  # Firmware uses stable filenames; revalidate them across firmware upgrades.
  plug(Plug.Static,
    at: "/",
    from: :nerves_gate,
    only: ~w(assets),
    cache_control_for_etags: "public, no-cache"
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])
  plug(Plug.Parsers, parsers: [:urlencoded], pass: [], length: 16_384)
  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(NervesGateWeb.Router)
end
