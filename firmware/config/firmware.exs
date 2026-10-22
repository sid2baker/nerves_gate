import Config

# Shared device settings, imported by ec100.exs and x86_64.exs only.
# Nothing in this file configures the workstation UI. The platform files add
# only real hardware differences; the device application is otherwise identical.
config :nerves_gate,
  # The UI calls this device's own services; the workstation uses a remote node.
  backend_node: :local,
  services: [
    NervesGate.Network.Vintage,
    {PropertyTable, name: NervesGate.Properties},
    NervesGate.SSH,
    NervesGate.Network,
    NervesGate.Remote,
    NervesGate.Equipment,
    NervesGate.Indicators,
    NervesGate.Buses,
    {Task.Supervisor, name: NervesGate.AppTasks},
    NervesGate.Storage,
    NervesGate.Apps,
    NervesGate.ProjectionServer,
    NervesGate.SDKBackend,
    NervesGateWeb.Endpoint
  ],
  # Platforms opt into real modem hardware; QEMU has no cellular profile.
  cellular: nil,
  network_adapter: {NervesGate.Network.Vintage, nil},
  remote_adapter: {NervesGate.Remote.Tailscaled, nil},
  equipment_adapter: {NervesGate.Equipment.Linux, nil}

config :nerves_gate_sdk, :backend, NervesGate.SDKBackend

# Public LAN advertisement only. Discovery does not grant access or advertise
# distribution cookies, login URLs, credentials or application data.
config :mdns_lite,
  hosts: [:hostname],
  services: [
    %{
      protocol: "nerves-device",
      transport: "tcp",
      port: 4000,
      txt_payload: [
        "product=Nerves Gate",
        "platform=#{config_target()}",
        "version=#{String.trim(File.read!(Path.expand("../../VERSION", __DIR__)))}"
      ]
    }
  ]

# Temporary access on every IPv4 interface, including USB, Ethernet and VPN.
# The UI is unauthenticated. Cellular INPUT is filtered before networking starts;
# Ethernet and VPN access must still be restricted to trusted networks.
config :nerves_gate, NervesGateWeb.Endpoint, http: [ip: {0, 0, 0, 0}, port: 4000]

config :logger, backends: [RingLogger]

config :logger, RingLogger, persist_path: "/data/ring_logger.log", persist_seconds: 5

config :nerves, :erlinit, update_clock: true

# Sends the Heart init handshake required by HEART_INIT_TIMEOUT in vm.args.
# Validate firmware only after OTP applications start; internet is not required.
# DataInit runs Nerves' normal mount/format, requires writable ext4 data, and
# installs cellular INPUT protection before networking/data users start.
config :nerves_runtime,
  startup_guard_enabled: true,
  init_module: NervesGate.Recovery.DataInit

# Uploads and EC100 button recovery share one boot-lifetime interlock.
config :ssh_subsystem_fwup,
  precheck_callback: {NervesGate.Recovery.EC100, :firmware_precheck, []}

# Nerves 2 ordering is explicit: data initialization must precede Tailscale,
# VintageNet, SSH, time persistence, and application services.
config :nerves, application_sort: [init: [:nerves_runtime]]

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
config :tailscaled_ex,
  daemon_path: "/usr/sbin/tailscaled",
  data_dir: "/data/tailscaled_ex",
  socket: "/run/tailscale/tailscaled.sock",
  manage_daemon: true,
  tun: :kernel

# VintageNet owns saved LAN settings. Trials use persist: false until confirmation.
# Each platform adds its own independent recovery/management connection.
config :vintage_net,
  route_metric_fun: {NervesGate.Network.RouteMetric, :compute_metric, 2},
  persistence: VintageNet.Persistence.FlatFile,
  config: []

# Build keys seed the device-owned store once. Settings owns later additions
# and removals; a firmware update must not restore a removed key.
config :nerves_gate,
  ssh_keys: String.split(System.get_env("NERVES_GATE_SSH_KEYS", ""), "\n", trim: true)

# Password recovery is restricted to the kernel-verified direct USB peer.
# Ethernet, VPN and QEMU management remain key-only.
config :nerves_ssh,
  iex_opts: [dot_iex: "/etc/iex.exs"],
  daemon_option_overrides: [
    auth_methods: ~c"publickey,password",
    key_cb: NervesGate.SSH,
    pwdfun: {NervesGate.SSH.USBPassword, :check, 4}
  ]
