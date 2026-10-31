import Config
import_config "firmware.exs"

# Physical EM300 hardware (RK3506, SPI NAND). Shared device services are in firmware.exs.
# Peripherals that are not yet qualified on EM300 (modem, LEDs, recovery key)
# stay disabled rather than borrowing EC100 assumptions.
config :nerves_gate, :board, %{
  # UBIFS on the UBI "data" volume, mounted by erlinit at /root.
  data: {:ubifs, "/dev/ubi0_2"},
  # Removable microSD slot; provision its first partition as ext4 separately.
  plugins_device: "/dev/mmcblk0p1",
  cellular: nil,
  # ttyS5 is the extension-module bus, owned by the I/O domain, not a plugin port.
  ports: %{
    can: ["can0", "can1"],
    serial: [
      {"ttyS1", "serial", "UART1 · transceiver unqualified"},
      {"ttyS2", "serial", "UART2 · transceiver unqualified"},
      {"ttyS3", "serial", "UART3 · transceiver unqualified"},
      {"ttyS4", "serial", "UART4 · transceiver unqualified"}
    ]
  },
  # LED polarity and the front key are not qualified yet.
  indicators: nil
}

# fwup's destination is the NAND env partition. Slot writes (UBI volume and raw
# kernel slot) and data-volume reset run outside it and need --unsafe; the
# archives come from the read-only system image or a verified SSH upload.
config :nerves_runtime, devpath: "/dev/mtdblock2", fwup_extra_options: ["--unsafe"]
config :ssh_subsystem_fwup, fwup_extra_options: ["--unsafe"]

# USB recovery is independent of LAN trials. Its DHCP server serves only USB.
config :vintage_net, config: [{"usb0", %{type: VintageNetDirect}}]

# Optional development distribution without Tailscale enrollment. Production
# discovers its node address through Tailscale and uses OTP's persistent cookie.
if config_env() == :dev do
  if node = System.get_env("NERVES_GATE_DEVICE_NODE") do
    config :nerves_gate, development_node: String.to_atom(node)
  end
end
