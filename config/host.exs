import Config

# Add configuration that is only needed when running on the host here.

config :nerves_gate,
  data_dir: Path.join(System.tmp_dir!(), "nerves_gate/#{config_env()}"),
  internet_adapter: NervesGate.Internet.HostAdapter,
  tailscale_enabled: false,
  internet_poll_interval: 60_000,
  cluster_poll_interval: 60_000

if config_env() == :test do
  config :nerves_gate,
    alarm_timings: %{
      failure_debounce: 20,
      flapping_count: 4,
      flapping_period: 500,
      flapping_hold: 100
    }
end

config :nerves_gate, NervesGateWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: if(config_env() == :test, do: 0, else: 4000)]

if config_env() == :dev do
  config :nerves_gate, NervesGateWeb.Endpoint,
    watchers: [tailwind: {Tailwind, :install_and_run, [:default, ~w(--watch)]}]
end

config :nerves_runtime,
  kv_backend:
    {Nerves.Runtime.KVBackend.InMemory,
     contents: %{
       # The KV store on Nerves systems is typically read from UBoot-env, but
       # this allows us to use a pre-populated InMemory store when running on
       # host for development and testing.
       #
       # https://nerves-runtime.hexdocs.pm/readme.html#using-nerves_runtime-in-tests
       # https://nerves-runtime.hexdocs.pm/readme.html#nerves-system-and-firmware-metadata

       "nerves_fw_active" => "a",
       "a.nerves_fw_architecture" => "generic",
       "a.nerves_fw_description" => "N/A",
       "a.nerves_fw_platform" => "host",
       "a.nerves_fw_version" => "0.0.0",
       "nerves_serial_number" => "host-development"
     }}
