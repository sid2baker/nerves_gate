import Config

# Firmware tests use the development build, not a separate test firmware.
unless {config_target(), config_env()} in [
         {:host, :dev},
         {:host, :test},
         {:host, :docs},
         {:x86_64, :dev},
         {:ec100, :dev},
         {:ec100, :prod}
       ] do
  raise """
  Unsupported build: MIX_TARGET=#{config_target()} MIX_ENV=#{config_env()}.
  Supported builds: host/dev, host/test, host/docs, x86_64/dev, ec100/dev, ec100/prod.
  Run QEMU scenarios with mix test; they use x86_64/dev firmware.
  """
end

Application.start(:nerves_bootstrap)

# Public cookie for trusted development networks only. Production keeps OTP's cookie.
config :nerves_gate,
  target: config_target(),
  distribution_cookie: if(config_env() == :dev, do: :mycookie)

config :phoenix, :json_library, Jason
config :phoenix, :filter_parameters, ["password", "auth_key", "pin", "secret", "public_key"]

config :nerves_gate, NervesGateWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "nervesgate.local"],
  http: [ip: {127, 0, 0, 1}, port: 4000],
  server: config_env() not in [:test, :docs],
  render_errors: [formats: [html: NervesGateWeb.ErrorHTML], layout: false],
  pubsub_server: NervesGate.PubSub,
  live_view: [signing_salt: "nerves-gate-live"]

# MIX_TARGET selects where this code runs, not the device the host connects to.
# host.exs: workstation. ec100.exs / x86_64.exs: device + shared firmware.exs.
# runtime.exs is loaded later at startup.
import_config "#{config_target()}.exs"
