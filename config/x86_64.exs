import Config
import_config "firmware.exs"

# One QEMU development firmware, also used by all scenarios. Not the workstation.
# No EC100 peripherals or modem are emulated.
config :nerves_gate,
  buses_adapter: nil,
  recovery_adapter: nil,
  indicators_adapter: nil

# Controller-visible identity through the loopback-only management forward.
# The actual NIC remains 192.168.77.2; no Tailscale login is needed.
node = System.get_env("NERVES_GATE_DEVICE_NODE") || "nerves_gate@127.0.0.1"
config :nerves_gate, development_node: String.to_atom(node)

# Management is separate from eth0/eth1; LAN trials cannot remove this address.
config :vintage_net,
  config: [
    {"eth2",
     %{
       type: VintageNetEthernet,
       ipv4: %{method: :static, address: "192.168.77.2", prefix_length: 24}
     }}
  ]
