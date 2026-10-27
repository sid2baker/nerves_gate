# Changelog

## Unreleased

### Breaking changes

- Application metadata is current-only schema 1 with immutable artifact SHA/name/module catalogs. Old records are blocked without migration or reset, while gateway management remains available. Stateful SDK resource access now requires managed activation membership; raw IEx/RPC callers use administrative domain APIs.

- Removed the equipment observation domain and SDK compatibility API; status schema is now 9. Device maintenance requires the current compiled APIs with no old-firmware identity fallback. SSH key initialization no longer imports an old NervesSSH key store: provision current configured keys explicitly before deployment.

- Hardware exposes gateway resources, not equipment identities or protocol editors. Equipment label/scan/share commands and legacy `equipment`/joined network configuration are removed. Saved legacy settings are rejected with migration guidance, never rewritten or erased automatically; existing devices need separately authorized migration. Applications own equipment configuration and local addressing through process-owned SDK leases.

- Administrative commands now live on their owning `NervesGate.Network`, `Cellular`, `Remote`, `Buses`, `Indicators`, `SSH` and `Storage` modules. `NervesGate` exposes only `status/0` and `subscribe/0`; use `NervesGate.System.info/0` for identity and explicit domain reads for private login URLs/cookies. Server-injection options and remote gateway-command routing are removed.
- Administrative status/projections use schema 9: `device` replaces `backend`, `remote` replaces `remote_access`, and action names include `buses.configure`, `buses.capture`, `buses.modbus_read` and `indicators.identify`. SDK observations remain a separate typed contract.
- Host modules/application are `Workbench`, `WorkbenchWeb` and `:nerves_gate_workbench`; host session metadata uses `WORKBENCH_*` and `_build/workbench/`. Scenarios share one `Scenarios` catalogue/runner and explicit owned-QEMU fixture. Update host tools and disposable guest firmware together; old live sessions and firmware are not supported by the new tools.
- Cellular code now lives under `NervesGate.Cellular`, including `Cellular.Modem`. Saved interface settings referencing an unavailable modem driver fail startup before UART access; there is no automatic migration or erasure. Physical deployment requires a separately authorized settings reprovision/reset procedure.
- Use the platform checkout as the developer environment. Create/open ordinary SDK applications directly in the workbench, or use `mix app.new PATH`; no generator archive or solution manifest is needed.
- App test, package and install commands take an application directory. The optional `mix dev PATH` opens that application; plain `mix dev` starts the workbench. QEMU scenarios use `mix test.qemu`.
- Firmware and simulator versions follow the platform version. The SDK retains its independent version and Hex package; firmware, simulator and generator are no longer published on Hex. Existing 0.1.x packages remain available.
- Simulated devices use firmware built locally from the platform checkout by default.
- The simulator is part of the root project: `NervesGateSim` modules are now `Simulator` in `lib/simulator/`, and bench configurations moved from `sim/priv/qemu/` to `priv/simulator/`. Gateway discovery belongs to the workbench.

### Added

- Gateway Applications page with optional app-owned LiveComponents, explicit Start/Stop controls and reviewed install/upgrade from first-party GitHub releases. The device checks compatibility and archive identity; new installs remain stopped and uncertain commands are never replayed. Subnet-router configuration and sharing controls are supplied by the app.

- Verified retained archives and exact extracted content/modes for every activation, with no same-version replacement. Explicit verified module preload, bounded lifecycle workers, generation-fenced SDK resources and one checked cleanup/rollback path preserve actual-PID ownership and fail closed on uncertain effects.

- Hardware shows Internet and application interfaces, claim/subscriber usage and explicit passive diagnostics. Remote access groups Tailscale with explicitly revealed developer runtime credentials; application storage lives under Settings. Replaced equipment/distribution/storage URLs are removed, not retained as aliases.
- Application-enabled isolated Ethernet can be claimed with transient addressing and explicitly advertised through the existing tailnet. Journaled route ownership, owner-exit cleanup and blocked unknown outcomes prevent unowned route adoption or premature address removal.
- Optional Tailnet subnet-router starter application, never automatically installed, started or enabled.
- Reviewed physical application installation over verified SSH: private package snapshot, typed one-use device confirmation, device-side hash/app/version/storage checks, and verified stopped/disabled state. Existing apps are rejected, never silently upgraded or started.
- Physical read-only hardware readiness/diagnostics and operator-assisted Ethernet/cellular failover with independent USB management. Reboot/reset retain physical-button authority, with bounded identity/new-boot/health observations.
- Public firmware identity includes the source commit separately from its semantic version; source-archive builds require `SOURCE_REVISION`.

- Developer workbench factory provisioning for EC100 over USB MASKROM, with a
  reviewed image, a full eMMC backup by default (skipping it needs a stronger
  confirmation), explicit physical-board/erase confirmation, verified readbacks
  before reset and a read-only USB reconnection check afterwards.
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
- `mix app.console` prints the SSH command only while an owned simulated device has idle Manual control.
- Generated apps demonstrate pure decisions over SDK observations and ordinary host unit tests. Generated Elixir files are formatted.
- Prerequisite errors include Linux installation guidance and the macOS Linux-VM route.

### Fixed

- Physical SSH responses ignore stale notifications from earlier channels on the same connection; only the active channel can complete or reject an operation.
- CAN configuration is rejected while applications hold active receive subscriptions.

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
