defmodule DevWeb.Endpoint do
  @moduledoc "Developer workbench: a private Unix socket for the CLI and a loopback port."
  use Phoenix.Endpoint, otp_app: :nerves_gate_dev

  @session_options [
    store: :cookie,
    key: "_nerves_gate_simulator",
    signing_salt: "nerves-gate-simulator",
    same_site: "Strict",
    http_only: true
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [
      connect_info: [session: @session_options],
      check_origin: ["//localhost", "//127.0.0.1"]
    ],
    longpoll: false
  )

  if code_reloading? do
    # Unix-socket peers have no loopback address. The session listens only on
    # that socket and 127.0.0.1; Tidewave's Origin checks stay enabled.
    plug(Tidewave, allow_remote_access: true)
    socket("/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket)
    plug(Phoenix.LiveReloader)
    plug(Phoenix.CodeReloader)
    plug(Volt.DevServer, root: Application.compile_env(:volt, :root, "assets"))
  end

  # CI sessions run without Volt and serve the built assets.
  plug(Plug.Static, at: "/", from: :nerves_gate, only: ~w(assets))
  plug(Plug.Parsers, parsers: [:urlencoded], pass: [], length: 16_384)
  plug(Plug.Session, @session_options)
  plug(DevWeb.Router)
end
