import Config
import_config "firmware.exs"

# Physical EC100 hardware. Shared device services are in firmware.exs.
config :nerves_gate, :board, %{
  data: {:ext4, "/sys/class/block/mmcblk0p3/dev"},
  # Removable SD slot on SPI1 (mmc-spi). Plugin data uses the card's first
  # partition (ext4).
  plugins_slot: %{path: "devices/platform/ff130000.spi", partition: 1},
  cellular: %{
    interface: "wwan0",
    # SIM slot insertion is active-high.
    sim_detect_level: 1,
    config: %{
      type: VintageNetECM,
      vintage_net_ecm: %{at_tty: "ttyUSB2", modem: NervesGate.Cellular.Modem}
    }
  },
  # Plugin-assignable hardware; `kind` says which class of plugin may own it.
  # The RS485 transceivers switch direction automatically.
  ports: [
    %{id: "eth0", kind: :ethernet, label: "LAN 1", assignable: true},
    %{id: "eth1", kind: :ethernet, label: "LAN 2", assignable: true},
    %{id: "ttyS3", kind: :rs485, label: "RS485 1", assignable: true},
    %{id: "ttyS4", kind: :rs485, label: "RS485 2", assignable: true},
    %{id: "can0", kind: :can, label: "CAN 1", assignable: true},
    %{id: "can1", kind: :can, label: "CAN 2", assignable: true}
  ],
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
