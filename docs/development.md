# Development

## Get started

Install the [prerequisites](#prerequisites), then run:

```sh
mix setup
mix dev
```

Open **http://localhost:4000** and choose **Start devices**. The site starts with
an empty simulator; Start builds one firmware image and bootstraps the configured
QEMU devices through USB SSH/fwup.

| Interface | Purpose |
| --- | --- |
| Simulator `/` | Device list, default wiring, lifecycle, runs and log |
| Simulator `/devices/:id` | One device's observations, faults and scenarios |
| Each device's Gateway UI link | Gateway settings served by that device |
| `mix dev.ui <target>` | Gateway UI with code reload at localhost:4001 |

`mix setup` installs missing Mix tooling, fetches dependencies, installs the
checksum-pinned x86 Tailscale daemon and downloads the prebuilt QEMU system.
It needs Internet access and does not overwrite a different installed daemon.
Use `mix deps.get` when only fetching dependencies.

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
(`orb create --arch arm64 ubuntu nerves-gate`) with fwup's arm64 package. Clone
inside the Linux filesystem. OrbStack forwards localhost:4000 to the Mac.
Avoid amd64/Rosetta machines because the BEAM JIT fails there.

Normal setup needs neither Docker nor privileged networking. Docker is required
only for building the Nerves system from source.

## Daily workflow

Keep `mix dev` running. On the simulator overview:

- **Start devices** builds and bootstraps empty devices, or resumes preserved disks.
- **Stop** powers off devices and preserves disks. Interrupted bootstrap requires Reset.
- **Reset** stops devices and erases all disks and enrollment. It leaves devices stopped.

Lifecycle changes cannot interrupt active runs or manual control. After a failure,
inspect diagnostics and Reset. If the simulator BEAM is unavailable, restart `mix dev`.
A new session starts with empty disks.

In another terminal:

```sh
mix test --only cable_loss                       # first configured device
mix test --only cable_loss --device gateway_b
mix test                                        # all scenarios
```

Results appear on the device page and overview. Independent devices can run
concurrently. A selection containing a `devices: :all` scenario reserves every
device for the whole run; **Run all** does too.

Each device page has two modes:

- **Scenarios** runs the shared test modules. Fresh-disk scenarios and failure
  recovery erase the affected devices' disks, including enrollment.
- **Manual** holds the device for cable, Internet, latency, loss and pause controls.
  Closing the page does not release it. Switching to Scenarios clears faults first.

**Clear all faults** resumes the VM, connects Internet to LAN1, reconnects both
cables and removes uplink faults. It preserves device settings and disk contents.
Injected faults are shown separately from live device observations. A paused VM
can show its last observation until distribution detects the loss.

Control timeouts and failed cleanup mean uncertain state: inspect diagnostics,
then Reset. Do not replay commands blindly. Avoid changing gateway settings from
another UI during scenarios.

### Reloading changes

- Gateway UI: use `mix dev.ui`; templates and assets reload.
- Device code or built firmware assets: Reset and Start.
- Simulator code, dependencies or configuration: restart `mix dev`.
- New scenarios: restart `mix dev` so the runner lists them.

The simulator site and `mix dev.ui` include Volt, LiveReload and Tidewave in dev.
Tidewave MCP is `/tidewave/mcp`, with metadata at `/tidewave/config` on the chosen
site port. Origin checks remain enabled. The simulator also serves its CLI API
(`/api/state`, `/api/run`, `/api/control`) at `_build/qemu-dev/http.sock`.
Treat API state as private: it includes a CSRF token.

### Frontend assets

Edit `assets/css/`, `assets/js/` and the UI modules. Volt watches sources and
serves development assets. Before committing assets or building firmware:

```sh
mix assets.build
MIX_TARGET=host MIX_ENV=dev mix volt.js.check
```

Commit generated `priv/static/assets/` with their sources. Rebuild after updating
Phoenix or LiveView dependencies. Firmware serves these built files. `mix format`
also formats JavaScript on the host.

## Gateway UI development

Use the same launcher for simulated and real development gateways:

```sh
mix dev.ui gateway_a
mix dev.ui nerves_gate@100.101.102.103
mix dev.ui gateway_b --port 4002
mix dev.ui                                      # use the only gateway found
```

The default UI port is **4001**. Start a simulated target on the simulator site
first. Without a target, the launcher reads the running simulator session and
probes gateways on the local tailnet. Ambiguous discovery lists explicit commands.
An explicit target probes only that gateway.

Real gateways need compatible development firmware, OTP/Elixir and the development
cookie. Use their exact `nerves_gate@<IPv4>` node name. Tailnet policy must permit
TCP 4369 (EPMD) and 9100 (distribution). Automatic tailnet discovery needs read
access to `/var/run/tailscale/tailscaled.sock`.

The launcher serves on loopback and connects over hidden, outbound-only Erlang
distribution. Simulated targets use the session's private EPMD port; real targets
use standard EPMD. It starts no device services and does not change the simulator
lifecycle or workstation networking. Restart it to choose another target.
Workstation HTTP access does not count as verified USB access.

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

Edit default wiring on the overview while stopped. Add/remove devices while empty
or after Reset. Changes are saved to the selected file. Sorted device IDs determine
serials and management addresses, so device membership cannot change under preserved
disks. Keep the default two unprovisioned devices for the full suite.

Each device gets its own disk, relay, QEMU process (1 GiB RAM), serial and
`127.0.0.N` management address. Optional file settings:

- `factory_firmware`: compatible factory artifact; defaults to `firmware`.
- Per-device `provision: %{ssh_keys: [public_key_line], network: settings}`:
  applies settings through normal SSH/public commands after bootstrap.

## Which configuration is used?

`MIX_TARGET` selects where code runs; `mix dev.ui` selects which gateway to connect to.
The launchers select the host target automatically. Use per-command environment
variables for firmware builds.

| Target / environment | Configuration | Purpose |
| --- | --- | --- |
| `host/dev` | `config/host.exs` | Simulator site and gateway UI development |
| `host/test` | `config/host.exs` | Scenario runner and quality checks |
| `x86_64/dev` | `config/x86_64.exs` | QEMU firmware |
| `ec100/dev`, `ec100/prod` | `config/ec100.exs` | EC100 firmware |

Firmware profiles import `config/firmware.exs` for shared services. Both targets
compile `lib/`; host builds also compile `dev/`, `test/support/` and `test/scenarios/`.
`config/runtime.exs` supplies session secrets and runtime node settings. QEMU uses
the same device services, initialization hook and VintageNetDirect configuration
as EC100; hardware-specific settings live in the platform profiles and systems.

The EC100 system is pinned to a release tag in `mix.exs`; firmware builds download
its published artifact. See [building EC100 firmware](../README.md#build-ec100-firmware).

## One scenario folder, one runner

UI, CLI and CI use [`test/scenarios/`](../test/scenarios) and the same runner.
Scenarios are ordinary Elixir modules using ExUnit assertions and owned device handles:

```elixir
def spec, do: %{name: "My scenario", fresh_disk: true}
def run(%{device: selected, devices: all_devices}), do: ...
```

- `fresh_disk: true` bootstraps a fresh disk before the scenario.
- `devices: :all` reserves every device and includes them all in failure recovery.
- `boot: [receive_stall: true]` enables the receive-stall hardware fault.

Before ordinary scenarios, the runner establishes Internet on LAN1, equipment on
LAN2, connected cables and eth0 DHCP. Failure recovery replaces the selected device,
or all devices for a multi-device scenario. Cleanup resumes paused VMs and restores
the network baseline; uncertainty blocks affected devices until Reset. The site
retains active runs, 20 completed runs and 100 events.

Useful focused checks:

| Scenario | Checks |
| --- | --- |
| `system_artifact` | System version, firmware validation, USB/hostname contract, data mount and release contracts |
| `frontend_assets` | Host/firmware assets, CSP, CSRF and development tooling boundaries |
| `test_bench` | Configuration, reservations and manual cleanup |
| `process_crash` | Eight gateway children, restart scope, saved settings/SSH key fingerprints and fresh local HTTP |
| `projection_stream` | Device projection, reconnect and draft preservation |
| `dev_discovery` | Gateway discovery, filtering and ambiguity |
| `multi_device` | Independent identities, disks, faults and power cuts |
| `topology` | Cable movement, stable NICs and network isolation |
| `internet`, `latency`, `loss` | Guest DNS/verified HTTPS and uplink faults |
| `firewall`, `tailscale_login` | Guest firewall and real Tailscale enrollment handshake |
| `ssh_access`, `firmware_upgrade` | USB SSH, key persistence, A/B firmware updates and their validation |

See the source folder for the full list. Internet/Tailscale scenarios require real
public services. They do not enroll an account or print private login links.

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

The relay applies cable/uplink faults to real frames; QMP supplies carrier changes.
Management is never faulted. Internet uses gateway `10.0.2.2` and DNS `10.0.2.3`;
equipment has no IP server. Frame admission blocks cross-segment and workstation
loopback access. Workstation interfaces, routes, DNS, firewall and VPN are untouched.

Device nodes are `nerves_gate@127.0.0.2`, `nerves_gate@127.0.0.3`, etc. The session
owns a private EPMD. Loopback services trust local users: this is network isolation,
not a hostile-local-user sandbox. See the [system notes](../systems/nerves_system_ec100_qemu/GATEWAY.md).

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

Patches preserve omitted fields and reject invalid values before changing forwarding.
Internet is `:lan1 | :lan2 | :off`, delay is 0–5000 ms, and loss is
`:none | :alternate | :all`. Alternate loss drops every other eligible outgoing
packet. Management and local ARP/DHCP bypass Internet faults. Wiring and faults
survive VM replacement; queued packets and live libslirp state do not.

## Coverage and limits

QEMU exercises the real Nerves application, VintageNet, tailscaled, persistence,
projection and USB SSH/fwup path. Firmware tests perform same-image A/B updates.
The USB peer is statically addressed; USB DHCP-client discovery is not tested.

Physical buses, LEDs/button, USB gadget hardware, cellular, EC100 flash/bootloader
recovery and interrupted updates need hardware qualification. Authenticated
end-to-end Tailscale routing/NAT and browser workflows also need separate checks.
QEMU uses IPv4 userspace networking; it does not qualify throughput, IPv6 or VPN
path selection. SIGKILL retains host disk caches and is not physical power loss.

`process_crash` checks private-management recovery only, not SSH host identity or
remote tailnet access. Workers are killed without cleanup; the Endpoint supervisor
stops its children and exits, as OTP supervisors fail. It allows 30 seconds
including a five-second stability window for each isolated crash. It first verifies that unchanged PIDs and a stopped
HTTP listener cannot pass. These negative controls intentionally produce two
`recovery_timeout` entries in `recovery.log`. Failures are recorded and bounded,
secret-free boot/process diagnostics captured before fault cleanup or disk replacement.

Boot waits are bounded at 180 seconds, scenario runs at fifteen minutes. Real
Internet outages fail checks. See the [MuonTrap runtime limitation](networking.md#known-runtime-limitation).

See the [reliability implementation plan](reliability-plan.md) for remote-access,
crash/hang, watchdog and chaos testing work.

## Troubleshooting

- Port in use: choose `mix dev --port 4002` or `mix dev.ui <target> --port 4003`.
- CLI unavailable: start `mix dev`, then Start devices on the overview.
- Session already running: stop the owning session before restarting. Never delete
  `_build/qemu-dev/session.lock`; the kernel releases the lock on exit.
- Setup failure: fix the reported prerequisite/download error, then rerun `mix setup`.
- Device failure: inspect `_build/qemu-tests/<session>/<device>/` and the site log.
  Reset after uncertain control; restart `mix dev` after simulator loss.
- Distribution conflict: resolve the process using port 9100 on the device's
  loopback address. The launcher never stops unrelated processes.

## Maintaining the QEMU system

`systems/nerves_system_ec100_qemu/` supplies the `x86_64` system artifact.

1. For build-input changes, bump its `VERSION` and add a dated changelog section.
2. Align system dependencies in its `mix.lock` and the application's `mix.lock`.
3. Push to `main`. The system workflow publishes and verifies the artifact before
   simulator CI uses it.

Published tags/assets are immutable. Matching releases are reused. An interrupted
draft can resume only with matching tagged sources, locks, toolchain pins and
artifact bytes. Conflicts require explicit maintainer cleanup or a new version;
never move a tag or overwrite an artifact. Ordinary application changes reuse the
published system.

For deliberate local system builds (Docker required):

```sh
MIX_TARGET=x86_64 MIX_ENV=dev mix deps.get
MIX_TARGET=x86_64 MIX_ENV=dev mix nerves.artifact.build nerves_system_ec100_qemu
mix setup
```

Inspect the artifact plan locally without building or contacting GitHub:

```sh
MIX_TARGET=x86_64 MIX_ENV=dev elixir -r dev/artifact_release.ex -S mix nerves.artifact.release plan
```

After changing the system, Reset and Start devices and run
`mix test --only system_artifact`.

## CI

`.github/workflows/qemu.yml` runs `mix setup` and `mix ci` on disposable GitHub-hosted
Ubuntu runners. It builds application firmware, bootstraps both default devices,
runs the shared scenarios and shuts down. Downloads are cached; only diagnostic
`.log` files are uploaded, for 14 days.

Main-branch system changes first run `.github/workflows/ec100-qemu-system.yml`.
Publication uses trusted main code and write permission; PRs cannot publish.
An unpublished required artifact fails setup. Both workflows support manual dispatch.

For an operator-owned standalone run, stop the development session first:

```sh
mix test --ci                   # clean bench and shared scenarios
mix ci                          # quality gates plus the clean scenario run
```

Agents use focused checks on the operator's existing session. Starting/stopping
that session or booting devices requires authorization. Full `mix ci` is run only
by the operator.
