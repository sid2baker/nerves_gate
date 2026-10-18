import Config

# Workstation UI/tools only. mix dev.ui selects the device to connect to; mix dev
# replaces these services with the simulator site. No device services run here.
config :nerves_gate, services: [NervesGate.HostInit, NervesGateWeb.Endpoint]

# Stable entry names let firmware use Phoenix static paths without loading Volt.
config :volt,
  entry: "assets/js/app.js",
  root: "assets",
  sources: ["**/*.js"],
  outdir: "priv/static/assets",
  resolve_dirs: ["deps"],
  target: :es2020,
  format: :esm,
  hash: false,
  code_splitting: false,
  sourcemap: false,
  tailwind: [
    css: "assets/css/app.css",
    sources: [
      %{base: "lib/", pattern: "**/*.{ex,heex}"},
      %{base: "dev/", pattern: "**/*.ex"},
      %{base: "assets/", pattern: "**/*.js"}
    ]
  ]

# The mix dev simulator site. The session selects its listeners at startup.
config :nerves_gate, NervesGateWeb.Simulator.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [formats: [html: NervesGateWeb.ErrorHTML], layout: false],
  pubsub_server: NervesGate.PubSub,
  live_view: [signing_salt: "nerves-gate-simulator"]

if config_env() == :dev do
  config :phoenix, :plug_init_mode, :runtime
  # Never recursively watch Nerves SDKs and disposable disks under _build/.
  config :phoenix_live_reload, dirs: ["lib/nerves_gate_web", "dev/simulator_web"]
  config :volt, :server, prefix: "/assets", watch_dirs: ["lib/", "dev/"]

  config :nerves_gate, NervesGateWeb.Endpoint,
    url: [host: "localhost"],
    http: [ip: {127, 0, 0, 1}, port: 4000],
    code_reloader: true,
    debug_errors: true,
    live_reload: [patterns: [~r"lib/nerves_gate_web/.*(ex|heex)$"]]

  config :nerves_gate, NervesGateWeb.Simulator.Endpoint,
    code_reloader: true,
    debug_errors: true,
    live_reload: [
      patterns: [~r"lib/nerves_gate_web/components/.*(ex|heex)$", ~r"dev/.*(ex|heex)$"]
    ]

  config :phoenix_live_view, debug_heex_annotations: true, debug_attributes: true
end

# mix test and mix ci print scenario results. OTP SSH and Phoenix log every
# connection, expected authentication rejection and 404 below warning level.
if config_env() == :test, do: config(:logger, level: :warning)
