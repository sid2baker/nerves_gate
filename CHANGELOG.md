# Changelog

## Unreleased

### Breaking changes

- Workbench Tailnet discovery selects online peers tagged `tag:nerves-gate`
  instead of device names beginning with `nerves-gate`. Tag gateways in Tailscale
  or add them manually; untagged name matches are no longer candidates.

- Hardware setup is plugin-first. `Plugins.review_assignment/4` and `confirm_assignment/1` replace `assign_port/5`; stale reviews fail before effects. Gateway-owned review survives plugin UI cleanup and offers explicit target-plugin startup after checked assignment. Saved owner/disabled intent is preserved; no connection or sharing command is replayed. Modbus 0.4.2 and Tailnet 0.1.9 expose setup links; new version-scoped configuration is not imported.
- Physical firmware uploads pin the SSH host-key fingerprints the gateway reports over authenticated distribution (`NervesGate.SSH.host_key_fingerprints/0`) instead of reading `~/.ssh/known_hosts`. Factory-reset gateways need no manual trust step; firmware without this function is rejected and needs one explicitly authorized external update. SSH failures report their reason.
- Workbench session operations verify checkout/session identity and protocol inputs; stale sessions require coordinated replacement. Use explicit `mix simulator.start/stop/reset`, `mix scenario.run ID --device TARGET` and `mix scenario.ci ID --device ID` instead of `mix test.qemu`. Plugin installs also require an explicit target and share the UI's reviewed Jobs workflow. No compatibility task aliases or automatic first-device selection remain.
- Plugin terminology replaces application terminology everywhere, without aliases or migration: network role `"plugin"` (saved `"application"` roles are rejected), SD mount `/mnt/plugins` with filesystem label `plugins`, board keys `plugins_device`/`plugins_mount`, `plugin_*` error codes, `/plugins/:plugin` route and the `"plugin"` review key and upload path for reviewed installs. Deployed gateways and SD cards need an explicitly authorized reprovision/reformat; Workbench and firmware must be updated together.
- Hardware excludes Internet-owned LANs. Free LANs use the same reviewed exclusive plugin assignment as RS485/CAN; local Ethernet claims require that assignment, and assigned LANs cannot be repurposed for Internet until disabled and unassigned. The separate network application-enable editor is removed.
- Workbench is one attachable hidden development node with a verified gateway directory and shared projection-driven pages for physical and simulated gateways. Disconnected gateways retain their last-seen time. Pi and Mix clients use distribution; the internal HTTP control API, split physical pages, `mix app.console`, separate simulator BEAM and private EPMD namespace are removed.
- QEMU management uses explicitly prepared bridge/TAP hardware and firmware-owned EPMD at the guest IP. Run `mix dev.network setup --subnet <private-/24>` before QEMU use and explicit cleanup afterward. Existing disposable disks with loopback-index serials require an authorized reset; physical devices are not migrated.

- Renamed the physical inventory domain to `NervesGate.Hardware`, with no old-name aliases.
- Board hardware is declared as data: `ports`, `indicators` (LED names and recovery button input) and `data` (`{:ext4, sysfs_dev}` or `{:ubifs, volume}`) replace `hardware_adapter`, `indicators_adapter`, `recovery_adapter` and `data_partition`. `NervesGate.Recovery` replaces `NervesGate.Recovery.EC100`; there are no aliases.

- Hardware now exposes exclusive plugin assignments, not built-in capture/Modbus diagnostics. Removed bus diagnostic commands and SDK CAN/RS485 transport proxies; plugins own direct supervised I/O. Assignment and enablement changes require checked stop of both affected plugins; target startup is separately explicit in the reviewed operation.

- Trusted plugins are selected at firmware build time and managed by `NervesGate.Plugins` at `/plugins`; the application store, GitHub app-release workflow and old gateway application routes/APIs are removed. Schema-2 plugin metadata records immutable artifact identity and source. Old application metadata blocks activation without automatic migration or erasure. Stateful SDK resource access requires managed activation membership; raw IEx/RPC callers use administrative domain APIs.
- The SDK uses the fixed firmware runtime bridge rather than configurable backends; absent firmware returns `:runtime_unavailable`. Plugin packages reject contributed native payloads and direct NIF loaders.

- Removed the equipment observation domain and SDK compatibility API; status schema is now 11. Device maintenance requires the current compiled APIs with no old-firmware identity fallback. SSH key initialization no longer imports an old NervesSSH key store: provision current configured keys explicitly before deployment.

- Hardware exposes gateway resources, not equipment identities or protocol editors. Equipment label/scan/share commands and legacy `equipment`/joined network configuration are removed. Saved legacy settings are rejected with migration guidance, never rewritten or erased automatically; existing devices need separately authorized migration. Applications own equipment configuration and local addressing through process-owned SDK leases.

