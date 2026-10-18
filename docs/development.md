# Development

## Get started

Install the [prerequisites](#prerequisites), then run:

```sh
mix setup
mix dev
```

Open **http://localhost:4000** and choose **Start devices**. Start builds one
firmware image and bootstraps the configured QEMU devices through USB SSH/fwup.

| Interface | Purpose |
| --- | --- |
| Simulator `/` | Device list, default wiring, lifecycle, runs and log |
| Simulator `/devices/:id` | One device's observations, faults and scenarios |
| Each device's Gateway UI link | Gateway settings served by that device |
| `mix dev.ui <target>` | Gateway UI with code reload at localhost:4001 |

`mix setup` installs missing Mix tooling, fetches dependencies, installs the
checksum-pinned x86 Tailscale daemon and downloads the prebuilt QEMU system. It
needs Internet access and does not overwrite a different installed daemon. Use
`mix deps.get` to fetch dependencies only.

### Prerequisites

- Linux x86_64 or aarch64; Elixir 1.20 / OTP 29 (`mise install`).
- [fwup](https://github.com/fwup-home/fwup#installing) on `PATH`.
- Git, C compiler, make, pkg-config, libmnl/libnl headers, QEMU 8.2+ with user and
  stream networking, util-linux and inotify-tools.

On Debian/Ubuntu:

```sh
sudo apt install git build-essential pkg-config libmnl-dev libnl-genl-3-dev qemu-system-x86 util-linux inotify-tools
```

On Apple Silicon, use an arm64 Ubuntu [OrbStack](https://orbstack.dev) machine
(`orb create --arch arm64 ubuntu nerves-gate`) with fwup's arm64 package, and clone
inside the Linux filesystem. OrbStack forwards localhost:4000 to the Mac. Avoid
amd64/Rosetta machines: the BEAM JIT fails there.

Normal setup needs neither Docker nor privileged networking. Docker is needed only
to build the Nerves system from source.

## Daily workflow

Keep `mix dev` running. In another terminal:

```sh
mix dev.status  # session state, URL and launcher PID; never starts devices
mix dev.stop    # stop the entire idle session and wait for cleanup
```

`mix dev.stop` refuses active scenarios, manual control and device lifecycle
operations. It never force-kills an unresponsive session. If the private API is
unavailable, use the original terminal to stop the session; during startup, wait
for the site to become ready first. A session without matching control identity
must also be stopped from its original terminal.

The OS lock, not the existence of `session.lock` or `http.sock`, determines whether
a session is alive. Never delete the lock file or use broad `pkill` commands to
bypass it. `mix dev.status` distinguishes starting, running, stopping and an
unresponsive API. A duplicate `mix dev` reports the existing session instead of
starting another. Start again with `mix dev` after `mix dev.stop` completes; a new
session has empty devices.

On the simulator overview:

- **Start devices** builds and bootstraps empty devices, or resumes preserved disks.
- **Stop** powers devices off and preserves disks; the simulator site stays running.
  `mix test --lifecycle stop` does the same. Interrupted bootstrap requires Reset.
- **Reset** stops devices and erases all disks and enrollment.

Lifecycle changes cannot interrupt active runs or manual control. After a failure, inspect
diagnostics and Reset. If the simulator BEAM is lost, restart `mix dev`; a new
session starts with empty disks.

In another terminal:

```sh
mix test --only cable_loss                       # first configured device
mix test --only cable_loss --device gateway_b
mix test                                        # all scenarios
```

Results appear on the device page and overview. Independent devices can run
concurrently; a selection with a `devices: :all` scenario, or **Run all**, reserves
every device.

Each device page has two modes:

- **Scenarios** runs the shared test modules. Fresh-disk scenarios and failure
  recovery erase the affected devices' disks, including enrollment.
- **Manual** holds the device for cable, Internet, latency, loss and pause controls.
  Closing the page does not release it; switching to Scenarios clears faults first.

**Clear all faults** resumes the VM, connects Internet to LAN1, reconnects both
cables and removes uplink faults, keeping settings and disks. A paused VM can show
its last observation until distribution detects the loss.

Control timeouts and failed cleanup leave the state uncertain: inspect diagnostics,
then Reset rather than replaying commands. Avoid changing gateway settings from
another UI during scenarios.

### Reloading changes

- Gateway UI: use `mix dev.ui`; templates and assets reload.
- Device code or built firmware assets: Reset and Start.
- Simulator code, dependencies, configuration or new scenarios: restart `mix dev`.

The simulator site and `mix dev.ui` include Volt, LiveReload and Tidewave
(`/tidewave/mcp`, metadata at `/tidewave/config`). The simulator also serves its
CLI API (`/api/state`, `/api/run`, `/api/control`) at `_build/qemu-dev/http.sock`.
API state is private: it includes a CSRF token.

The site listens only on `127.0.0.1` and that socket; it has no sign-in and Tidewave
can run code. From another machine, use an SSH tunnel such as
`ssh -N -L 4000:127.0.0.1:4000 <workstation>` and open http://localhost:4000.

### Frontend assets

Edit `assets/css/`, `assets/js/` and the UI modules; Volt serves development assets.
Before committing assets or building firmware:

```sh
mix assets.build
MIX_TARGET=host MIX_ENV=dev mix volt.js.check
```

Commit `priv/static/assets/` with its sources, and rebuild after updating Phoenix
or LiveView. Firmware serves these built files. `mix format` also formats JavaScript.

## Gateway UI development

```sh
mix dev.ui gateway_a
mix dev.ui nerves_gate@100.101.102.103
mix dev.ui gateway_b --port 4002
mix dev.ui                                      # use the only gateway found
```

The default port is **4001**. Start a simulated target on the simulator site first.
Without a target, the launcher checks the running simulator session and the local
tailnet; ambiguous results list explicit commands. An explicit target probes only
that gateway.

Real gateways need compatible development firmware, OTP/Elixir and the development
cookie. Use their exact `nerves_gate@<IPv4>` name. Tailnet policy must permit TCP
4369 (EPMD) and 9100 (distribution). Tailnet discovery needs read access to
`/var/run/tailscale/tailscaled.sock`.

The launcher serves on loopback and connects over hidden, outbound-only Erlang
distribution: the session's private EPMD for simulated targets, standard EPMD for
real ones. It starts no device services and changes neither the simulator nor
workstation networking. Restart it to switch targets. Workstation HTTP access never
counts as verified USB access.

## Simulator configuration

The default is `dev/simulator.exs`. To use another trusted Elixir data file:

```sh
mix dev --config path/to/simulator.exs
```

```elixir
%{
  firmware: "_build/x86_64_dev/nerves/images/nerves_gate.fw",
  devices: %{
    gateway_a: %{network: %{internet: :lan1}},
    gateway_b: %{network: %{internet: :lan2}}
  }
}
```

Edit default wiring on the overview while stopped; add or remove devices while disks
are empty. Changes are saved to the selected file. Sorted device IDs determine
serials and management addresses. Keep the default two unprovisioned devices for
the full suite.

Each device gets its own disk, relay, QEMU process (1 GiB RAM), serial and
`127.0.0.N` management address. Optional settings:

- `factory_firmware`: compatible factory artifact; defaults to `firmware`.
- Per-device `provision: %{ssh_keys: [public_key_line], network: settings}`, applied
  through normal SSH/public commands after bootstrap.

## Build configurations

`MIX_TARGET` selects where code runs; `mix dev.ui` selects which gateway to use.
The launchers select the host target automatically.

| Target / environment | Configuration | Purpose |
| --- | --- | --- |
| `host/dev` | `config/host.exs` | Simulator site and gateway UI development |
| `host/test` | `config/host.exs` | Scenario runner and quality checks |
| `x86_64/dev` | `config/x86_64.exs` | QEMU firmware |
| `ec100/dev`, `ec100/prod` | `config/ec100.exs` | EC100 firmware |

Both firmware profiles import `config/firmware.exs` for the shared device services.
All targets compile `lib/`; host builds also compile `dev/`, `test/support/` and
`test/scenarios/`. `config/runtime.exs` supplies session secrets and node settings.
Hardware-specific settings live in the platform profiles and systems.

## Scenarios

UI, CLI and CI run [`test/scenarios/`](../test/scenarios) with the same runner.
Scenarios are ordinary Elixir modules using ExUnit assertions and owned device handles:

```elixir
def spec, do: %{name: "My scenario", fresh_disk: true}
def run(%{device: selected, devices: all_devices}), do: ...
```

- `fresh_disk: true` bootstraps a fresh disk first.
- `devices: :all` reserves every device and includes them all in failure recovery.
- `boot: [receive_stall: true]` enables the receive-stall hardware fault.

Before ordinary scenarios, the runner sets Internet on LAN1, equipment on LAN2,
connected cables and eth0 DHCP. On failure it records the error and bounded,
secret-free diagnostics, then replaces the affected devices' disks. Cleanup resumes
paused VMs and restores the baseline; uncertainty blocks affected devices until
Reset. The site keeps active runs, 20 completed runs and 100 events.

Useful focused checks:

| Scenario | Checks |
| --- | --- |
| `system_artifact` | System version, firmware validation, USB/hostname contract, data mount and release contracts |
| `frontend_assets` | Host/firmware assets, CSP, CSRF and development tooling boundaries |
| `test_bench` | Configuration, reservations and manual cleanup |
| `process_crash` | Gateway process restarts, restart scope, saved settings and fresh local HTTP |
| `restart_intensity` | Four rapid crashes exhaust supervision; firmware reboots without harness rescue |
| `alarm_recovery` | Two-second debounce, immediate critical alarms, timer preservation and clearing after owner restart |
| `dependency_restart` | VintageNet, Tailscale and property-subscription workers; fresh UI read-model updates |
| `process_chaos` | Six seeded single/double crashes with saved-state, scope and stable recovery checks |
| `projection_stream` | Device projection, reconnect and draft preservation |
| `dev_discovery` | Gateway discovery, filtering and ambiguity |
| `multi_device` | Independent identities, disks, faults and power cuts |
| `topology` | Cable movement, stable NICs and network isolation |
| `internet`, `latency`, `loss` | Guest DNS/verified HTTPS and uplink faults |
| `firewall`, `tailscale_login` | Guest firewall and real Tailscale enrollment handshake |
| `ssh_access`, `firmware_upgrade` | USB SSH, key persistence, A/B firmware updates and their validation |

Ordinary Internet and Tailscale scenarios use real public services without enrolling
an account or printing private login links. The explicitly selected `tailscale_auth`
scenario enrolls three disposable guests into a real test tailnet; it is excluded
from **Run all**, `mix test` and `mix ci`. See [real tailnet CI setup](tailnet-ci.md)
for its GitHub OIDC trust configuration, manual workflow and cleanup.

`process_crash` kills each gateway worker without cleanup and stops the Endpoint
supervisor as OTP would. Each must recover within 30 seconds, including six stable
seconds, with the expected `rest_for_one` scope and unchanged boot identity,
settings and SSH keys. Two negative controls log expected `recovery_timeout`
entries in `recovery.log`.

`process_chaos` defaults to seed 40465. Set `PROCESS_CHAOS_SEED=<integer>` or
`PROCESS_CHAOS_SEED=random` when starting `mix dev` or `mix ci`, not the attaching
`mix test` client. The seed and chosen sequence are recorded in `recovery.log`.
Faults stay within an explicit guest-process allowlist; each step waits for six
stable seconds before the next, aging out OTP's inclusive five-second restart
window. This is not arbitrary PID killing, a hang test or proof of tailnet
reachability.

`alarm_recovery` measures controlled condition pulses using Alarmist's guest
monotonic timestamps, separately from cable/DHCP detection. It also disconnects the
Internet cable, restarts Network while its alarm is active, then requires the alarm
to clear when connectivity returns. `dependency_restart` checks the device's cached
projection after SSH-key and cable changes, not just direct domain queries.

### Isolation

A host-only Simulator BEAM owns all QEMU processes, disks, QMP sockets and Ethernet
relays. Each device uses private Unix sockets and libslirp networking:

```text
eth0 / LAN1 ──┐
              ├── one LAN to Internet; the other to isolated equipment
eth1 / LAN2 ──┘
eth2 ─────────── restricted management → loopback distribution, HTTP and SSH
usb0 ─────────── VintageNetDirect → restricted USB SSH
```

The relay applies cable and uplink faults to real frames; QMP supplies carrier
changes. Management is never faulted. Internet uses gateway `10.0.2.2` and DNS
`10.0.2.3`; equipment has no IP server. Frame admission blocks cross-segment and
workstation loopback access. Workstation interfaces, routes, DNS, firewall and VPN
are untouched.

Device nodes are `nerves_gate@127.0.0.2`, `nerves_gate@127.0.0.3`, and so on, with
a session-private EPMD. Loopback services trust local users: this is network
isolation, not a sandbox against hostile local users. See the
[system notes](../systems/nerves_system_ec100_qemu/GATEWAY.md).

### Network control API

Scenarios and manual controls share the owned device drivers:

```elixir
alias NervesGate.TestQemu, as: Qemu

Qemu.network(vm, %{internet: :lan2})
Qemu.network(vm, %{cables: %{lan1: false}})
Qemu.network(vm, %{uplink: %{delay_ms: 200, loss: :alternate}})
Qemu.network(vm)
Qemu.network_stats(vm)
Qemu.network(vm, NervesGate.Simulator.Network.defaults())
```

Patches keep omitted fields and reject invalid values before changing forwarding.
Internet is `:lan1 | :lan2 | :off`, delay 0–5000 ms, and loss
`:none | :alternate | :all` (alternate drops every other eligible outgoing packet).
Management and local ARP/DHCP bypass Internet faults. Wiring and faults survive VM
replacement; queued packets and libslirp state do not.

## Coverage and limits

QEMU runs the real Nerves application, VintageNet, tailscaled, persistence,
projection and USB SSH/fwup path, including same-image A/B updates. The USB peer is
statically addressed, so USB DHCP-client discovery is not tested.

QEMU does not cover physical buses, LEDs/button, USB gadget hardware, cellular,
watchdog, EC100 flash/bootloader recovery or interrupted updates. It does not
check authenticated Tailscale subnet routing/NAT, browser workflows, throughput, IPv6
or VPN path selection. The opt-in [tailnet workflow](tailnet-ci.md) additionally checks
real enrollment, peer HTTP and identity persistence across a guest power cycle. Killing QEMU keeps host disk caches, so it is not a physical
power loss. `process_crash` covers the private management path only.

Boot waits are bounded at 180 seconds and scenario runs at fifteen minutes. Real
Internet outages fail checks. See the
[MuonTrap limitation](networking.md#known-runtime-limitation).

## Troubleshooting

- Port in use: `mix dev --port 4002` or `mix dev.ui <target> --port 4003`.
- CLI unavailable: start `mix dev`, then Start devices on the overview.
- Session already running: stop the owning session first. Never delete
  `_build/qemu-dev/session.lock`; the kernel releases it on exit.
- Setup failure: fix the reported prerequisite or download error, then rerun `mix setup`.
- Device failure: inspect `_build/qemu-tests/<session>/<device>/` and the site log.
  Reset after uncertain control; restart `mix dev` after simulator loss.
- Distribution conflict: free port 9100 on the device's loopback address. The
  launcher never stops other processes.

## Maintaining the QEMU system

`systems/nerves_system_ec100_qemu/` supplies the `x86_64` system artifact.

1. For build-input changes, bump its `VERSION` and add a dated changelog section.
2. Align system dependencies in its `mix.lock` and the application's `mix.lock`.
3. Push to `main`. The system workflow publishes and verifies the artifact before
   simulator CI uses it.

Published tags and assets are immutable; matching releases are reused. An
interrupted draft resumes only with identical sources, locks, toolchain pins and
artifact bytes. Otherwise clean up explicitly or bump the version; never move a
tag or overwrite an artifact.

Local system build (Docker required) and release-plan check (no build, no GitHub):

```sh
MIX_TARGET=x86_64 MIX_ENV=dev mix deps.get
MIX_TARGET=x86_64 MIX_ENV=dev mix nerves.artifact.build nerves_system_ec100_qemu
mix setup
MIX_TARGET=x86_64 MIX_ENV=dev elixir -r dev/artifact_release.ex -S mix nerves.artifact.release plan
```

After changing the system, Reset and Start devices and run
`mix test --only system_artifact`.

## CI

`.github/workflows/qemu.yml` runs `mix setup` and `mix ci` on disposable
GitHub-hosted Ubuntu runners: it builds firmware, bootstraps both default devices,
runs the shared scenarios and uploads only diagnostic `.log` files (14 days).
Main-branch system changes first run `.github/workflows/ec100-qemu-system.yml`,
which publishes with trusted main code; PRs cannot publish. Setup fails if a required artifact is
unpublished. Both workflows support manual dispatch.

For an operator-owned standalone run, stop the development session first:

```sh
mix test --ci                   # clean bench and shared scenarios
mix ci                          # quality gates plus the clean scenario run
```

Agents run focused checks on the operator's session. Starting or stopping that
session, booting devices and full `mix ci` belong to the operator.
