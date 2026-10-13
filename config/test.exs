import Config

config :nerves_gate,
  target: :test,
  network_adapter: {NervesGate.Network.Host, NervesGate.Network.Host},
  remote_adapter: {NervesGate.Remote.Host, NervesGate.Remote.Host},
  equipment_adapter: {NervesGate.Equipment.Host, NervesGate.Equipment.Host},
  indicators_adapter: {NervesGate.Indicators.Host, NervesGate.Indicators.Host},
  recovery_adapter: {NervesGate.Recovery.Host, NervesGate.Indicators.Host},
  buses_adapter: {NervesGate.Buses.Host, NervesGate.Buses.Host}
