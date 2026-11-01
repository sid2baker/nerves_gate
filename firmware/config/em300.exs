import Config
import_config "firmware.exs"

# Physical EM300 hardware (RK3506, SPI NAND). Shared device services are in firmware.exs.
# Peripherals that are not yet qualified on EM300 (modem, LEDs, recovery key)
# stay disabled rather than borrowing EC100 assumptions.
config :nerves_gate, :board, %{
  # UBIFS on the UBI "data" volume, mounted by erlinit at /root.
  data: {:ubifs, "/dev/ubi0_2"},
  # The microSD slot is wired to a Genesys USB card reader on internal hub port
  # 1-1.3, not to the SoC's SD controller. Plugin data uses the card's first
  # partition (ext4).
  plugins_slot: %{path: "devices/platform/ff780000.usb/usb1/1-1/1-1.3", partition: 1},
  cellular: nil,
  # Factory network: the WAN jack (eth0) with DHCP. The stock vendor firmware
  # runs DHCP on eth0 and bridges eth1 as its LAN.
  internet_port: "eth0",
  # Plugin-assignable Linux resources; `kind` says which plugin may own them.
  # Three physical Ethernet jacks are specified (WAN + 2 LAN), but Linux exposes
  # only eth0 (WAN) and eth1 (LAN). Do not invent an eth2 resource or assume
  # independent LAN jacks.
  # The vendor specifies 4x RS485 on UART1-4 (electrically unqualified here).
  # The expansion bus is ttyS5 (921600 8N1) with the module reset and link lines,
  # one resource for a plugin speaking the IOTRouter expansion protocol.
  ports: [
    %{id: "eth0", kind: :ethernet, label: "WAN", assignable: true},
    %{id: "eth1", kind: :ethernet, label: "LAN", assignable: true},
    %{id: "ttyS1", kind: :rs485, label: "RS485 1", assignable: true},
    %{id: "ttyS2", kind: :rs485, label: "RS485 2", assignable: true},
    %{id: "ttyS3", kind: :rs485, label: "RS485 3", assignable: true},
    %{id: "ttyS4", kind: :rs485, label: "RS485 4", assignable: true},
    %{
      id: "ttyS5",
      kind: :iotrouter_expansion,
      label: "Expansion Bus",
      assignable: true,
      gpios: %{reset: "EXT_RESET", link: "EXT_LINK"}
    }
  ],
  # LED polarity and the front key are not qualified yet.
  indicators: nil
}

# fwup's destination is the NAND env partition. UBI slot writes and data-volume
# reset run outside it and need --unsafe; the
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
