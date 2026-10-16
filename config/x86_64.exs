import Config
import_config "firmware.exs"

# One QEMU development firmware, also used by all scenarios. Not the workstation.
# No EC100 peripherals or modem are emulated.
config :nerves_gate,
  buses_adapter: nil,
  recovery_adapter: nil,
  indicators_adapter: nil

# Initialize real VintageNetDirect and a serial-derived development identity
# before VintageNet starts. Every simulated device uses this same firmware.
config :nerves_runtime, init_module: NervesGate.QemuInit

# Management is separate from eth0/eth1; LAN trials cannot remove this address.
config :vintage_net,
  config: [
    {"eth2",
     %{
       type: VintageNetEthernet,
       ipv4: %{method: :static, address: "192.168.77.2", prefix_length: 24}
     }}
  ]
