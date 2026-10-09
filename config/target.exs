import Config

config :nerves_gate,
  data_dir: "/data",
  target: Mix.target(),
  network_adapter: {NervesGate.Network.Vintage, nil}

config :logger, backends: [RingLogger]
config :nerves, :erlinit, update_clock: true

# NervesGate is the sole owner of LAN configuration. Only confirmed JSON is durable.
config :vintage_net, persistence: VintageNet.Persistence.Null, config: []

# Recovery SSH is key-only. Supply a public key at firmware build time.
config :nerves_ssh,
  authorized_keys: String.split(System.get_env("NERVES_GATE_SSH_KEYS", ""), "\n", trim: true)
