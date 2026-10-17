import Config
import_config "firmware.exs"

# Physical EC100 hardware. Shared device services are in firmware.exs.
config :nerves_gate,
  data_partition: "/sys/class/block/mmcblk0p3/dev",
  buses_adapter: {NervesGate.Buses.EC100, nil},
  recovery_adapter: {NervesGate.Recovery.EC100, nil},
  indicators_adapter: {NervesGate.Indicators.EC100, "/sys/class/leds"}

# USB recovery is independent of LAN trials. Its DHCP server serves only USB.
config :vintage_net, config: [{"usb0", %{type: VintageNetDirect}}]

# Optional development distribution without Tailscale enrollment. Production
# discovers its node address through Tailscale and uses OTP's persistent cookie.
if config_env() == :dev do
  if node = System.get_env("NERVES_GATE_DEVICE_NODE") do
    config :nerves_gate, development_node: String.to_atom(node)
  end
end
