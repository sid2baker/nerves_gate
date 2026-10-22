# Nerves Gate

## KISS

- Prefer direct Elixir/OTP and the simplest design solving today's problem.
- Keep one implementation per operation. Remove obsolete code; avoid speculative
  frameworks, plugin registries and configuration layers.
- Document the current system, not replaced implementations.

## Elixir only

- Application logic, tests and development tooling are Elixir. Prefer Req for HTTP.
- External tools are for actual firmware, networking, QEMU and Git operations.

## Structure and ownership

The root is the host-only developer platform (`:nerves_gate_dev`), not an umbrella.
Subsystems remain independent Mix projects. Root host checks use native
`Mix.Project.in_project/4`; do not shell out to Mix for repository host orchestration.
Device builds and user apps are exceptions: they require isolated supervised
OS processes, never device-target compilation in the workbench VM.

- `lib/dev/`: sessions, app projects, LAN discovery, builds, operation coordination and release tools.
- `lib/dev_web/`: workbench UI and CLI API. UI and CLI call ordinary shared APIs,
  not Mix tasks. Backend validation is authoritative.
- `config/`, `priv/dev/`: workstation configuration and owned launch scripts.
- `priv/templates/`: ordinary SDK app scaffolding; app projects live outside this checkout.
- `firmware/lib/nerves_gate/`: device domains own admission, deadlines and persistence.
- `firmware/lib/nerves_gate.ex`: public API; status stays a direct domain query.
- `firmware/lib/nerves_gate_web/`: gateway UI shared by EC100, QEMU and `mix dev.ui`.
- `firmware/lib/nerves_gate/{sdk_backend,apps,storage}.ex`: SDK translation, trusted
  app lifecycle and SD storage. `NervesGate.Buses` owns CAN/RS485 access.
- `sdk/`: typed app contract and packaging. Never expose firmware status maps or
  administrative commands through the SDK.
- `sim/lib/nerves_gate_sim/simulator.ex`, `simulator/`: owned real QEMU hardware.
- `sim/lib/nerves_gate_sim/qemu_tests.ex`: shared UI/CLI/CI admission and reservations;
  independent devices can run concurrently; `devices: :all` reserves every device.
- `sim/scenarios/`: real-QEMU scenarios compiled by the root. Extend them for I/O
  checks, not hardware mocks or fake SDK backends.
- `firmware/test/unit/`: pure policy, validation and codec tests; no devices.
- `systems/`: Nerves systems. Artifact input changes require a system version bump.
- Projections are read models. LiveViews subscribe to device-owned streams and
  keep drafts separate. UI availability never replaces backend validation.

## Safety

- Tests use only disposable supervised QEMU devices on private socket networks.
  Never attach drivers to arbitrary VMs.
- Never flash physical hardware, change workstation networking/VPN or stop
  unrelated processes without explicit authorization.
- Never expose private login URLs, cookies, CSRF tokens, keys or VM identity disks
  in projections, logs, notifications or uploaded artifacts.

## Development and validation

- Run commands at the root. `mix setup` prepares projects and artifacts without
  building device firmware or booting devices.
- The user owns `mix dev [APP_DIRECTORY]`. Do not start/stop that session or boot its
  devices without authorization; ask the user to start it if unavailable.
- Focused checks use `mix test.qemu --only ID [--device ID]` against that session.
  `--ci` creates a separate disposable bench and needs explicit authorization.
- `mix dev.ui DEVICE [--port 4001]` connects to a running device, never boots one.
- Root `mix ci` runs all host checks/tests and may be run by agents. Never weaken
  `--check-locked`, compiler checks or deadlines.
- `mix format --force` formats the root and subsystems, excluding system inputs.
- Build changed assets in `firmware/` with `mix assets.build`; commit
  `firmware/priv/static/assets/` with their sources.
- Test changed behaviour. Documentation-only changes need no QEMU checks.
- Root, firmware and sim share `VERSION`/`CHANGELOG.md`; SDK and systems keep
  independent versions. Only SDK is published on Hex. Tags/releases, retirement,
  pushes and physical-device operations require a request.
- Release checks live under `lib/dev/`. Protected CI is the publisher; do not put
  publishing credentials into the workbench process.

## Start here

- [Architecture](docs/architecture.md)
- [Development](docs/development.md)
- [App development](docs/app-development.md)
- [Public API](firmware/lib/nerves_gate.ex)
