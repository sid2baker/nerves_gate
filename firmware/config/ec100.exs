import Config
import_config "firmware.exs"

# Physical EC100 hardware. Shared device services are in firmware.exs.
config :nerves_gate, :board, %{
  data: {:ext4, "/sys/class/block/mmcblk0p3/dev"},
  # Removable SPI SD card; provision its first partition as ext4 separately.
  plugins_device: "/dev/mmcblk1p1",
  cellular: %{
    interface: "wwan0",
    # SIM slot insertion is active-high.
    sim_detect_level: 1,
    config: %{
      type: VintageNetECM,
      vintage_net_ecm: %{at_tty: "ttyUSB2", modem: NervesGate.Cellular.Modem}
    }
  },
  # ttyS3/ttyS4 are the RS485 field ports.
  ports: %{
    can: ["can0", "can1"],
    serial: [
      {"ttyS3", "rs485", "RS485 · automatic direction · 9600 8N1"},
      {"ttyS4", "rs485", "RS485 · automatic direction · 9600 8N1"}
    ]
  },
  # Status LEDs by role and the KEY_PROG1 input that drives reboot/factory-reset recovery.
  indicators: %{
    leds: %{run: "ec100:run", user1: "ec100:user1", user2: "ec100:user2"},
    button: "gpio-keys"
  }
}

# USB recovery is independent of LAN trials. Its DHCP server serves only USB.
config :vintage_net, config: [{"usb0", %{type: VintageNetDirect}}]

# Optional development distribution without Tailscale enrollment. Production
# discovers its node address through Tailscale and uses OTP's persistent cookie.
if config_env() == :dev do
  if node = System.get_env("NERVES_GATE_DEVICE_NODE") do
    config :nerves_gate, development_node: String.to_atom(node)
  end
end
