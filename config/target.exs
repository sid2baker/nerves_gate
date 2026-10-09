import Config

config :nerves_gate,
  data_dir: "/data",
  target: config_target(),
  network_adapter: {NervesGate.Network.Vintage, nil}

config :logger, backends: [RingLogger]
config :nerves, :erlinit, update_clock: true

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

# Static console setup plus target-specific binaries prepared by the release step.
config :nerves, :firmware,
  rootfs_overlay: [
    Path.expand("../rootfs_overlay", __DIR__),
    Path.join(Mix.Project.build_path(), "tailscale_rootfs")
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

# NervesGate owns LAN configuration; USB provisioning is independent of LAN trials.
# VintageNetDirect's DHCP server is confined to the point-to-point USB link.
config :vintage_net,
  persistence: VintageNet.Persistence.Null,
  config: if(config_target() == :ec100, do: [{"usb0", %{type: VintageNetDirect}}], else: [])

# Recovery SSH is key-only. Supply a public key at firmware build time.
config :nerves_ssh,
  authorized_keys: String.split(System.get_env("NERVES_GATE_SSH_KEYS", ""), "\n", trim: true),
  iex_opts: [dot_iex: "/etc/iex.exs"]
