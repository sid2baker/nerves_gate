import Config

# Simulator services run on the workstation, never as device-domain stand-ins.
config :nerves_gate,
  target: :host,
  distribution_cookie: :mycookie,
  services: [NervesGateSim.HostInit, NervesGateWeb.Endpoint]

config :phoenix, :json_library, Jason
config :phoenix, :filter_parameters, ["password", "auth_key", "pin", "secret", "public_key"]

for {endpoint, salt} <- [
      {NervesGateWeb.Endpoint, "nerves-gate-live"},
      {NervesGateSimWeb.Endpoint, "nerves-gate-simulator"}
    ] do
  config :nerves_gate, endpoint,
    adapter: Bandit.PhoenixAdapter,
    url: [host: "localhost"],
    http: [ip: {127, 0, 0, 1}, port: 4000],
    server: false,
    render_errors: [formats: [html: NervesGateWeb.ErrorHTML], layout: false],
    pubsub_server: NervesGate.PubSub,
    live_view: [signing_salt: salt]
end

# Code reload is repository tooling; installed packages serve the built assets.
firmware = Path.expand("../../firmware", __DIR__)

if config_env() == :dev and File.dir?(Path.join(firmware, "assets")) do
  config :phoenix, :plug_init_mode, :runtime

  config :phoenix_live_reload,
    dirs: [Path.join(firmware, "lib/nerves_gate_web"), "lib/nerves_gate_sim_web"]

  config :volt,
    entry: Path.join(firmware, "assets/js/app.js"),
    root: Path.join(firmware, "assets"),
    sources: ["**/*.js"],
    outdir: Path.join(firmware, "priv/static/assets"),
    resolve_dirs: ["deps"],
    target: :es2020,
    format: :esm,
    hash: false,
    code_splitting: false,
    sourcemap: false,
    tailwind: [
      css: Path.join(firmware, "assets/css/app.css"),
      sources: [
        %{base: Path.join(firmware, "lib"), pattern: "**/*.{ex,heex}"},
        %{base: "lib/", pattern: "**/*.ex"},
        %{base: Path.join(firmware, "assets"), pattern: "**/*.js"}
      ]
    ]

  config :volt, :server, prefix: "/assets", watch_dirs: [Path.join(firmware, "lib"), "lib/"]

  for endpoint <- [NervesGateWeb.Endpoint, NervesGateSimWeb.Endpoint] do
    config :nerves_gate, endpoint,
      code_reloader: true,
      debug_errors: true,
      reloadable_apps: [:nerves_gate, :nerves_gate_sim],
      live_reload: [patterns: [~r"lib/(nerves_gate_web|nerves_gate_sim_web)/.*(ex|heex)$"]]
  end

  config :phoenix_live_view, debug_heex_annotations: true, debug_attributes: true
end

if config_env() == :test, do: config(:logger, level: :warning)
