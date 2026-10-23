import Config
import_config "firmware.exs"

# One QEMU development firmware, also used by all scenarios. Not the workstation.
# Same application as EC100; only virtual hardware differs. QEMU does not emulate
# EC100 buses, LEDs or the recovery button, so those adapters are disabled.
config :nerves_gate, :board, %{
  data_partition: "/sys/class/block/vda4/dev",
  # The simulator's prepared ext4 virtual SD card.
  apps_device: "/dev/vdb",
  cellular: nil,
  buses_adapter: nil,
  recovery_adapter: nil,
  indicators_adapter: nil
}

# The QEMU system exposes usb0 before Erlang starts, so USB is configured exactly
# as on EC100. eth2 is the bench's private management link (distribution, HTTP,
# SSH forwards); it is separate from eth0/eth1 and LAN trials cannot remove it.
config :vintage_net,
  config: [
    {"usb0", %{type: VintageNetDirect}},
    {"eth2",
     %{
       type: VintageNetEthernet,
       ipv4: %{method: :static, address: "192.168.77.2", prefix_length: 24}
     }}
  ]
