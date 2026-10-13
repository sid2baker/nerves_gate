import Config

config :nerves_gate,
  target: config_target(),
  # Set only after identifying and qualifying the modem; see docs/networking.md.
  cellular: nil,
  network_adapter: {NervesGate.Network.Vintage, nil},
  remote_adapter: {NervesGate.Remote.Tailscale, nil},
  equipment_adapter: {NervesGate.Equipment.Linux, nil},
  buses_adapter: if(config_target() == :ec100, do: {NervesGate.Buses.EC100, nil}, else: nil),
  recovery_adapter:
    if(config_target() == :ec100, do: {NervesGate.Recovery.EC100, nil}, else: nil),
  indicators_adapter:
    if(config_target() == :ec100,
      do: {NervesGate.Indicators.EC100, "/sys/class/leds"},
      else: nil
    )

# Optional development distribution without Tailscale enrollment. Production
# keeps its existing automatic Tailscale identity and native persistent cookie.
if config_env() == :dev do
  node =
    System.get_env("NERVES_GATE_DEVICE_NODE") ||
      if(config_target() == :x86_64, do: "nerves_gate@192.168.77.2")

  if node do
    config :nerves_gate, development_node: String.to_atom(node)
  end
end

# Temporary access on every IPv4 interface, including USB, Ethernet and VPN.
# The UI is unauthenticated; use only on trusted networks.
config :nerves_gate, NervesGateWeb.Endpoint, http: [ip: {0, 0, 0, 0}, port: 4000]

config :logger, backends: [RingLogger]

config :logger, RingLogger, persist_path: "/data/ring_logger.log", persist_seconds: 5

config :nerves, :erlinit, update_clock: true

# Sends the Heart init handshake required by HEART_INIT_TIMEOUT in vm.args.
# Validate firmware only after OTP applications start; internet is not required.
config :nerves_runtime, startup_guard_enabled: true

# Nerves 2 ordering is explicit: the data check must precede Tailscale,
# VintageNet, SSH, time persistence, and application services.
config :nerves, application_sort: [init: [:nerves_runtime]]

if config_target() == :ec100 do
  config :nerves_runtime, init_module: NervesGate.Recovery.DataInit

  config :ssh_subsystem_fwup,
    precheck_callback: {NervesGate.Recovery.EC100, :firmware_precheck, []}
end

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
  route_metric_fun: {NervesGate.Network.RouteMetric, :compute_metric, 2},
  persistence: VintageNet.Persistence.FlatFile,
  config: if(config_target() == :ec100, do: [{"usb0", %{type: VintageNetDirect}}], else: [])

# A separate management NIC for QEMU development. The gateway only manages
# equipment/Internet ports eth0 and eth1, so trials cannot remove this address.
if config_target() == :x86_64 and config_env() == :dev do
  config :vintage_net,
    config: [
      {"eth2",
       %{
         type: VintageNetEthernet,
         ipv4: %{method: :static, address: "192.168.77.2", prefix_length: 24}
       }}
    ]
end

# Recovery SSH is key-only. Supply a public key at firmware build time.
config :nerves_ssh,
  authorized_keys: String.split(System.get_env("NERVES_GATE_SSH_KEYS", ""), "\n", trim: true),
  iex_opts: [dot_iex: "/etc/iex.exs"]
