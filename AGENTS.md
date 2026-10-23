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
`sdk/` and `firmware/` remain independent Mix projects. Root host checks use native
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
- `firmware/lib/nerves_gate_web/`: gateway UI served by EC100 and QEMU; shared components also serve the workbench.
- `firmware/lib/nerves_gate/{sdk_backend,apps,storage}.ex`: SDK translation, trusted
  app lifecycle and SD storage. `NervesGate.Buses` owns CAN/RS485 access.
- `sdk/`: typed app contract and packaging. Never expose firmware status maps or
  administrative commands through the SDK.
- `lib/simulator.ex`, `lib/simulator/`: owned real QEMU hardware; `priv/simulator/`
  holds the simulator-node script and bench configurations.
- `lib/simulator/qemu_tests.ex`: shared UI/CLI/CI admission and reservations;
  independent devices can run concurrently; `devices: :all` reserves every device.
- `lib/dev/scenarios/`: portable platform/SDK contract scenarios; `Dev.Scenarios`
  checks device/fixture requirements before preparation. `Dev.TestDevice` reads
  running targets; `Dev.TestFixture` separates explicitly owned bench controls.
- `lib/simulator/scenarios/`: QEMU-specific integration scenarios. Shared scenarios
  also run through the existing QEMU owner. No hardware mocks or fake SDK backends.
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
- Open a device's gateway link for its UI. After gateway Elixir/HEEx changes, rebuild firmware and Reset/Start the disposable QEMU device.
- Root `mix ci` runs all host checks/tests and may be run by agents. Never weaken
  `--check-locked`, compiler checks or deadlines.
- `mix format --force` formats the root and subsystems, excluding system inputs.
- Root `mix firmware [x86_64 | ec100] [--env dev | prod]`, workbench Build and local
  QEMU builds prepare assets on the host before isolated target compilation.
  `mix ci` builds assets too; `mix assets.build` in `firmware/` is only an
  asset-only diagnostic. Commit `firmware/priv/static/assets/` with their sources.
- Test changed behaviour. Documentation-only changes need no QEMU checks.
- Root and firmware share `VERSION`/`CHANGELOG.md`; SDK and systems keep
  independent versions. Only SDK is published on Hex. Tags/releases, retirement,
  pushes and physical-device operations require a request.
- Release checks live under `lib/dev/`. Protected CI is the publisher; do not put
  publishing credentials into the workbench process.

## Start here

- [Architecture](docs/architecture.md)
- [Development](docs/development.md)
- [App development](docs/app-development.md)
- [Public API](firmware/lib/nerves_gate.ex)
