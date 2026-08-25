import Config

# Use Ringlogger as the logger backend and remove :console.
# See https://ring-logger.hexdocs.pm/readme.html for more information on
# configuring ring_logger.

config :logger, backends: [RingLogger]

# Use shoehorn to start the main application. See the shoehorn
# library documentation for more control in ordering how OTP
# applications are started and handling failures.

config :shoehorn, init: [:nerves_runtime, :vintage_net]

# This custom GRUB system does not yet implement trial-boot validation or
# automatic fallback. Enabling StartupGuard makes a normal QEMU boot exhaust
# validation retries and reboot, so leave it disabled until GRUB supports it.
config :nerves_runtime, startup_guard_enabled: false

config :nerves_gate, startup_gate_enabled: true

config :nerves_gate,
  frame_ancestors:
    if(config_env() == :dev and Mix.target() == :x86_64,
      do: "http://qemu.localhost:4000 http://localhost:4000",
      else: "'none'"
    )

# Erlinit can be configured without a rootfs_overlay. See
# https://github.com/nerves-project/erlinit/ for more information on
# configuring erlinit.

# Advance the system clock on devices without a real-time clock.
config :nerves, :erlinit, update_clock: true

# Configure the network using vintage_net
#
# Update regulatory_domain to your 2-letter country code E.g., "US"
#
# See https://github.com/nerves-networking/vintage_net for more information
# NervesGate owns uplink and commissioning interfaces at runtime. Keeping
# VintageNet's boot config empty prevents an unverified DHCP lease from
# replacing the persisted last-known-good candidate.
config :vintage_net,
  regulatory_domain: "00",
  persistence: VintageNet.Persistence.Null,
  config: []

config :mdns_lite,
  # The `hosts` key specifies what hostnames mdns_lite advertises.  `:hostname`
  # advertises the device's hostname.local. For the official Nerves systems, this
  # is "nerves-<4 digit serial#>.local".  The `"nerves"` host causes mdns_lite
  # to advertise "nerves.local" for convenience. If more than one Nerves device
  # is on the network, it is recommended to delete "nerves" from the list
  # because otherwise any of the devices may respond to nerves.local leading to
  # unpredictable behavior.

  hosts: [:hostname, "nerves"],
  ttl: 120,

  # SSH is a Tailnet-only service and must never be advertised on the LAN.
  services: []

# Import target specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
# Uncomment to use target specific configurations

# import_config "#{Mix.target()}.exs"
