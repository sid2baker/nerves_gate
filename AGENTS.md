# Nerves Gate

## KISS — Keep it stupidly simple

- Use the simplest design that solves today's problem.
- Prefer direct code and ordinary Elixir/OTP. Minimize concepts and indirection, not changed lines.
- Keep one clear way to do each job. Remove obsolete code; avoid speculative frameworks and configuration layers.
- Document how the system works now, not the history of replaced code.

## Elixir only

- Write application logic, tests and development tooling in Elixir.
- Prefer Elixir libraries, such as Req for HTTP, over shelling out.
- Use external tools for actual firmware, networking and QEMU operations.

## Structure and ownership

Independent Mix projects (no umbrella, no shared version). The root `mix.exs` only orchestrates them natively with `Mix.Project.in_project/4`; never shell out to `mix` for that.

- `firmware/lib/nerves_gate/`: device domains. They own commands, admission, deadlines and persistence.
- `firmware/lib/nerves_gate.ex`: public API. Keep `NervesGate.status/1` as a direct domain query.
- `firmware/lib/nerves_gate_web/`: gateway UI, shared by EC100, QEMU and `mix dev.ui`.
- `firmware/lib/nerves_gate/sdk_backend.ex`, `apps.ex`, `storage.ex`: SDK translation, application lifecycle and SD storage. `NervesGate.Buses` owns all CAN/RS485 access.
- `sdk/`: pure Elixir application API. SDK structs are the contract; never expose firmware status maps or administrative commands through it.
- `sim/`: the only simulator. It runs real firmware in QEMU and requires QEMU; there is no in-memory fallback or fake SDK backend.
- `sim/lib/nerves_gate_sim/simulator.ex` and `simulator/`: host-only lifecycle and owned QEMU hardware.
- `sim/lib/nerves_gate_sim_web/`: simulator site, with configuration at `/` and tests at `/devices/:id`.
- `sim/lib/nerves_gate_sim/qemu_tests.ex`: shared UI/CLI/CI admission and per-device reservations. Independent devices can run concurrently; `devices: :all` reserves every device.
- `sim/scenarios/`: repository-only shared QEMU scenarios. Extend these for real I/O checks; do not add fake hardware backends.
- `firmware/test/unit/`: fast host tests for pure validation, policies and codecs. These require no hardware or QEMU.
- `tools/`: private release tools and their tests. Never publish this project.
- `firmware/config/firmware.exs`: shared device services; `sim/config/`: workstation services.
- `systems/`: Nerves systems. Their package files are artifact fingerprint inputs: change them only with a version bump.
- Projections are read models. LiveViews subscribe to the device-owned stream and keep drafts separate. UI availability never replaces backend validation.
- Preserve boundaries without adding layers just to enforce them.

## Safety

- Tests use only disposable, supervised QEMU devices on private socket networks. Never attach drivers to arbitrary VMs.
- Never flash physical devices, change workstation networking/VPN, or stop unrelated processes without explicit authorization.
- Keep private login URLs, distribution cookies, CSRF tokens and other secrets out of projections, notifications and logs.

## Development and validation

- Run commands from the repository root. `mix setup` prepares all projects and QEMU development.
- The user owns `mix dev` and starts devices on the simulator overview. Do not launch/stop that session or boot devices without authorization. If unavailable, ask the user to start it.
- Run focused checks with `mix test.firmware --only <scenario> [--device <id>]` against that session. Never use `--ci` to launch another bench.
- `mix dev.ui <device-id | nerves_gate@IPv4> [--port 4001]` serves the gateway UI with code reload. It connects to a running device; it does not boot one.
- Root `mix ci` (all host checks and unit tests) needs no devices and may be run by agents. Inside a project, set `NERVES_GATE_LOCAL_DEPS=1`.
- Build changed assets with `NERVES_GATE_LOCAL_DEPS=1 mix assets.build` in `firmware/` and commit `firmware/priv/static/assets/` with their sources.
- Keep code formatted and test changed behavior. Documentation-only changes need no QEMU checks.
- `mix test.firmware --ci` boots an isolated bench and belongs to the user. Report focused checks; do not run it without authorization.
- Each project has its own VERSION and CHANGELOG with namespaced tags (`sdk/vX.Y.Z`, …). Do not publish, tag or push without a request.

## Start here

- [Architecture and source map](docs/architecture.md)
- [Development](docs/development.md)
- [Public API](firmware/lib/nerves_gate.ex)