- Administrative commands now live on their owning `NervesGate.Network`, `Cellular`, `Remote`, `Hardware`, `Indicators`, `SSH` and `Storage` modules. `NervesGate` exposes only `status/0` and `subscribe/0`; use `NervesGate.System.info/0` for identity and explicit domain reads for private login URLs/cookies. Server-injection options and remote gateway-command routing are removed.
- Administrative status/projections use schema 11: `hardware` replaces `buses`, `device` replaces `backend`, `remote` replaces `remote_access`, and action names include `indicators.identify`; built-in bus diagnostic actions are removed. SDK observations remain a separate typed contract.
- Host modules/application are `Workbench`, `WorkbenchWeb` and `:nerves_gate_workbench`; host session metadata uses `WORKBENCH_*` and `_build/workbench/`. Scenarios share one `Scenarios` catalogue/runner and explicit owned-QEMU fixture. Update host tools and disposable guest firmware together; old live sessions and firmware are not supported by the new tools.
- Cellular code now lives under `NervesGate.Cellular`, including `Cellular.Modem`. Saved interface settings referencing an unavailable modem driver fail startup before UART access; there is no automatic migration or erasure. Physical deployment requires a separately authorized settings reprovision/reset procedure.
- Use the platform checkout as the developer environment. Create/open ordinary SDK plugin projects under **Develop → Plugins** (`/develop/plugins`), or use `mix plugin.new PATH`; no generator archive or solution manifest is needed. The former `mix app.*` tasks, `/develop/applications` routes and `Workbench.Applications`/`AppInstall` modules are renamed without aliases.
- `mix plugin.test`, `plugin.package` and `plugin.install` take a plugin directory. The optional `mix dev PATH` opens that plugin project; plain `mix dev` starts the workbench. QEMU scenarios use `mix scenario.run ID --device TARGET`; the SD development-artifact scenario is `sd_plugins`.
- Firmware and simulator versions follow the platform version. The SDK retains its independent version and Hex package; firmware, simulator and generator are no longer published on Hex. Existing 0.1.x packages remain available.
- Simulated devices use firmware built locally from the platform checkout by default.
- The simulator is part of the root project: `NervesGateSim` modules are now `Simulator` in `lib/simulator/`, and bench configurations moved from `sim/priv/qemu/` to `priv/simulator/`. Gateway discovery belongs to the workbench.

### Added

- EM300 (RK3506B, SPI NAND) firmware target and Workbench support for builds, MASKROM provisioning, firmware updates and the gateway directory. The unpublished `nerves_system_em300` builds only with `NERVES_GATE_LOCAL_DEPS=1`; the modem, LEDs, recovery button and extension I/O stay disabled until qualified on hardware.
- Gateway **I/O** page (`/io`): every plugin input and output with availability, latest Reading, quality, monotonic freshness, writer, desired target and Status (`Confirmed`/`Pending`/`Mismatch`/`Unknown`) with its reason, Apply outcome, evidence and the plugin's declared release behaviour. Manual claim/set/release goes through `NervesGate.IO.Manual`, the single manual writer that owns claims independently of browser tabs and shares the I/O domain's exclusive admission. `NervesGate.IO.snapshot/0` reads all endpoints; output snapshots add caller-relative `owned?`.
- Read-only Workbench diagnostics and inspection: `mix dev.doctor`, `mix gateway.list/inspect/logs` and `mix dev.job [ID]`. Jobs and Runner expose owner/session-qualified operation IDs and bounded history. Wait timeouts do not cancel work; uncertain outcomes block further maintenance/control instead of authorizing retries.
- Plugin configuration storage: one opaque, atomically replaced term per running plugin version under the plugin's SD data directory, keyed by the actual managed caller's activation. Older versions' terms are preserved; restores decode safely and never delete corrupt files.
- Firmware `NervesGate.IO` domain with persisted typed definitions (catalogue schema 2), managed plugin bindings, latest Readings, coalesced dirty notifications and exclusive process-owned output Authority. Every claim starts a new claim epoch; the bound handler reports Apply outcomes for the current epoch and Desire, and stale reports are rejected. `NervesGate.IO.OutputStatus` derives output Status from the Apply outcome and declared evidence inputs (stronger roles win; only Readings received after the Desire changed plus settle time count; Apply alone never confirms). Desires are runtime-only; writer/binding loss clears Authority without an implicit device write. Plugins own reconciliation and release behaviour. Unsupported or unreadable saved definitions disable I/O without stopping the controller or rewriting the file. `NervesGateSDK.IO` calls run in the actual managed caller.
- `mix firmware.update GATEWAY [IMAGE] [--sha256 SHA]` prints read-only gateway state, reviews the image, confirms once (interactively or by exact SHA-256), waits for the verified boot and prints the state again.

- Gateway Plugins page with explicit Start/Stop and optional plugin-owned LiveComponents. Firmware bundles the selected pure-BEAM dependency closures and a verified inventory; bundled code needs no SD card. Saved unavailable versions require explicit selection, never silent replacement. Uncertain commands are never replayed.
- Modbus TCP/RTU plugin using yamodbus with client and server definitions saved through plugin configuration storage. Explicitly started runtimes expose mapped holding registers and coils as platform inputs and repeatable outputs with linked feedback; clients reconcile the latest desire. RTU requires an enabled exclusive RS485 assignment, operator approval and firmware-provided circuits_uart. Startup and saving never communicate.
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

- Explicit `mix dev.network setup` can recreate an unchanged recorded QEMU management network after reboot when every bridge/TAP is absent. Partial or conflicting interfaces still require inspection and cleanup; ordinary startup never changes host networking.
- Gateway status, hardware and plugin-port authorization no longer re-verify every plugin archive on each read; status reads that took over a second (and timed out under load) now return in milliseconds.
- Boot no longer fails and restarts when the first `fwup status` after startup exceeds `Nerves.Runtime.KV`'s one-second timeout.
- Stopping or uninstalling a plugin that holds a local LAN lease no longer reports `generation_cleanup_pending` when the platform has already begun releasing that lease.
- An unexpected storage setup worker exit is logged with its reason.
- Storage commissioning while a plugin operation is reconciling the card reports `operation_in_progress` instead of claiming plugins are installed.
- A storage owner busy probing or mounting the card no longer crashes the SDK backend or other callers; `NervesGate.Storage.root/0` reports `:storage_unavailable`, as documented for plugin configuration storage.
- Valid saved I/O definitions no longer prevent firmware startup after a cold boot. The catalogue loads its compiled schema before safe decoding; unknown atoms and malformed files remain rejected without rewriting saved state.
- Releasing a plugin's local LAN lease without a generation drain no longer crashes `NervesGate.Network` (and, through it, I/O and Plugins).
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
