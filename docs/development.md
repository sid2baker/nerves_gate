# Development

## Get started

With the [prerequisites](#prerequisites) installed, run from the repository root:

```sh
mix setup
mix dev.qemu
```

Wait for **QEMU ready**, then open **http://localhost:4000** for the gateway UI or
**/tests** for the device test bench. Readiness requires both the private CLI socket and the loopback HTTP listener.
No EC100, Tailscale login, environment file or manual network setup is needed.

`mix setup` checks the workstation, installs missing Hex/Rebar/Nerves bootstrap,
fetches host and x86 dependencies, verifies a pinned Tailscale archive and installs
its x86 daemon, then downloads the prebuilt EC100 QEMU system from GitHub Releases.
First setup needs Internet access and space for dependencies and the system SDK,
but does not rebuild Linux or Erlang. Reruns reuse the download cache. A different
existing x86 daemon is not overwritten: remove it explicitly if you want setup to
install the pinned one.
Setup neither boots QEMU nor runs tests, and never touches the ARM daemon or EC100 BSP.

### Prerequisites

- **Linux x86_64 or aarch64**. No host TAP device, network namespace or elevated privilege is needed.
- **Elixir 1.20 / OTP 29**; `mise install` uses the versions in `mise.toml` if you use mise.
- **fwup**, available on `PATH`; see its [installation guide](https://github.com/fwup-home/fwup#installing).
- Git, a C compiler, make, pkg-config, **QEMU 8.2+ with user and stream networking**,
  util-linux (`flock`) and inotify-tools.

For Debian/Ubuntu, the last group can be installed with:

```sh
sudo apt install git build-essential pkg-config qemu-system-x86 util-linux inotify-tools
```

On an Apple Silicon Mac, use an arm64 Ubuntu [OrbStack](https://orbstack.dev) machine
(`orb create --arch arm64 ubuntu nerves-gate`) with the packages above and fwup's
arm64 `.deb`. Clone the repository inside the machine, not under `/Users`, to use
a case-sensitive filesystem for builds. QEMU emulates the x86 guest there;
OrbStack forwards the machine's `localhost:4000` to the Mac. Avoid amd64 machines:
the BEAM JIT fails under Rosetta.

QEMU's libslirp supplies DHCP, DNS forwarding and outbound Internet. An Elixir
process forwards real Ethernet frames over private Unix sockets and applies cable
and packet faults. There is no external DHCP daemon or host network setup.
Install the toolchain and fwup separately. Docker is needed only by maintainers
building the system from source, not for normal setup, firmware builds or QEMU.
`mix setup` checks QEMU capabilities and reports missing tools; it does not install
OS packages or change workstation security policy.

## Daily workflow

Keep `mix dev.qemu` running in one terminal. It builds current development firmware,
boots a disposable disk and starts workstation Phoenix with code reload,
LiveReload, Volt and Tidewave. Phoenix serves the same Endpoint on a private Unix
socket for CLI clients and a loopback-only Bandit listener for the browser.
Tidewave accepts Unix-socket peers in this session; its Origin checks stay enabled
and no workstation listener is opened to remote hosts. Configure Tidewave MCP clients with
`http://localhost:4000/tidewave/mcp` (adjust the port when using `--port`). Its
metadata is at `/tidewave/config`; the root `/config` and `/mcp` paths are not
Tidewave routes. EC100 development keeps Tidewave's default local-only policy.
Host UI changes reload; device code changes require restarting the command to
rebuild firmware. Run `mix setup` again after changing dependencies or the local
Nerves system.

In another terminal:

```sh
mix test --only cable_loss       # one scenario on the running device
mix test                        # all scenarios on that same session
```

Results also appear at **http://localhost:4000/tests**. The bench has two shared modes:

- **Scenarios** runs the same modules as the CLI and CI, with current progress and
  per-scenario results. Fresh-disk scenarios are labelled; the page asks for
  confirmation before starting a run. Some scenarios reboot or replace the device,
  and any failed scenario also replaces its disk, discarding Tailscale enrollment.
- **Manual** exclusively holds the bench until you switch back to Scenarios.
  Connect the Internet router to LAN1, LAN2, or neither; disconnect/reconnect
  either cable; inject an Internet outage or 50% uplink loss; add/remove 200 ms
  latency; and pause/resume the VM. Moving the router preserves cable faults and
  never changes gateway settings, NIC identities, the disk or enrollment. Actions are
  serialized by the backend, not merely disabled in the UI. CLI runs are rejected
  while manual control is held; manual actions are rejected during scenario runs.

Connections and manual faults survive page reloads and closing the browser.
**Clear all faults** resumes the VM, puts Internet on LAN1, reconnects both cables,
and removes uplink faults; it does not change gateway settings, replace the disk
or erase enrollment. Switching back to Scenarios performs
that cleanup before releasing control. Recovery is asynchronous: a cleared fault
is not proof that Internet or Tailscale has recovered. A control timeout or cleanup
failure blocks the bench until the session is restarted.

The live device summary uses the same device-owned projection stream as the rest of
the UI. Injected faults are shown separately from observations; while paused, a VM's
last observation can remain visible until distribution detects the loss. One shared
in-memory log retains the last 100 actions, fault changes and runner events across
both modes. It does not record private login links or distribution credentials.

Only one controller is admitted at a time; avoid editing device settings elsewhere
during a run. The bench lock coordinates fault controls and scenario runs, not all
gateway settings pages. The UI reconnects after reboots; do not keep valuable state
on the disposable device.

For a clean, standalone run, stop your development session first, then run:

```sh
mix test --ci                   # boot, run the same scenarios, shut down
mix ci                          # static quality gates, then the same clean run
```

Agents use the session you started and focused `mix test --only <scenario>` checks.
Starting/stopping `mix dev.qemu` and running full `mix ci` remain operator actions.
`mix test.qemu` is a compatibility alias for `mix test`.

Commands select the appropriate host dev/test environment even if firmware
variables remain exported.

### Frontend assets

Browser sources live in `assets/css/` and `assets/js/`. [Volt](https://hexdocs.pm/volt/)
serves them inside the host Phoenix endpoint, watches sources and templates (including
`dev/`), and updates CSS without a page reload. JavaScript entry changes reload the
page. No Node.js, npm commands or separate asset watcher are needed. After adding or
updating host dependencies/configuration, restart your development session.

Before committing asset changes or building firmware, run:

```sh
mix assets.build                                   # host-only JS bundle + Tailwind CSS
MIX_TARGET=host MIX_ENV=dev mix volt.js.check        # JS formatting and lint
```

`mix format` also formats JavaScript on the host. Commit the generated files under
`priv/static/assets/` with their sources. Firmware serves those files directly;
it never loads Volt or its native tooling. Stable entry filenames and ETag
revalidation avoid needing a Volt runtime manifest reader on the device. The
JavaScript bundle includes Phoenix and LiveView from the locked Mix dependencies,
not separate npm versions. Rebuild after updating either dependency too.

Volt's first Tailwind build downloads its compiler into the host npm_ex cache.
Firmware builds need only the checked-in output, not that cache or frontend tooling.
The host development CSP permits inline styles for Volt's error overlay; firmware
keeps its strict policy.

## Which configuration is used?

**`MIX_TARGET` selects where the code runs, not which device to connect to.**
`MIX_ENV` independently selects development (`dev`), testing (`test`) or production
(`prod`) behavior. `dev` is the default; it is not a device type.

Only these five combinations are supported. `config/config.exs` rejects other
combinations, loads common settings, then imports exactly one platform file:

| `MIX_TARGET` | `MIX_ENV` | Platform file | Purpose |
| --- | --- | --- | --- |
| `host` | `dev` | `config/host.exs` | Workstation UI/tools with code reload (default) |
| `host` | `test` | `config/host.exs` | Test/CI tooling without development reloaders |
| `x86_64` | `dev` | `config/x86_64.exs` | QEMU firmware for development and tests |
| `ec100` | `dev` | `config/ec100.exs` | Physical-device development |
| `ec100` | `prod` | `config/ec100.exs` | Deployment firmware |

There is no separate test firmware. `mix test` runs as `host/test` against the
same `x86_64/dev` firmware used by the development UI; CI uses that firmware too.
The host environment changes tooling behavior, not the scenarios or device logic.

Both firmware platform files first import `config/firmware.exs` for shared device
services, then add their own hardware and recovery-network settings. Workstation
code reload and LiveReload live in `host.exs`, enabled only in `dev`; there is no
separate `dev.exs` or catch-all `target.exs`.

At startup, `config/runtime.exs` supplies the HTTP session secret and the host's
remote `backend_node`. **That node selects the connection destination**, not
`MIX_TARGET`. The development launchers supply it:

- `mix dev.qemu` builds `x86_64` firmware, then runs the `host` UI connected to it.
- `mix dev.ec100` discovers EC100 gateways on the current tailnet and runs the
  `host` UI connected to one. It does not build or flash EC100 firmware.
- `MIX_TARGET=ec100 mix firmware` builds EC100 firmware; it does not connect to or
  flash a device.

The EC100 system is pinned to a GitHub release tag in `mix.exs`. Run
`MIX_TARGET=ec100 mix deps.get` to fetch its sources; firmware builds download the
matching prebuilt system automatically. No local BSP checkout or system rebuild
is needed. The matching GitHub release must be published for Nerves' tag-based
artifact downloads; a draft release is not sufficient.

Do not globally export a target for everyday development. The launchers and test
command select their targets automatically; use per-command `MIX_TARGET=...` for
explicit firmware builds.

### Troubleshooting

- **Port 4000 in use:** run `mix dev.qemu --port 4001`.
- **CLI cannot reach a session:** start `mix dev.qemu`; tests use its private Unix socket.
- **Distribution port 9100 in use:** the QEMU management forward requires that
  loopback port. Resolve the conflict yourself; the launcher never stops another
  process. EPMD, guest HTTP and SSH use session-selected loopback ports.
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

The runner restores the physical baseline (Internet on LAN1, LAN2 on equipment,
both cables connected), establishes an eth0 DHCP configuration before each ordinary
scenario, and reuses the booted device. Scenarios requiring a fresh disk declare `boot_options/0`.
A failed scenario causes a fresh boot before continuing; failed fault cleanup or
a runner timeout blocks further runs until the session is restarted. Only the
latest result and the last 100 bench events are kept in memory. The `test_bench`
scenario exercises runner admission and the real manual fault driver's cleanup,
including cleanup with a paused VM and combined faults. `mix test --only frontend_assets`
checks host and firmware CSS/JS delivery, firmware cache revalidation and strict CSP,
Tidewave access through the development proxy with its Origin guard intact, and
absence of the Volt and Tidewave runtimes on the guest. Restart `mix dev.qemu`
after rebuilding assets so that this check sees the new files in firmware too.
`mix test --only dev_discovery` checks service discovery against the real guest
and verifies that the EC100 launcher excludes QEMU and rejects ambiguous selections.

`mix test --only topology` moves the real Internet connection between stable NICs,
checks HTTPS and unchanged settings/identities, removes Internet entirely, and
verifies that even explicit routes cannot forward through equipment or management.
`test_bench` also covers moving the Internet cable while another cable fault is
active and restoring topology during cleanup. `power_saved` checks that external
connections and cable faults survive a VM process replacement. `projection_stream` checks that
ambiguous discovery does not misreport two online interfaces as disconnected.

The page, CLI endpoints, runner and scenarios exist only in host dev/test. The
runner refuses EC100 or arbitrary VMs; CLI requests use the page's session and
CSRF protection through a private Unix socket.

### Isolation

One owned QEMU process supplies the virtual hardware and libslirp network stacks.
One Elixir `TestNetwork` process forwards actual Ethernet frames over private Unix
sockets. No workstation interfaces, routes, DNS files, firewall rules or VPN are
changed. The guest runs real DHCP, DNS, VintageNet checks, HTTPS and tailscaled;
there are no synthetic Internet responders or device-status overrides.

```text
eth0 / LAN1 ──┐     Elixir relay ── QEMU hub + libslirp ── Internet
              ├── one selected LAN; the other on isolated equipment
eth1 / LAN2 ──┘
eth2 ────────────── fixed management gate ── restricted libslirp ── loopback forwards
```

The Internet backend has gateway `10.0.2.2` and DNS `10.0.2.3`. Default wiring is
LAN1 → Internet, LAN2 → equipment; Off puts both ports on equipment. Equipment
is a real isolated Ethernet segment without an IP/DHCP/DNS server. Management
stays `192.168.77.2/24`, with virtual host `192.168.77.1`, and is never faulted.

The relay owns actual attachments, cable settings and packet queues. QMP mirrors
cable state into guest carrier. A running guest acknowledges unplug before a
move; a paused CPU cannot observe intermediate transitions. NIC IDs, MACs and
settings never change when cables move. QEMU starts paused: streams and saved
carrier states are applied before firmware runs. Topology, cable and uplink fault
settings survive VM replacement in Elixir; queued packets and libslirp's live
DHCP/NAT state do not. A fresh disk restores the baseline.

The routed frame gate denies unsupported encapsulation, IPv6, source-routed IPv4,
spoofed source networks and virtual-host/loopback access, with explicit ARP, DHCP
and DNS allowances. Equipment never forwards to the Internet socket; management
also uses libslirp `restrict=on`. `topology` supplies an explicit route **and a
neighbor entry** to prove forbidden IP frames are rejected, rather than merely
failing ARP. The gate does not implement networking protocols or TCP state.

The QEMU-only node identity is `nerves_gate@127.0.0.1`, reached through the owned
loopback forward to guest distribution port 9100. EPMD, guest HTTP and SSH have
explicit loopback forwards on session-selected ports. The launcher sets
`ERL_EPMD_PORT` **before the controller BEAM starts**. The controller initiates
authenticated distribution connections and listens for none; it neither starts
nor replaces workstation EPMD. Projection
notifications use that bidirectional connection. Physical EC100 discovery is unchanged.

All socket files and disposable disks belong to a private session directory.
Relay loss has no bypass: the controller blocks admission and stops its owned VM.
QMP and power-cut operations validate the supervised process's ownership.
Raw packets are excluded from OTP status/crash reports and event logs.

This is **network isolation, not an OS or hostile-local-user sandbox**. Like the
existing privileged localhost UI, the loopback management forwards trust local
workstation users. Ordinary outbound LAN/tailnet access still follows workstation
routing/VPN policy. DNS forwarding to the workstation resolver is intentional;
arbitrary workstation-loopback services are not available through the Internet
backend. An enrolled guest remains reachable through its own Tailscale identity
according to tailnet policy. Images are files, never physical disks; see the
[system notes](../systems/nerves_system_ec100_qemu/GATEWAY.md).

### Network control API

Scenarios and manual controls use the same partial-map operation on the runner's
owned VM handle. Omitted fields are preserved; unknown keys and invalid values
are rejected before changing forwarding. There is no generic topology DSL.

```elixir
alias NervesGate.TestQemu, as: Qemu

Qemu.network(vm, %{internet: :lan2})
Qemu.network(vm, %{cables: %{lan1: false}})
Qemu.network(vm, %{uplink: %{delay_ms: 200, loss: :alternate}})
Qemu.network(vm)        # current configuration
Qemu.network_stats()   # actual forwarding, drops, queue delays and overflow
Qemu.network(vm, NervesGate.TestNetwork.defaults())
```

`internet` is `:lan1 | :lan2 | :off`; each cable is a boolean. `delay_ms` is
0–5000 and `loss` is `:none | :alternate | :all`. Loss is deterministic: every
other eligible outgoing packet, not a random probability. Outage/loss precede
delay, while local ARP/DHCP and management bypass Internet faults. Each delayed
frame gets a monotonic deadline; this is not QEMU's periodic buffer filter.
Queues are bounded to 4096 frames/4 MiB, sockets use demand-limited reads, and
stale/overflow drops are counted separately. Changing settings discards pending
impaired packets rather than flushing a surprise burst onto a new connection.

These drivers do not replace runner admission. Cleanup resumes the VM before
restoring the default map; uncertainty blocks the bench. The UI's choices are
ordinary data mapping action names to these same patches.

### Real Internet and Tailscale

After **QEMU ready**, configure eth0 with DHCP in the UI. `/remote` uses the real
guest tailscaled: connect with a unique device name and follow the private login
link yourself. No workstation identity or auth key is copied into the guest.
Use a disposable test tailnet/device; the development UI and distribution are
privileged, and running scenarios can replace the disk and discard enrollment.
Remove obsolete QEMU devices from your tailnet after testing.

Focused checks use the same scenarios in the UI, CLI and CI:

```sh
mix test --only topology          # move Internet, stable NICs, no alternate uplinks
mix test --only internet          # guest DNS + verified HTTPS, outage, recovery
mix test --only latency           # HTTPS with 200ms uplink delay
mix test --only loss              # 50% uplink loss, management and HTTPS recovery
mix test --only firewall          # guest IPv4/IPv6 filter, NAT and mangle tables
mix test --only tailscale_login   # fresh guest checks firewall and obtains a private login link
```

`mix test --only ssh_access` uses a fresh disposable disk and an extra restricted
libslirp Ethernet path named `usb0` inside the guest, with its own loopback SSH forward. It checks actual SSH password/key
handshakes, rejection on non-USB management, key persistence/revocation across
reboots, input validation and failed writes. This qualifies the kernel/authentication
boundary, not EC100 USB gadget hardware. Management `eth2` is never renamed or faulted.

The `firewall` check needs neither Internet nor Tailscale enrollment. It reads
tables without changing rules and is also a prerequisite in `tailscale_login`.
The other checks require working public Internet access. `internet`, `latency` and
`loss` use `https://example.com/` with the guest's CA store and hostname verification.
Outage/loss/delay act on eligible guest-to-libslirp Ethernet traffic, including
DNS requests, not on management. This is not wire-for-wire equivalent to a
post-routing ISP link: DNS caching, fragmentation and TCP proxy buffering differ.
The latency scenario checks actual per-frame queue residence time as well as HTTPS.
At 50% packet loss, HTTPS may fail; the scenario checks counted alternating drops,
working management during the fault, and successful HTTPS after restoration.
External DNS/HTTPS/Tailscale service failures are genuine test failures, not skipped
or replaced with fixtures. `tailscale_login` uses a fresh disposable disk and never
completes account enrollment or prints the login link; it proves the control-server
handshake and that HTTPS Serve waits for enrollment, not authenticated peer traffic.
The scenario also checks Serve admission and one-attempt-per-DNS-name rules;
`frontend_assets` checks that LiveView session validation requires a matching
cookie and CSRF token, while allowing HTTPS origins over the local HTTP backend.
Use the UI login for peer access, actual HTTPS/certificate checks and approved
equipment-subnet sharing checks.

## Coverage and limits

Scenarios cover public status, projection clients, server restart/reconnect, draft
preservation, invalid inputs, cable loss, NIC removal, VM freeze, configuration
trials, reboot/crash persistence, disk errors, upstream outages, latency and loss.
The source folder is the authoritative list.

Internet checks originate inside the guest, including DNS and certificate-verified
HTTPS; Tailscale login uses the real daemon and public control server. The uplink
is IPv4 and uses userspace translation, not an EC100 PHY or a real ISP router:
throughput, IPv6 and direct-versus-relayed Tailscale paths need separate qualification.
Receive-stall faults delay all LAN1 receive traffic, not just DHCP. Disk faults
return real EIO; removing the
fault does not heal a read-only guest filesystem. SIGKILL of QEMU is not physical
power loss: host disk caches remain intact.

Boot waits are bounded at 180 seconds to accommodate fresh-disk initialization
under software emulation; the launcher allows 240 seconds for the guest and host
HTTP endpoint together. Ordinary recovery is bounded at 30 seconds and Internet
detection at up to 90 seconds. A scenario has a five-minute outer limit. Guest
observations and timers are not mocked.

Bus protocols, physical LEDs/button/recovery, authenticated Tailscale traffic,
forwarding/NAT isolation and automated browser workflows remain unqualified.
QEMU does not reproduce EC100 peripherals, flash or its boot chain. A cellular
uplink/emulation is deferred until the actual EC100 modem and its data/control
interfaces are known; cellular remains disabled on both firmware targets.
See also the [known MuonTrap limitation](networking.md#known-runtime-limitation).

## EC100 UI development

Connect workstation Tailscale to the device's tailnet. With the device online
and running compatible development firmware, run:

```sh
mix dev.ec100
```

The command reads the existing local Tailscale daemon, probes online peers for
the `nerves_gate` Erlang service, and authenticates with a bounded, read-only
`NervesGate.target/0` call. It connects automatically only when exactly one EC100
answers; QEMU gateways are excluded. It does not start or reconfigure Tailscale.
If none answer, it reports an error instead of opening a disconnected UI. If
several answer, it lists explicit commands to choose one:

```sh
mix dev.ec100 --node nerves_gate@100.101.102.103
```

Use the device's actual node name (`nerves_gate@<Tailscale IPv4>`), not its
MagicDNS alias. `--node` probes only that address and still verifies it is an
EC100; it also requires connected workstation Tailscale. Both ends must use
compatible OTP/Elixir and cookie `mycookie`. Tailnet policy must allow EPMD
(TCP 4369) and the device's Erlang distribution port. The local daemon must be
readable through `/var/run/tailscale/tailscaled.sock`.

Phoenix serves on loopback; the UI distribution node uses the workstation's
Tailscale IPv4. No QEMU scenarios run against EC100. Backend selection is runtime
configuration; restart the launcher to discover again or choose another device.
Switching between QEMU and EC100 does not require a forced recompile or build cleanup.
Host HTTP access never counts as trusted USB access to the device. Use trusted
networks: development distribution and the UI grant device access.

## Maintaining the QEMU system

The package is `systems/nerves_system_ec100_qemu`; the application target stays
`x86_64`. Its `VERSION` is independent of the application and upstream system.
The package's own `CHANGELOG.md` supplies release notes verbatim; upstream history
is retained separately in `UPSTREAM_CHANGELOG.md`.

For kernel, OTP, Buildroot, toolchain or other system build-input changes:

1. Update the system and bump `VERSION` (initial version: `0.1.0`). Add a dated
   `## <version> - YYYY-MM-DD` section to its changelog. Use level-three category
   headings and bullets; keep fenced code examples in the development guide.
2. Keep the system dependencies aligned between the application and system
   `mix.lock` files. The release check rejects drift. System dependency locks are
   included in Nerves' source fingerprint; documentation is not.
3. Push the changes to `main`. `.github/workflows/ec100-qemu-system.yml` checks
   whether publication is needed, builds the artifact, creates the
   `ec100-qemu-v<version>` tag/release, uploads and checks the artifact digest,
   and verifies a fresh download using Nerves' normal artifact resolver.

The workflow runs only trusted `main` code on a GitHub-hosted Ubuntu 24.04 runner;
no self-hosted machine is needed for system publication. It installs the pinned
Elixir/OTP toolchain and host tools, uses Docker for the build, and caches source
downloads between runs. Builds consume GitHub Actions minutes and must fit hosted
runner resources; the first complete build still needs CI qualification. The
repository's `GITHUB_TOKEN` supplies release access. Publication is serialized
and does not boot QEMU or run full CI. Ordinary gateway code changes do not
rebuild the system. Documentation-only system changes check
the release but reuse its artifact.

Published tags/assets are never overwritten. Changed build inputs under an
already-released version fail with a request to bump `VERSION`. A re-run skips an
already-published matching release. Release discovery includes drafts. An
interrupted draft can resume from a publisher-repair commit only if the entire
system directory (including deleted files), root `mix.lock` and `mise.toml` still
match its tag, and any existing artifact bytes match the new build. The tag is
never moved. Conflicting draft bytes require explicit maintainer cleanup, not an
automatic overwrite. Releases are not marked as the application's latest release.
The first release must finish before clean `mix setup` downloads can succeed. A missing artifact fails clearly; setup never silently falls back to
an hour-long source build.

For deliberate local system development (Docker required):

```sh
MIX_TARGET=x86_64 MIX_ENV=dev mix deps.get
MIX_TARGET=x86_64 MIX_ENV=dev mix nerves.artifact.build nerves_system_ec100_qemu
mix setup
```

Inspect the exact version, fingerprinted artifact name and changelog notes without
building or contacting GitHub:

```sh
MIX_TARGET=x86_64 MIX_ENV=dev elixir -r dev/artifact_release.ex -S mix nerves.artifact.release plan
```

The workflow also supports manual dispatch on `main` for retries. Do not replace
this custom system with an upstream x86 artifact: their networking capabilities
differ. This is real gateway software on virtual x86 hardware, not an EC100
peripheral simulator. After the artifact is available, restart your `mix dev.qemu`
session and run `mix test --only system_artifact` to check the guest's system
version and firmware platform, plus release-note, draft-discovery and safe-retry
contracts.

## CI

`.github/workflows/qemu.yml` is opt-in (`workflow_dispatch`) on a trusted Linux x64
runner labelled `nerves-gate-qemu`. The runner needs the same prerequisites as a
workstation. It runs `mix setup`, then `mix ci`, and uploads diagnostic logs, never
disks. It does not run untrusted PR code. Runner registration and GitHub execution
remain operator setup.
