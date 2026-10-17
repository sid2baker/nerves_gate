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

- `lib/nerves_gate/`: device domains. They own commands, admission, deadlines and persistence.
- `lib/nerves_gate.ex`: public API. Keep `NervesGate.status/1` as a direct domain query.
- `lib/nerves_gate_web/`: gateway UI, shared by EC100, QEMU and `mix dev.ui`.
- `dev/simulator.ex` and `dev/simulator/`: host-only lifecycle and owned QEMU hardware.
- `dev/simulator_web/`: simulator site, with configuration at `/` and tests at `/devices/:id`.
- `test/support/runner.ex`: shared UI/CLI/CI admission and per-device reservations. Independent devices can run concurrently; `devices: :all` reserves every device.
- `test/scenarios/`: shared QEMU scenarios. Extend these rather than adding a hardware-mock suite.
- `config/firmware.exs`: shared device services; `config/host.exs`: workstation services.
- Projections are read models. LiveViews subscribe to the device-owned stream and keep drafts separate. UI availability never replaces backend validation.
- Preserve boundaries without adding layers just to enforce them.

## Safety

- Tests use only disposable, supervised QEMU devices on private socket networks. Never attach drivers to arbitrary VMs.
- Never flash physical devices, change workstation networking/VPN, or stop unrelated processes without explicit authorization.
- Keep private login URLs, distribution cookies, CSRF tokens and other secrets out of projections, notifications and logs.

## Development and validation

- `mix setup` prepares QEMU development; `mix deps.get` only fetches dependencies.
- The user owns `mix dev` and starts devices on the simulator overview. Do not launch/stop that session or boot devices without authorization. If unavailable, ask the user to start it.
- Run focused checks with `mix test --only <scenario> [--device <id>]` against that session. Never use `--ci` to launch another bench.
- `mix dev.ui <device-id | nerves_gate@IPv4> [--port 4001]` serves the gateway UI with code reload. It connects to a running device; it does not boot one.
- Build changed assets with `mix assets.build` and commit `priv/static/assets/` with their sources.
- Keep code formatted and test changed behavior. Documentation-only changes need no QEMU checks.
- Full `mix ci` is expensive and belongs to the user. Report focused checks; do not run it.

## Start here

- [Architecture and source map](docs/architecture.md)
- [Development](docs/development.md)
- [Public API](lib/nerves_gate.ex)
