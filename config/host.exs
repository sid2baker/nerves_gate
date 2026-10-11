import Config

# Host development never configures the workstation's network.
config :nerves_gate,
  target: :host,
  network_adapter: {NervesGate.Network.Host, NervesGate.Network.Host},
  remote_adapter: {NervesGate.Remote.Host, NervesGate.Remote.Host},
  equipment_adapter: {NervesGate.Equipment.Host, NervesGate.Equipment.Host},
  indicators_adapter: {NervesGate.Indicators.Host, NervesGate.Indicators.Host}
