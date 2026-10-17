import Config

# Workstation UI/tools only. runtime.exs selects the remote device to connect to.
# No firmware settings or local device services are loaded here.
config :nerves_gate, services: [NervesGate.HostInit, NervesGate.QemuTests]

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

if config_env() == :dev do
  config :phoenix, :plug_init_mode, :runtime
  config :volt, :server, prefix: "/assets", watch_dirs: ["lib/", "dev/"]

  config :nerves_gate, NervesGateWeb.Endpoint,
    url: [host: "localhost"],
    http: [ip: {127, 0, 0, 1}, port: 4000],
    code_reloader: true,
    debug_errors: true,
    live_reload: [
      patterns: [
        ~r"lib/nerves_gate_web/.*(ex|heex)$",
        ~r"dev/.*(ex|heex)$"
      ]
    ]

  config :phoenix_live_view, debug_heex_annotations: true, debug_attributes: true
end
