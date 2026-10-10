import Config

# Host development never configures the workstation's network.
config :nerves_gate,
  data_dir: Path.expand("../tmp/#{config_env()}", __DIR__),
  target: :host,
  network_adapter: {NervesGate.Network.Host, NervesGate.Network.Host},
  remote_adapter: {NervesGate.Remote.Host, NervesGate.Remote.Host}
