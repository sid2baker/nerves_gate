import Config
import_config "firmware.exs"

# Physical EC100 hardware. Shared device services are in firmware.exs.
config :nerves_gate,
  buses_adapter: {NervesGate.Buses.EC100, nil},
  recovery_adapter: {NervesGate.Recovery.EC100, nil},
  indicators_adapter: {NervesGate.Indicators.EC100, "/sys/class/leds"}

config :nerves_runtime, init_module: NervesGate.Recovery.DataInit

config :ssh_subsystem_fwup,
  precheck_callback: {NervesGate.Recovery.EC100, :firmware_precheck, []}

# USB recovery is independent of LAN trials. Its DHCP server serves only USB.
config :vintage_net, config: [{"usb0", %{type: VintageNetDirect}}]

# Optional development distribution without Tailscale enrollment. Production
# discovers its node address through Tailscale and uses OTP's persistent cookie.
if config_env() == :dev do
  if node = System.get_env("NERVES_GATE_DEVICE_NODE") do
    config :nerves_gate, development_node: String.to_atom(node)
  end
end
