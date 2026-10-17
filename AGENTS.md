# Nerves Gate

## Most important: KISS — Keep it stupidly simple

- Choose the simplest design that correctly solves the problem.
- Large changes are welcome when they simplify the system. Minimize concepts and indirection, not necessarily changed lines.
- Prefer direct code and ordinary Elixir/OTP over frameworks, generic machinery, speculative abstractions or configuration layers.
- Keep one clear way to do each job. Remove obsolete code rather than carrying parallel implementations.
- Solve today's requirements. Optimize or generalize only when there is a demonstrated need.

## Elixir only

- Write application logic, tests and development tooling in Elixir. Do not introduce helper scripts in other languages.
- Prefer Elixir libraries over shelling out when they cover the task; for example, use Req for HTTP.
- External system tools remain appropriate for actual firmware, networking and QEMU operations. Do not wrap ordinary application logic in shell scripts.

## Ownership and architecture

- Domain processes own commands, admission, deadlines and persistence.
- The projection is a read model, not a command coordinator. UI action availability never replaces backend validation.
- Keep `NervesGate.status/1` as a direct domain query. LiveViews share the device-owned projection stream and keep form drafts separate.
- Preserve clear boundaries without adding layers just to enforce them.

## Safety

- Tests operate only on disposable, supervised QEMU instances on the bench's private socket-based networks. Never attach the drivers to an arbitrary VM or alter workstation networking.
- Never flash physical devices, modify workstation networking/VPN, or stop unrelated processes without explicit authorization.
- Keep private login URLs, distribution cookies and other secrets out of projections, notifications and logs.

## Development and validation

- Use `mix setup` for initial QEMU development setup; use `mix deps.get` when only fetching dependencies.
- The user runs `mix dev` in another shell and starts devices on the simulator overview (`/`). Do not launch or stop that session, or boot devices through lifecycle controls without authorization. If unavailable, ask the user to start it.
- Run focused scenarios against the existing session with `mix test --only <scenario> [--device <id>]`; do not use `--ci` to launch another VM. Device pages are `/devices/:id`; the private CLI API is on `_build/qemu-dev/http.sock`.
- `mix dev.ui [device-id | nerves_gate@<IPv4>] [--port 4001]` serves the real gateway UI with code reload against a simulated or real device. It never boots devices; gateway firmware has no simulator pages.
- UI, CLI and CI use the same QEMU scenarios. Extend those rather than creating a separate hardware-mock or simulator suite.
- `mix ci` is expensive and is run only by the user. Do not run it; report the focused checks you performed and leave full CI to the user.
- Keep code formatted and test changed behavior. Documentation-only changes do not require QEMU checks.

## Start here

- [Architecture](docs/architecture.md)
- [Development and QEMU workflow](docs/development.md)
- [Public API](lib/nerves_gate.ex)
