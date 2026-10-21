# Development

## Get started

Install the [prerequisites](#prerequisites), then run from the repository root:

```sh
mix setup
mix dev
```

Open **http://localhost:4000** and choose **Start devices**. Start builds the local
x86_64 firmware and bootstraps the configured QEMU devices through USB SSH/fwup.

| Interface | Purpose |
| --- | --- |
| Simulator `/` | Device list, default wiring, lifecycle, runs and log |
| Simulator `/devices/:id` | One device's observations, faults and scenarios |
| Each device's Gateway UI link | Gateway settings served by that device |
| `mix dev.ui <target>` | Gateway UI with code reload at localhost:4001 |

`mix setup` installs missing Mix tooling, fetches every project's dependencies,
installs the checksum-pinned x86 Tailscale daemon and downloads the prebuilt QEMU
system. It needs Internet access, never boots a device and does not overwrite a
different installed daemon.

## Test the app-development workflow locally

Before releasing package changes, create a workspace using this checkout:

```sh
mix dev.workspace
cd <printed-workspace-path>
mix setup
mix test
mix app.new example_app
mix setup
mix test
mix app.package example_app
mix sim
```

`mix dev.workspace` only generates files in a new temporary directory. It does
not run tests, start a server, boot devices or publish anything. Run the ordinary
workspace commands yourself in separate terminals as needed. The workspace and
all apps created within it use this checkout's generator, simulator, firmware
host code and SDK, not their Hex releases. Local dependency selection is recorded
in its `mix.exs`; no shell environment flags are needed.

Setup downloads the pinned released QEMU image if missing. To test changed device
code too, build it from `firmware/` and point the workspace's
`config/simulator.exs` at that `.fw`; local host dependencies do not rebuild device
firmware. `mix sim` serves the site, and devices start only when explicitly
requested there. Remove the temporary workspace when finished.

The isolated archive-install smoke test remains part of generator tests. Release
tags are a separate, explicit step after local validation; see [releases](releases.md).

### Prerequisites

- Linux x86_64 or aarch64; Elixir 1.20 / OTP 29 (`mise install`).
- [fwup](https://github.com/fwup-home/fwup#installing) on `PATH`.
- Git, C compiler, make, pkg-config, libmnl/libnl headers, QEMU 8.2+ with user and
  stream networking, util-linux, inotify-tools and e2fsprogs (`mkfs.ext4` on `PATH`).

On Debian/Ubuntu:

```sh
sudo apt install git build-essential pkg-config libmnl-dev libnl-genl-3-dev qemu-system-x86 util-linux inotify-tools e2fsprogs
```

On Apple Silicon, use an arm64 Ubuntu [OrbStack](https://orbstack.dev) machine
(`orb create --arch arm64 ubuntu nerves-gate`) with fwup's arm64 package, and clone
inside the Linux filesystem. OrbStack forwards localhost:4000 and the Gateway UI links
to the Mac. Avoid
amd64/Rosetta machines: the BEAM JIT fails there.

Normal setup needs neither Docker nor privileged networking. Docker is needed only
to build a Nerves system from source.

## Repository

Independent Mix projects; none is an umbrella child and there is no shared version.

| Project | Package | Purpose |
| --- | --- | --- |
| `firmware/` | `nerves_gate` | Device application, gateway UI, SDK backend, application runtime |
| `sdk/` | `nerves_gate_sdk` | Pure Elixir application API and `mix nerves_gate.package` |
| `sim/` | `nerves_gate_sim` | QEMU simulator, simulator site and scenario runner |
| `new/` | `nerves_gate_new` | `mix nerves_gate.new` archive |
| `systems/nerves_system_ec100` | `nerves_system_ec100` | EC100 Nerves system |
| `systems/nerves_system_ec100_qemu` | `nerves_system_ec100_qemu` | x86_64 system for QEMU |

The root `mix.exs` only orchestrates them in one VM with `Mix.Project.in_project/4`,
using local path dependencies (`NERVES_GATE_LOCAL_DEPS=1`):

| Command | Runs |
| --- | --- |
| `mix setup` | Dependencies for all projects and the QEMU firmware inputs |
| `mix format` | Each Elixir project's formatter (not the Nerves systems) |
| `mix test` | SDK, simulator and generator unit tests; no devices |
| `mix check` | Warnings-as-errors, formatting and unit tests for those packages |
| `mix ci` | Each SDK, simulator, generator and firmware project's CI, in test mode |
| `mix dev`, `mix dev.status`, `mix dev.stop`, `mix dev.ui` | The simulator session |
| `mix test.sdk`, `mix test.sim` | One package's unit tests |
| `mix test.firmware` | Firmware integration scenarios on the running session |

Root commands are product-maintainer orchestration, not the app-development
interface. Root `mix ci` runs all application-project quality gates; each project
also provides its own `mix ci`. System artifact builds remain in dedicated
workflows; QEMU scenarios are explicit and are not launched by `mix ci`.

Run firmware-specific commands inside `firmware/`, using local repository
dependencies:

```sh
cd firmware
NERVES_GATE_LOCAL_DEPS=1 MIX_TARGET=ec100 MIX_ENV=prod mix firmware
NERVES_GATE_LOCAL_DEPS=1 MIX_TARGET=x86_64 mix firmware
```

There is no root `mix firmware` alias. App developers consume a compatible
firmware image rather than building the product; see
[Application development](applications.md#application-development).

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
  `mix test.firmware --lifecycle stop` does the same. Interrupted bootstrap requires Reset.
- **Reset** stops devices and erases all disks, SD cards and enrollment.

Lifecycle changes cannot interrupt active runs or manual control. After a failure, inspect
diagnostics and Reset. If the simulator BEAM is lost, restart `mix dev`; a new
session starts with empty disks.

In another terminal:

```sh
mix test.firmware --only cable_loss                       # first configured device
mix test.firmware --only cable_loss --device gateway_b
mix test.firmware                                        # all scenarios
```

Results appear on the device page and overview. Independent devices can run
concurrently; a selection with a `devices: :all` scenario, or **Run all**, reserves
every device.

Each device page has two modes:

- **Scenarios** runs the shared test modules. Fresh-disk scenarios and failure
  recovery erase the affected devices' disks and SD cards, including enrollment.
- **Manual** holds the device for cable, Internet, latency, loss and pause controls.
  Closing the page does not release it; switching to Scenarios clears faults first.

**Clear all faults** resumes the VM, connects Internet to LAN1, reconnects both
cables and removes uplink faults, keeping settings and disks. A paused VM can show
its last observation until distribution detects the loss.

Control timeouts and failed cleanup leave the state uncertain: inspect diagnostics,
then Reset rather than replaying commands. Avoid changing gateway settings from
another UI during scenarios.

### Applications on simulated devices

Each device has a sparse ext4 virtual SD card (`/dev/vdb`). Open its gateway UI,
choose **Application storage → Use this card**, then firmware mounts it at
`/mnt/apps` like a commissioned physical card. In a generated app-development workspace, with its `mix sim` session running:

```sh
mix app.install my_app [--device gateway_a]
```

packages the application, then installs and starts it through the device's own
`NervesGate.Apps`. The runner reserves the device until installation finishes;
release manual control first. A timeout blocks further operations until Reset.
Versioned upgrades retain health-checked rollback; reinstalling the same version
replaces the development copy and keeps its data.

### Reloading changes

- Gateway UI: use `mix dev.ui`; templates and assets reload.
- Device code or built firmware assets: Reset and Start.
- Simulator code, dependencies, configuration or new scenarios: restart `mix dev`.

The simulator site and `mix dev.ui` include Volt, LiveReload and Tidewave
(`/tidewave/mcp`, metadata at `/tidewave/config`). The simulator also serves its
CLI API (`/api/state`, `/api/run`, `/api/control`, `/api/install`) at
`sim/_build/qemu-dev/http.sock`. API state is private: it includes a CSRF token.

The site listens only on `127.0.0.1` and that socket; it has no sign-in and Tidewave
can run code. From another machine, use an SSH tunnel such as
`ssh -N -L 4000:127.0.0.1:4000 <workstation>` and open http://localhost:4000.

### Frontend assets

Edit `firmware/assets/css/`, `firmware/assets/js/` and the UI modules; Volt serves
development assets. Before committing assets or building firmware:

```sh
cd firmware
NERVES_GATE_LOCAL_DEPS=1 mix assets.build
NERVES_GATE_LOCAL_DEPS=1 mix volt.js.check
```

Commit `firmware/priv/static/assets/` with its sources, and rebuild after updating
Phoenix or LiveView. Firmware and the simulator site serve these built files.
`mix format` also formats JavaScript.

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

The default is `sim/priv/qemu/simulator.exs`. To use another trusted Elixir data
file (relative paths are relative to `sim/`):

```sh
mix dev --config path/to/simulator.exs
```

```elixir
%{
  firmware_project: "../firmware",
  firmware: "../firmware/_build/x86_64_dev/nerves/images/nerves_gate.fw",
  devices: %{
    gateway_a: %{network: %{internet: :lan1}},
    gateway_b: %{network: %{internet: :lan2}}
  }
}
```

`firmware_project` is built before devices start; omit it to use a prebuilt
`firmware` image (`mix nerves_gate.sim --firmware path` does this outside the
repository). Edit default wiring on the overview while stopped; add or remove
devices while disks are empty. Changes are saved to the selected file. Sorted
device IDs determine serials and management addresses. Keep the default two
unprovisioned devices for the full suite.

Each device gets its own disk, SD card, relay, QEMU process (1 GiB RAM), serial and
`127.0.0.N` management address. Its Gateway UI link uses a random port on 127.0.0.1.
Optional settings:

- `factory_firmware`: compatible factory artifact; defaults to `firmware`.
- Per-device `provision: %{ssh_keys: [public_key_line], network: settings}`, applied
  through normal SSH/public commands after bootstrap.

## Build configurations

`MIX_TARGET` selects where firmware code runs; `mix dev.ui` selects which gateway to use.

| Project / target | Configuration | Purpose |
| --- | --- | --- |
| `sim` host | `sim/config/` | Simulator site, gateway UI development and scenario runner |
| `firmware` host | `firmware/config/host.exs` | Quality checks and asset builds; starts nothing |
| `firmware` `x86_64/dev` | `firmware/config/x86_64.exs` | QEMU firmware |
| `firmware` `ec100/dev`, `ec100/prod` | `firmware/config/ec100.exs` | EC100 firmware |

Both firmware profiles import `firmware/config/firmware.exs` for the shared device
services. `sim` compiles `firmware` as a dependency (never starting its device
services) plus the repository's `firmware/test/scenarios/` and
`firmware/scripts/artifact_release.ex`. Hardware-specific settings live in the
platform profiles and systems.

## Scenarios

UI, CLI and CI run [`firmware/test/scenarios/`](../firmware/test/scenarios) with the
same runner (`sim/lib/nerves_gate/qemu_tests.ex`). Scenarios are ordinary Elixir
modules using ExUnit assertions and owned device handles:

```elixir
def spec, do: %{name: "My scenario", fresh_disk: true}
def run(%{device: selected, devices: all_devices}), do: ...
```

- `fresh_disk: true` bootstraps a fresh disk and SD card first.
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
| `apps` | Virtual SD mount, install, cold upgrade, health-checked rollback and removal |
| `sdk` | Typed SDK observations, caller-owned subscriptions and unavailable buses |
| `system_artifact` | System version, firmware validation, USB/hostname contract, data mount and release contracts |
| `frontend_assets` | Host/firmware assets, CSP, CSRF and development tooling boundaries |
| `test_bench` | Build progress, configuration, reservations and manual cleanup |
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
from **Run all** and `mix test.firmware`. See [real tailnet testing](tailnet-ci.md)
for GitHub OIDC setup, local test keys, the three-device configuration and logout cleanup.

`process_crash` kills each gateway worker without cleanup and stops the Endpoint
supervisor as OTP would. Each must recover within 30 seconds, including six stable
seconds, with the expected `rest_for_one` scope and unchanged boot identity,
settings and SSH keys. Two negative controls log expected `recovery_timeout`
entries in `recovery.log`.

`process_chaos` defaults to seed 40465. Set `PROCESS_CHAOS_SEED=<integer>` or
`PROCESS_CHAOS_SEED=random` when starting `mix dev` or `mix test.firmware --ci`, not
the attaching client. The seed and chosen sequence are recorded in `recovery.log`.
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
vdb ──────────── virtual SD card (sim/_build/qemu-dev/<device>/sd.img)
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
projection, SDK backend, application manager and USB SSH/fwup path, including
same-image A/B updates. The USB peer is statically addressed, so USB DHCP-client
discovery is not tested.

QEMU does not cover physical buses, LEDs/button, USB gadget hardware, cellular,
watchdog, EC100 flash/bootloader recovery, SD hot-removal or interrupted updates.
It does not check authenticated Tailscale subnet routing/NAT, browser workflows,
throughput, IPv6 or VPN path selection. The opt-in [tailnet workflow](tailnet-ci.md)
additionally checks real enrollment, peer HTTP and identity persistence across a
guest power cycle. Killing QEMU keeps host disk caches, so it is not a physical
power loss. `process_crash` covers the private management path only.

Boot waits are bounded at 180 seconds and scenario runs at fifteen minutes. Real
Internet outages fail checks. See the
[MuonTrap limitation](networking.md#known-runtime-limitation).

## Troubleshooting

- Port in use: `mix dev --port 4002` or `mix dev.ui <target> --port 4003`.
- Missing simulator tools: install the reported prerequisite; there is no fallback.
- CLI unavailable: start `mix dev`, then Start devices on the overview.
- Session already running: stop the owning session first. Never delete
  `sim/_build/qemu-dev/session.lock`; the kernel releases it on exit.
- Setup failure: fix the reported prerequisite or download error, then rerun `mix setup`.
- Device failure: inspect `sim/_build/qemu-tests/<session>/<device>/` and the site log.
  Reset after uncertain control; restart `mix dev` after simulator loss.
- Distribution conflict: free port 9100 on the device's loopback address. The
  launcher never stops other processes.

## System artifacts

Both systems live in this repository. Firmware consumes their source with Git
subdirectory dependencies pinned to `system-ec100/v<VERSION>` or
`system-ec100-qemu/v<VERSION>`. Their `artifact_sites` download fingerprinted
binaries from GitHub Releases in `sid2baker/nerves_gate`; no system Hex packages
are needed. `NERVES_GATE_LOCAL_DEPS=1` selects the checked-out system sources.

1. For build-input changes, bump the system's `VERSION`, update firmware's pinned
   dependency in `firmware/mix.exs`, and add a dated changelog section.
2. Align system dependencies in its `mix.lock` and `firmware/mix.lock`.
3. Push to `main`. CI detects each system directory independently and calls
   `.github/workflows/system-artifact.yml`. It builds the system, creates the
   namespaced tag, publishes the artifact, and verifies a fresh download. QEMU
   tests wait for the QEMU artifact; EC100 publication runs independently.

EC100 publication includes the corresponding-source archive and `SHA256SUMS`.
The publisher verifies all required assets and hashes before making a draft
public. Manual dispatch selects `ec100` or `x86_64` and can resume a release.
Release title is exactly the tag; notes are exactly the dated changelog body.

The release tag is read from the system's `artifact_sites`, so downloads and
publication agree. Published tags and assets are immutable; matching releases are
reused. An interrupted draft resumes only with identical sources, locks, toolchain
pins and artifact bytes. Otherwise clean up explicitly or bump the version; never
move a tag or overwrite an artifact.

Local system build (Docker required) and release-plan check (no build, no GitHub):

```sh
cd firmware
export NERVES_GATE_LOCAL_DEPS=1 MIX_TARGET=x86_64 MIX_ENV=dev
mix deps.get
mix nerves.artifact.build nerves_system_ec100_qemu
elixir -r scripts/artifact_release.ex -S mix nerves.artifact.release plan
```

For EC100, select `MIX_TARGET=ec100` and build `nerves_system_ec100` instead;
collect its sources with
`elixir -r ../systems/nerves_system_ec100/lib/mix/tasks/ec100.release.ex -S mix ec100.release`.
Neither command flashes hardware. Local `plan` is read-only and never publishes.

After changing the QEMU system, the operator resets and starts devices and runs
`mix test.firmware --only system_artifact` against the new system. Release metadata
and immutability checks also run as ordinary simulator unit tests.

## Package releases

Each project has its own `VERSION` and `CHANGELOG.md`, with namespaced tags:
`firmware/vX.Y.Z`, `sdk/vX.Y.Z`, `sim/vX.Y.Z`, `new/vX.Y.Z`,
`system-ec100/vX.Y.Z` and `system-ec100-qemu/vX.Y.Z`. Systems use Git source
packages and GitHub binary releases, not Hex. Other packages consume Hex
dependencies unless `NERVES_GATE_LOCAL_DEPS=1` selects repository-local paths.
Publish SDK before firmware, then simulator and generator tooling. System
artifacts must be published before firmware builds can download them.
See [Package releases](releases.md) for the release workflow, credentials,
validation, repair policy and current publication blockers.

## CI

`.github/workflows/qemu.yml` checks the pure packages (`sdk`, `new`) separately,
then runs `mix setup`, the root `mix ci` quality gates and
`mix test.firmware --ci` on disposable GitHub-hosted Ubuntu runners: it builds
firmware, bootstraps both default devices, runs the shared scenarios and uploads
only diagnostic `.log` files (14 days). Main-branch system changes invoke the
shared `.github/workflows/system-artifact.yml` for each changed target; PRs
cannot publish. QEMU setup waits for its system release and fails if a required
artifact is unpublished. EC100 source and binary assets publish through the same
immutable release process.

For an operator-owned standalone run, stop the development session first:

```sh
mix test.firmware --ci          # clean bench and shared scenarios
```

Agents run focused checks on the operator's session. Starting or stopping that
session, booting devices and full CI runs belong to the operator.
