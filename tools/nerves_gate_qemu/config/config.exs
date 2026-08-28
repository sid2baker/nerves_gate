import Config

project_root = Path.expand("../../..", __DIR__)

config :nerves_gate_qemu,
  project_root: project_root,
  release_port: 4010

config :nerves_gate_qemu, NervesGateQEMUWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  server: true,
  url: [host: "qemu.localhost", port: 4000, scheme: "http"],
  http: [
    ip: {127, 0, 0, 1},
    port: if(config_env() == :test, do: 0, else: 4000),
    thousand_island_options: [num_acceptors: 4]
  ],
  secret_key_base: "tBP1d7zSaDT7l0xW8Qm5D8dHnYQhdTFUM0TBVfoQpgL0oM9MtX6JuFjRpGsJEghf",
  render_errors: [
    formats: [html: NervesGateQEMUWeb.ErrorHTML, json: NervesGateQEMUWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: NervesGateQEMU.PubSub,
  live_view: [signing_salt: "nervesgate-qemu-live"],
  watchers:
    if(config_env() == :dev,
      do: [tailwind: {Tailwind, :install_and_run, [:default, ~w(--watch)]}],
      else: []
    )

config :phoenix, :json_library, Jason

config :tailwind,
  version: "4.3.0",
  default: [
    args: ~w(--input=assets/css/app.css --output=priv/static/app.css),
    cd: Path.expand("..", __DIR__)
  ]
