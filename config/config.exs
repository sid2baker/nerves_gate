# This file is responsible for configuring your application and its
# dependencies.
#
# This configuration file is loaded before any dependency and is restricted to
# this project.
import Config

# Enable the Nerves integration with Mix
Application.start(:nerves_bootstrap)

# Customize non-Elixir parts of the firmware. See
# https://nerves.hexdocs.pm/advanced-configuration.html for details.

config :nerves, :firmware, rootfs_overlay: "rootfs_overlay"

# Set the SOURCE_DATE_EPOCH date for reproducible builds.
# See https://reproducible-builds.org/docs/source-date-epoch/ for more information

config :nerves, source_date_epoch: "1787244399"

config :phoenix, :json_library, Jason

config :phoenix, :filter_parameters, [
  "auth_key",
  "auth_token",
  "cookie",
  "password",
  "credential",
  "secret"
]

config :tailwind,
  version: "4.3.0",
  default: [
    args: ~w(--input=assets/css/app.css --output=priv/static/app.css),
    cd: Path.expand("..", __DIR__)
  ]

config :logger, :default_formatter,
  metadata: [:alarm, :alarm_id, :alarm_state, :alarm_level, :alarm_description]

config :alarmist,
  managed_alarms: [
    NervesGate.Internet.Condition.ActionableUnavailable,
    NervesGate.Internet.Alarm.Unavailable,
    NervesGate.Internet.Alarm.Unstable,
    NervesGate.Tailnet.Condition.ActionableUnavailable,
    NervesGate.Tailnet.Alarm.Unavailable,
    NervesGate.Cluster.Condition.ActionableUnavailable,
    NervesGate.Cluster.Alarm.Unavailable
  ],
  alarm_levels: %{
    NervesGate.Internet.Signal.Unavailable => :debug,
    NervesGate.Tailnet.Signal.Unavailable => :debug,
    NervesGate.Cluster.Signal.Enabled => :debug,
    NervesGate.Cluster.Signal.Unavailable => :debug,
    NervesGate.Storage.Alarm.Failure => :error,
    NervesGate.Commissioning.Alarm.Unavailable => :error
  }

config :nerves_gate,
  data_dir: "/data",
  internet_adapter: NervesGate.Internet.VintageNetAdapter,
  internet_poll_interval: 10_000,
  tailscale_enabled: true,
  tailscale_version: "1.102.3",
  tailscale_binary_sha256: %{
    cli: "d6ffcba02fa07728f0c4847fc06d61f239f763478bd59156abf3591bdb1a3ad1",
    daemon: "ce4770bbe6fc9dbcf47d8a2ccc5efad73e3f975460b01738dd0b059879d01221"
  },
  tailscale_binaries: %{
    cli_path: "/usr/lib/nerves_gate/tailscale/tailscale",
    daemon_path: "/usr/lib/nerves_gate/tailscale/tailscaled"
  },
  distribution_port: 43_769,
  cluster_poll_interval: 5_000,
  tailnet_repair_failures: 6,
  alarm_timings: %{
    failure_debounce: 30_000,
    flapping_count: 4,
    flapping_period: :timer.minutes(5),
    flapping_hold: :timer.minutes(10)
  }

config :nerves_gate, NervesGateWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  server: true,
  url: [host: "nervesgate.local", port: 80, scheme: "http"],
  http: [ip: {0, 0, 0, 0}, port: 80],
  secret_key_base: "kVe8TVi10nIRiiuHjUdxi5zudS5O8H3CHf19UvOK1fmQY3PGuF8NrmhT2om8bgkM",
  render_errors: [
    formats: [html: NervesGateWeb.ErrorHTML, json: NervesGateWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: NervesGate.PubSub,
  live_view: [signing_salt: "nervesgate-live"]

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "target.exs"
end
