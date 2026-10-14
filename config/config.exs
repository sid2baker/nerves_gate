import Config

Application.start(:nerves_bootstrap)

# Public cookie for trusted development networks only. Production keeps OTP's cookie.
config :nerves_gate,
  distribution_cookie: if(config_env() == :dev, do: :mycookie),
  dev_tests: config_env() in [:dev, :test] and Mix.target() == :host

config :phoenix, :json_library, Jason
config :phoenix, :filter_parameters, ["password", "auth_key", "pin", "secret"]

config :nerves_gate, NervesGateWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "nervesgate.local"],
  http: [ip: {127, 0, 0, 1}, port: 4000],
  server: config_env() != :test,
  render_errors: [formats: [html: NervesGateWeb.ErrorHTML], layout: false],
  pubsub_server: NervesGate.PubSub,
  live_view: [signing_salt: "nerves-gate-live"]

if Mix.target() == :host do
  import_config "host.exs"
  if config_env() == :dev, do: import_config("dev.exs")
else
  import_config "target.exs"
end
