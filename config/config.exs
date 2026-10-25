import Config

# Only the explicit workbench launcher starts UI services. No device domains or
# gateway HTTP endpoint run on the workstation.
config :nerves_gate,
  target: :host,
  distribution_cookie: :mycookie,
  services: []

config :phoenix, :json_library, Jason

config :phoenix, :filter_parameters, [
  "password",
  "username",
  "auth_key",
  "pin",
  "secret",
  "public_key"
]

config :nerves_gate_workbench, WorkbenchWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  http: [ip: {127, 0, 0, 1}, port: 4000],
  server: false,
  render_errors: [formats: [html: NervesGateWeb.ErrorHTML], layout: false],
  pubsub_server: NervesGate.PubSub,
  live_view: [signing_salt: "nerves-gate-simulator"]

firmware = Path.expand("../firmware", __DIR__)
import_config "../firmware/config/assets.exs"

if config_env() == :dev do
  config :phoenix, :plug_init_mode, :runtime

  config :phoenix_live_reload,
    dirs: [Path.join(firmware, "lib/nerves_gate_web"), "lib/workbench_web"]

  config :nerves_gate_workbench, WorkbenchWeb.Endpoint,
    code_reloader: true,
    debug_errors: true,
    reloadable_apps: [:nerves_gate, :nerves_gate_workbench],
    live_reload: [patterns: [~r"lib/(nerves_gate_web|workbench_web)/.*(ex|heex)$"]]

  config :phoenix_live_view, debug_heex_annotations: true, debug_attributes: true
end

if config_env() == :test, do: config(:logger, level: :warning)
