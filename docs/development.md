# Development

## Get started

With the [prerequisites](#prerequisites) installed, run from the repository root:

```sh
mix setup
mix dev.qemu
```

Wait for **QEMU ready**, then open **http://localhost:4000** for the gateway UI or
**/tests** for scenarios. The proxy opens only after Phoenix answers HTTP requests.
No EC100, Tailscale login, environment file or manual network setup is needed.

`mix setup` checks the workstation, installs missing Hex/Rebar/Nerves bootstrap,
fetches host and x86 dependencies, verifies a pinned Tailscale archive and installs
its x86 daemon, then builds the local Nerves system. The first build can take an
hour and needs Internet access and substantial disk space. Reruns reuse the
archive and incremental build cache. A different existing x86 daemon is not
overwritten: remove it explicitly if you want setup to install the pinned one.
Setup neither boots QEMU nor runs tests, and never touches the ARM daemon or EC100 BSP.

### Prerequisites

- **Linux x86_64**, with unprivileged user/network namespaces and `/dev/net/tun`.
- **Elixir 1.20 / OTP 29**; `mise install` uses the versions in `mise.toml` if you use mise.
- **fwup**, available on `PATH`; see its [installation guide](https://github.com/fwup-home/fwup#installing).
- **Docker**, running and usable by your account without sudo.
- Git, a C compiler, make, pkg-config, QEMU, iproute2, nftables, socat and util-linux.

For Debian/Ubuntu, the last group can be installed with:

```sh
sudo apt install git build-essential pkg-config qemu-system-x86 iproute2 nftables socat util-linux
```

Install the toolchain, fwup and Docker separately. `mix setup` reports missing
tools; it does not install OS packages, start Docker, change permissions or enable
namespaces. If namespaces are restricted by host policy, use an approved Linux
development machine rather than running the session as root.

## Daily workflow

Keep `mix dev.qemu` running in one terminal. It builds current development firmware,
boots a disposable disk and starts workstation Phoenix with code reload,
LiveReload and Tidewave. Host UI changes reload; device code changes require
restarting the command to rebuild firmware. Run `mix setup` again after changing
dependencies or the local Nerves system.

In another terminal:

```sh
mix test --only cable_loss       # one scenario on the running device
mix test                        # all scenarios on that same session
```

Results also appear at **http://localhost:4000/tests**. Only one run is admitted at
a time; avoid manual device changes during a run. Some scenarios reboot or replace
the disposable device. The UI reconnects afterward; do not keep valuable state there.

For a clean, standalone run, stop your development session first, then run:

```sh
mix test --ci                   # boot, run the same scenarios, shut down
mix ci                          # static quality gates, then the same clean run
```

Agents use the session you started and focused `mix test --only <scenario>` checks.
Starting/stopping `mix dev.qemu` and running full `mix ci` remain operator actions.
`mix test.qemu` is a compatibility alias for `mix test`.

Commands select the appropriate host dev/test environment even if firmware
variables remain exported. All browser assets are checked in. Only when changing
CSS, rebuild with `cd assets && npm ci && npm run build`; Node.js is not needed
for normal development or firmware compilation.

### Troubleshooting

- **Port 4000 in use:** run `mix dev.qemu --port 4001`.
- **CLI cannot reach a session:** start `mix dev.qemu`; tests use its private Unix socket.
- **Session already running:** stop the owning session before restarting. The kernel
  releases its lock on exit, including after a crash. The `session.lock` file stays
  on disk and is reused; never delete it. Stale HTTP sockets are removed on startup.
- **Failed setup/build:** fix the reported prerequisite or download error, then rerun
  `mix setup`. It does not discard the Nerves build cache.
- **Device failure:** inspect `_build/qemu-tests/<session>/` for console, QEMU and
  fault logs. Power-cut scenarios label intentional SIGKILLs; unexpected daemon
  failures still produce errors. Normal shutdown deletes the disposable disk, not the logs.

## One scenario folder, one runner

[`test/scenarios/`](../test/scenarios) contains ordinary modules with `name/0` and
`run/1`, using ExUnit assertions against the public device API and QEMU fault
controls. UI, CLI and CI use these same modules; there is no hardware-mock suite.

The runner establishes an eth0 DHCP baseline before each ordinary scenario and
reuses the booted device. Scenarios requiring a fresh disk declare `boot_options/0`.
A failed scenario causes a fresh boot before continuing; failed fault cleanup or
a runner timeout blocks further runs until the session is restarted. Only the
latest result is kept in memory.

The page, CLI endpoints, runner and scenarios exist only in host dev/test. The
runner refuses EC100 or arbitrary VMs; CLI requests use the page's session and
CSRF protection through a private Unix socket.

### Isolation

Development and CI run inside an empty user/network namespace. The device has
eth0 (Internet), eth1 (equipment) and eth2 (management, 192.168.77.2). Management is
never faulted. The controller uses 192.168.77.1 and development cookie `mycookie`.
A loopback-only socat proxy exposes Phoenix's Unix socket to the workstation.

All TAP interfaces, firewall rules, probe fixtures and Erlang distribution stay
inside the namespace. No workstation routes, firewall rules or VPN are changed.
The namespace has no public Internet access. Images are disposable files, never
physical disks. See the [system notes](../systems/nerves_system_x86_64/GATEWAY.md)
for the x86 platform's differences from EC100.

## Coverage and limits

Scenarios cover public status, projection clients, server restart/reconnect, draft
preservation, invalid inputs, cable loss, NIC removal, VM freeze, configuration
trials, reboot/crash persistence, disk errors, upstream outages, latency and loss.
The source folder is the authoritative list.

Probe fixtures accept real TCP/53 connections to VintageNet's default probe IPs;
they do not prove public Internet or Tailscale access. Receive-stall faults delay
all WAN receive traffic, not just DHCP. Disk faults return real EIO; removing the
fault does not heal a read-only guest filesystem. SIGKILL of QEMU is not physical
power loss: host disk caches remain intact.

Boot waits are bounded at 100 seconds, ordinary recovery at 30 seconds and Internet
detection at up to 90 seconds. A scenario has a five-minute outer limit. Guest
observations and timers are not mocked.

Bus protocols, physical LEDs/button/recovery, authenticated Tailscale traffic,
forwarding/NAT isolation and automated browser workflows remain unqualified.
QEMU does not reproduce EC100 peripherals, flash or its boot chain. See also the
[known MuonTrap limitation](networking.md#known-runtime-limitation).

## EC100 UI development

With a reachable device running compatible development firmware, run:

```sh
mix dev.ec100
```

The command uses the device node in `config/dev.exs`, derives the workstation
address from its route to that device, and serves Phoenix on loopback. Both ends
must use compatible OTP/Elixir and cookie `mycookie`. No QEMU scenarios run against it.
Backend selection is runtime configuration; restart the launcher after changing it.
Switching between QEMU and EC100 does not require a forced recompile or build cleanup.
Host HTTP access never counts as trusted USB access to the device. Use trusted
networks: development distribution and the UI grant device access.

## CI

`.github/workflows/qemu.yml` is opt-in (`workflow_dispatch`) on a trusted Linux x64
runner labelled `nerves-gate-qemu`. The runner needs the same prerequisites as a
workstation. It runs `mix setup`, then `mix ci`, and uploads diagnostic logs, never
disks. It does not run untrusted PR code. Runner registration and GitHub execution
remain operator setup.
