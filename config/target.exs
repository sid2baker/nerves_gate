import Config

config :nerves_gate,
  target: config_target(),
  network_adapter: {NervesGate.Network.Vintage, nil},
  remote_adapter: {NervesGate.Remote.Tailscale, nil},
  equipment_adapter: {NervesGate.Equipment.Linux, nil},
  indicators_adapter:
    if(config_target() == :ec100,
      do: {NervesGate.Indicators.EC100, "/sys/class/leds/ec100:run"},
      else: nil
    )

# Temporary access on every IPv4 interface, including USB, Ethernet and VPN.
# The UI is unauthenticated; use only on trusted networks.
config :nerves_gate, NervesGateWeb.Endpoint, http: [ip: {0, 0, 0, 0}, port: 4000]

config :logger, backends: [RingLogger]
config :nerves, :erlinit, update_clock: true

# Sends the Heart init handshake required by HEART_INIT_TIMEOUT in vm.args.
# Validate firmware only after OTP applications start; internet is not required.
config :nerves_runtime, startup_guard_enabled: true

# Nerves 2 requires an explicit source timestamp. Keep rebuilds deterministic;
# source-archive builds without Git can supply SOURCE_DATE_EPOCH instead.
source_date_epoch =
  System.get_env("SOURCE_DATE_EPOCH") ||
    case System.cmd("git", ["log", "-1", "--format=%ct"], stderr_to_stdout: true) do
      {timestamp, 0} -> String.trim(timestamp)
      _ -> raise "Set SOURCE_DATE_EPOCH when building firmware without Git history"
    end

case Integer.parse(source_date_epoch) do
  {seconds, ""} when seconds >= 0 -> :ok
  _ -> raise "SOURCE_DATE_EPOCH must be a non-negative Unix timestamp in seconds"
end

config :nerves, source_date_epoch: source_date_epoch

# Shared console setup plus binaries explicitly installed for the selected target.
config :nerves, :firmware,
  rootfs_overlay: [
    Path.expand("../rootfs_overlay/common", __DIR__),
    Path.expand("../rootfs_overlay/#{config_target()}", __DIR__)
  ],
  # sqfstar rejects timestamp flags together with SOURCE_DATE_EPOCH. Use the env value.
  rootfs_type: {:squashfs, ["-no-xattrs", "-quiet"]}

# The dependency's OTP application supervises tailscaled and retries when offline.
# Keep identity on the data partition and the LocalAPI socket in volatile storage.
config :tailscale,
  daemon_path: "/usr/sbin/tailscaled",
  data_dir: "/data/tailscale_ex",
  socket: "/run/tailscale/tailscaled.sock",
  manage_daemon: true,
  tun: :kernel

# VintageNet owns saved LAN settings. Trials use persist: false until confirmation.
# USB provisioning is independent of LAN trials.
# VintageNetDirect's DHCP server is confined to the point-to-point USB link.
config :vintage_net,
  persistence: VintageNet.Persistence.FlatFile,
  config: if(config_target() == :ec100, do: [{"usb0", %{type: VintageNetDirect}}], else: [])

# Recovery SSH is key-only. Supply a public key at firmware build time.
config :nerves_ssh,
  authorized_keys: String.split(System.get_env("NERVES_GATE_SSH_KEYS", ""), "\n", trim: true),
  iex_opts: [dot_iex: "/etc/iex.exs"]
