# Changelog

## Unreleased

### Breaking changes

- Workbench is one attachable hidden development node with a verified gateway directory and shared projection-driven pages for physical and simulated gateways. Disconnected gateways retain their last-seen time. Pi and Mix clients use distribution; the internal HTTP control API, split physical pages, `mix app.console`, separate simulator BEAM and private EPMD namespace are removed.
- QEMU management uses explicitly prepared bridge/TAP hardware and firmware-owned EPMD at the guest IP. Run `mix dev.network setup --subnet <private-/24>` before QEMU use and explicit cleanup afterward. Existing disposable disks with loopback-index serials require an authorized reset; physical devices are not migrated.

- Renamed the physical inventory domain to `NervesGate.Hardware` and its adapter configuration to `hardware_adapter`, with no old-name aliases.

- Hardware now exposes exclusive plugin assignments, not built-in capture/Modbus diagnostics. Removed bus diagnostic commands and SDK CAN/RS485 transport proxies; plugins own direct supervised I/O. Assignment and enablement changes require checked stop of both affected plugins and leave them stopped.

- Trusted plugins are selected at firmware build time and managed by `NervesGate.Plugins` at `/plugins`; the application store, GitHub app-release workflow and old gateway application routes/APIs are removed. Schema-2 plugin metadata records immutable artifact identity and source. Old application metadata blocks activation without automatic migration or erasure. Stateful SDK resource access requires managed activation membership; raw IEx/RPC callers use administrative domain APIs.
- The SDK uses the fixed firmware runtime bridge rather than configurable backends; absent firmware returns `:runtime_unavailable`. Plugin packages reject contributed native payloads and direct NIF loaders.

- Removed the equipment observation domain and SDK compatibility API; status schema is now 11. Device maintenance requires the current compiled APIs with no old-firmware identity fallback. SSH key initialization no longer imports an old NervesSSH key store: provision current configured keys explicitly before deployment.

- Hardware exposes gateway resources, not equipment identities or protocol editors. Equipment label/scan/share commands and legacy `equipment`/joined network configuration are removed. Saved legacy settings are rejected with migration guidance, never rewritten or erased automatically; existing devices need separately authorized migration. Applications own equipment configuration and local addressing through process-owned SDK leases.

- Administrative commands now live on their owning `NervesGate.Network`, `Cellular`, `Remote`, `Hardware`, `Indicators`, `SSH` and `Storage` modules. `NervesGate` exposes only `status/0` and `subscribe/0`; use `NervesGate.System.info/0` for identity and explicit domain reads for private login URLs/cookies. Server-injection options and remote gateway-command routing are removed.
- Administrative status/projections use schema 11: `hardware` replaces `buses`, `device` replaces `backend`, `remote` replaces `remote_access`, and action names include `indicators.identify`; built-in bus diagnostic actions are removed. SDK observations remain a separate typed contract.
- Host modules/application are `Workbench`, `WorkbenchWeb` and `:nerves_gate_workbench`; host session metadata uses `WORKBENCH_*` and `_build/workbench/`. Scenarios share one `Scenarios` catalogue/runner and explicit owned-QEMU fixture. Update host tools and disposable guest firmware together; old live sessions and firmware are not supported by the new tools.
- Cellular code now lives under `NervesGate.Cellular`, including `Cellular.Modem`. Saved interface settings referencing an unavailable modem driver fail startup before UART access; there is no automatic migration or erasure. Physical deployment requires a separately authorized settings reprovision/reset procedure.
- Use the platform checkout as the developer environment. Create/open ordinary SDK applications directly in the workbench, or use `mix app.new PATH`; no generator archive or solution manifest is needed.
- App test, package and install commands take an application directory. The optional `mix dev PATH` opens that application; plain `mix dev` starts the workbench. QEMU scenarios use `mix test.qemu`.
- Firmware and simulator versions follow the platform version. The SDK retains its independent version and Hex package; firmware, simulator and generator are no longer published on Hex. Existing 0.1.x packages remain available.
- Simulated devices use firmware built locally from the platform checkout by default.
- The simulator is part of the root project: `NervesGateSim` modules are now `Simulator` in `lib/simulator/`, and bench configurations moved from `sim/priv/qemu/` to `priv/simulator/`. Gateway discovery belongs to the workbench.

### Added

- Gateway Plugins page with explicit Start/Stop and optional plugin-owned LiveComponents. Firmware bundles the selected pure-BEAM dependency closures and a verified inventory; bundled code needs no SD card. Saved unavailable versions require explicit selection, never silent replacement. Uncertain commands are never replayed.
- Read-only Modbus TCP/RTU plugin using yamodbus, with explicit per-device configuration/connection, bounded holding/input-register polling and connection cleanup. RTU requires an enabled exclusive RS485 assignment, operator approval and firmware-provided circuits_uart; the initial profile is 9600 8N1. No equipment connections occur at startup.
- Subnet-router interface picker uses gateway observations and disables Internet, claimed, addressed and operator-disabled ports with explanations.

