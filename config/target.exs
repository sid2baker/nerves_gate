import Config

qemu_firmware_public_key = "QQ7mTLG7ip0Wu5PYksxiwID9sXip67R374bCbmLilWY="
release_api_url = System.get_env("NERVES_GATE_RELEASE_API_URL", "https://api.github.com")

firmware_public_keys =
  System.get_env(
    "NERVES_GATE_FWUP_PUBLIC_KEYS",
    if(config_env() == :dev, do: qemu_firmware_public_key, else: "")
  )
  |> String.split(",", trim: true)

if firmware_public_keys == [] do
  raise "NERVES_GATE_FWUP_PUBLIC_KEYS is required for production firmware"
end

# Use Ringlogger as the logger backend and remove :console.
# See https://ring-logger.hexdocs.pm/readme.html for more information on
# configuring ring_logger.

config :logger, backends: [RingLogger]

# Use shoehorn to start the main application. See the shoehorn
# library documentation for more control in ordering how OTP
# applications are started and handling failures.

config :shoehorn,
  init: [:nerves_runtime, :vintage_net],
  handler: NervesGate.ShoehornHandler,
  retry_applications: [:nerves_runtime],
  retry_attempts: 1,
  resume_application: :nerves_gate

# NervesGate owns trial validation so firmware is never committed merely because
# OTP started. The system boot contract performs fallback on any unvalidated reboot.
config :nerves_runtime, startup_guard_enabled: false

config :nerves_gate,
  startup_gate_enabled: true,
  firmware: [
    platform: NervesGate.Firmware.Platform.Nerves,
    enabled: true,
    automatic_fallback: true,
    system: "nerves_system_nerves_gate",
    repository: "sid2baker/nerves_gate",
    api_url: release_api_url,
    allow_insecure_http: URI.parse(release_api_url).scheme == "http",
    manifest_public_keys: firmware_public_keys,
    fwup_public_keys: firmware_public_keys,
    reboot_method:
      if(config_env() == :dev and Mix.target() == :x86_64,
        do: :kernel_sysrq,
        else: :nerves_runtime
      ),
    free_space_bytes:
      if(config_env() == :dev and Mix.target() == :x86_64,
        do: 2 * 1024 * 1024 * 1024,
        else: nil
      ),
    trial_timeout: String.to_integer(System.get_env("NERVES_GATE_TRIAL_TIMEOUT_MS", "900000")),
    stable_window: String.to_integer(System.get_env("NERVES_GATE_STABLE_WINDOW_MS", "60000")),
    health_grace: String.to_integer(System.get_env("NERVES_GATE_HEALTH_GRACE_MS", "120000"))
  ]

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
