# Nerves Gate

An Ethernet gateway with a small, local web UI, built with Nerves 2, Jido v3 and
Phoenix LiveView. EC100 is the primary target; x86_64 support is in progress.

## Use it

Open `http://<gateway-address>:4000` through LAN, USB or Tailscale.

- **Gateway** — Internet, equipment and Tailscale status at a glance.
- **Network** — choose an Internet connection and optionally add equipment.
- **Tailscale** — connect the gateway, see its address, rename or disconnect it.

A new gateway tries DHCP on both Ethernet ports independently. It suggests the
only plausible Internet port; it never joins networks or silently reassigns saved
roles. First setup is one form. Equipment and Internet are both optional.

First setup through verified USB saves directly. Other network changes have a
60-second **Keep changes / Restore previous settings** window. USB remains
independent for recovery. Technical details are collapsed until needed.

**This UI has no sign-in protection.** Anyone who can reach port 4000 can change
settings. Use trusted networks and restrict access with your Tailscale policy;
do not expose it to the public Internet. CSRF and same-origin checks remain enabled.

Tailscale connects **the gateway itself**. Equipment subnet routing, permissions,
remote equipment verification, cellular, failover and web firmware upload are not
implemented. This software does not start an Ethernet DHCP server or configure NAT.

See [networking and recovery](docs/networking.md) for addressing, rollback and
Tailscale behavior.

## Backend entry point

**Start at [`lib/nerves_gate.ex`](lib/nerves_gate.ex).** `NervesGate` exposes named
functions for LiveView, IEx/SSH and future interfaces. No dispatcher, client object
or knowledge of Jido is needed to use the backend.

```elixir
:ok = NervesGate.subscribe()               # subscribe before reading
status = NervesGate.status()

{:ok, id} = NervesGate.network_propose(settings)
:ok = NervesGate.network_confirm(id)        # or network_cancel(id)
:ok = NervesGate.remote_configure("my-gateway")
```

| Function | Result / meaning |
| --- | --- |
| `network_validate(settings)` | `{:ok, normalized}`; no changes |
| `network_propose(settings, opts \\ [])` | `{:ok, trial_id}`; applied with automatic rollback |
| `network_confirm(trial_id, opts \\ [])` | `:ok`; keep that trial |
| `network_cancel(trial_id, opts \\ [])` | `:ok`; restore saved settings |
| `remote_connect(hostname, opts \\ [])` | `:ok`; connection/enrollment accepted |
| `remote_configure(hostname, opts \\ [])` | `:ok`; hostname change accepted |
| `remote_disconnect(opts \\ [])` | `:ok`; sign-out accepted |
| `remote_login_url(opts \\ [])` | `{:ok, url_or_nil}`; private sign-in URL |

Failures return `{:error, %{code: code, message: message}}`. Read `NervesGate.status()`
separately after commands. Remote acceptance is not completion; check its operation
and error. An unknown outcome requires reading status before retrying.

Internally, ordinary OTP calls and deferred replies handle network commands. A small
Jido agent decides first-USB-setup auto-save; the runtime owns the independent
rollback timer and hardware worker. Remote is one bounded GenServer.
VintageNet owns saved LAN settings; Tailscale owns its identity and preferences.
There is no central state server, trial journal or connectivity retry agent.
Saving several interfaces is not a transaction: interruption can leave partially
saved settings. USB remains independent for recovery.

Jido v3 is pinned to immutable source commits. **Approved dependency exception:**
Jido's v3 Action engine requires Runic internally. NervesGate has no direct Runic
calls or workflows, and introduces no AI dependencies.

See the [action API](docs/action-api.md) for return values and UI mapping, and the
[architecture](docs/architecture.md) for ownership, lifecycle,
persistence tradeoffs and the exact dependency pins.

## Develop

Use Elixir 1.20 and the Erlang/OTP major version required by your Nerves system
(current EC100: OTP 29).

```sh
mix deps.get
mix ci                    # compile, format, tests, Credo, Dialyzer, duplication, architecture
mix phx.server            # http://localhost:4000
```

Host mode simulates Ethernet and Tailscale. It never modifies the workstation's
network or starts its VPN daemon. In IEx, `NervesGate.Network.Host.simulate/1`
changes simulated observations. Host HTTP listens on loopback only.

All browser assets are local and checked in. Rebuild CSS with
`cd assets && npm ci && npm run build`. Node.js is not needed on the device or to
compile firmware.

### Integration checks

These bootstrap isolated runtimes and are deliberately separate from `mix test`:

```sh
scripts/test_bridge.sh
MIX_TARGET=host mix run --no-start test/integration/tailscale_test.exs /absolute/path/to/tailscaled
```

The Linux network check requires user namespaces, `ip`, `brctl`, `ifconfig`,
`udhcpc`, `dnsmasq`, `ping` and `curl`. It creates disposable LAN/USB peers and checks
DHCP discovery, bridging, hotplug, static addresses, port roles, rollback and real
HTTP access. It does not configure the workstation LAN.

The Tailscale check uses a private userspace daemon, temporary identity storage
and a private socket. It does not enroll an account, attach to the workstation
daemon or change kernel routes. It checks cached status, configuration writes and
preservation of omitted preferences against daemon 1.104.1.

Neither check substitutes for a firmware boot or hardware test.

## Build firmware

```sh
export MIX_TARGET=ec100    # or x86_64
export MIX_ENV=prod        # omit development tooling from firmware
mix deps.get
mix firmware --overwrite
```

All targets share `mix.lock`. EC100 uses the local system checkout at
`/home/n0gg1n/Development/Work/ism/dev/nerves_system_ec100`, retaining its bootloader,
GPT and A/B update contract. See [systems/README.md](systems/README.md) for the
unfinished x86 system work.

The rootfs combines `rootfs_overlay/common` with `rootfs_overlay/<target>`. Supply a
checksum-verified static `tailscaled` binary for the selected architecture at
`rootfs_overlay/<target>/usr/sbin/tailscaled`, executable. Binaries are ignored by
Git. The EC100 overlay currently contains official ARM **1.104.1**; keep ARM and
x86 binaries separate. **Builds never download or replace the daemon.** The
library's optional `mix tailscale.install` still defaults to the older 1.102.3.

Target builds take the source timestamp from the latest Git commit. Set
`SOURCE_DATE_EPOCH` explicitly for source archives without Git history. Nerves
2.0.0-pre.4 handles that timestamp natively.

Set `NERVES_GATE_SSH_KEYS` to authorized public keys at build time. SSH is key-only;
serial/SSH IEx loads `/etc/iex.exs` and prints NervesMOTD. Keep the Nerves startup
guard enabled: it supplies Heart's initialization handshake and validates firmware
after the expected OTP applications start, without requiring Internet or setup.

Before an update, verify the device identity, firmware platform, and a local
recovery path. Firmware upgrades should preserve `/data` and Tailscale identity;
do not use a full-disk burn for an in-place update.