- Verified retained archives and exact extracted content/modes for every activation, with no same-version replacement. Explicit verified module preload, bounded lifecycle workers, generation-fenced SDK resources and one checked cleanup/rollback path preserve actual-PID ownership and fail closed on uncertain effects.

- Hardware shows Internet and application interfaces, bus presence and exclusive assigned plugin identity. Remote access groups Tailscale with explicitly revealed developer runtime credentials; application storage lives under Settings. Replaced equipment/distribution/storage URLs are removed, not retained as aliases.
- Application-enabled isolated Ethernet can be claimed with transient addressing and explicitly advertised through the existing tailnet. Journaled route ownership, owner-exit cleanup and blocked unknown outcomes prevent unowned route adoption or premature address removal.
- Firmware-selected Tailnet subnet-router plugin, stopped on first discovery and never automatically configured or sharing-enabled.
- Reviewed physical application installation over distribution: private package snapshot, typed one-use device confirmation, device-side hash/app/version/storage checks, and verified stopped/disabled state. Existing apps are rejected, never silently upgraded or started.
- Physical readiness and operator-assisted Ethernet/cellular failover scenarios over distribution. Reboot/reset retain physical-button authority, with bounded identity/new-boot/health observations.
- Public firmware identity includes the source commit separately from its semantic version; source-archive builds require `SOURCE_REVISION`.

- Developer workbench factory provisioning for EC100 over USB MASKROM, with a
  reviewed image, a full eMMC backup by default (skipping it needs a stronger
  confirmation), explicit physical-board/erase confirmation, verified readbacks
  before reset. Healthy boot is checked separately through the verified gateway directory.
- EC100 4G support for the Quectel EG800AK-GL using CDC-ECM, an operator APN and
  the existing Internet-source and Ethernet-backup settings, the network's default
  APN unless overridden, and SIM PIN commissioning with an optional SIM-bound saved
  PIN for automatic unlock. The USB recovery link stays separate.
- Cellular inbound protection is installed before saved network connections are
  restored, keeping unsolicited mobile traffic away from the unauthenticated UI
  and SSH. Firmware refuses startup if this protection cannot be installed.
- The developer workbench creates/opens applications and offers explicit test, package, simulator install and EC100/QEMU firmware-build actions.
- Physical firmware updates use verified-host SSH public-key authentication, image/device compatibility review, SHA-256 and a single-use typed confirmation before upload and reboot. No initial provisioning or disk formatting is performed.
- Local mDNS discovery lists advertised Nerves Gate gateways without subnet scans or VPN changes. Known IPv4 addresses can be added manually. New firmware advertises public device metadata; discovery is not authentication.
- Generated apps demonstrate pure decisions over SDK observations and ordinary host unit tests. Generated Elixir files are formatted.
- Prerequisite errors include Linux installation guidance and the macOS Linux-VM route.

### Fixed

- Hardware-resource queries skip unassigned and disabled ports instead of crashing plugin management when opening the Modbus RTU configuration.
- Physical firmware uploads use verified SSH; identity, health and plugin-artifact checks use distribution before upload and new-boot verification.

- Manual device entries accept DNS names, including Tailscale names, as well as IPv4 addresses.
- Workstation commands select the host even when the shell carries a device Mix target; firmware commands retain their selected target.
- Clean device builds initialize the Nerves toolchain before compiling native dependencies; workstation binaries are not shipped to musl guests.
- Boot failures retain bounded, secret-free domain liveness diagnostics separately from the gateway status query.
- Invalid RTC time handling uses the `nerves_time` 0.4.14 fix.
- Firmware and app builds no longer occasionally crash with `:epipe` and lose
  their exit status when a command finishes.

### Security

- Updated Bandit to 1.14.0 and Plug.Crypto to 2.2.1 to address known HTTP-server and secret-exposure vulnerabilities. Firmware, workstation and starter-app dependency locks use matching patched shared libraries; rebuild firmware and app packages together.

Earlier component history is preserved in the [firmware](https://github.com/sid2baker/nerves_gate/tree/b7f474dd5639e55ef31fbd3e7dc35de786ade27a), [simulator](https://github.com/sid2baker/nerves_gate/tree/7fe074e82db853fd344fb12f75730ad91016b963) and [generator](https://github.com/sid2baker/nerves_gate/tree/9d1b3d9854c3e05fdbcc0e65b12db5cda37b7eb4) source commits.
