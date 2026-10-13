# Nerves Gate

An Ethernet gateway with a small, local web UI, built with Nerves 2, ordinary OTP,
Alarmist and Phoenix LiveView. EC100 is the production target; an EC100-aligned
x86_64/QEMU test system is in progress.

## Use it

Open `http://<gateway-address>:4000` through LAN, USB or Tailscale.

- **Overview** — Internet, Remote access and Erlang distribution, in that order. Open a card for settings and connection details.
- **Equipment** — LAN ports, both RS485 buses and both CAN buses. Open a port for its configuration and diagnostics; the dedicated Internet port is hidden.
- **Device** — a small link for firmware/runtime information, identification and button/LED help.

A new gateway tries DHCP on both Ethernet ports independently. It suggests the
only plausible Internet port; it never joins networks or silently reassigns saved
roles. First setup and later changes use the same form under **Overview → Internet**.
Equipment and Internet are both optional.

First setup through verified USB saves directly. Other network changes have a
60-second **Keep changes / Restore previous settings** window. USB remains
independent for recovery. Technical details are collapsed until needed.

**This UI has no sign-in protection.** Anyone who can reach port 4000 can change
settings. Use trusted networks and restrict access with your Tailscale policy;
do not expose it to the public Internet. CSRF and same-origin checks remain enabled.

Tailscale connects **the gateway itself** and can share the confirmed dedicated equipment
IPv4 subnet. Use equipment's normal addresses; overlapping networks are unsupported.
Open the equipment LAN page to turn subnet sharing on or off.
Route approval and permissions belong to your tailnet; reachability is not verified. Device can identify the gateway with a
five-second blink. RUN shows application state, USER1 Internet + Tailscale health, and USER2 alarms.
The physical button identifies on a short release and requests reboot after 5 seconds.
The 30-second factory-reset gesture erases EC100 application data and reboots;
physical qualification is pending. Recovery tests use in-memory fakes.
See [LEDs and button](docs/indicators.md).
CAN/RS485 workspaces offer bounded receive-only captures and explicitly authorized
Modbus register reads, with no scans, writes or retries. Physical CAN still needs
qualification; RS485 is limited to the BSP-qualified 9600 8N1 profile.
Cellular configuration and Ethernet-preferred backup are prepared, using VintageNet
routing. **The EC100 modem still needs identification, a matching driver and BSP
qualification; default firmware rejects cellular setup.** See [cellular preparation](docs/networking.md#internet-source-and-cellular-preparation).
Remote bus bridges and web firmware upload are not implemented.
There is no Ethernet DHCP server or Internet sharing. Tailscale owns VPN subnet NAT;
firmware enables IPv4 forwarding behind a default-deny policy.
See the [UI structure and next stages](docs/ui.md).

See [networking and recovery](docs/networking.md) for addressing, rollback and
Tailscale behavior.

## Backend entry point

**Start at [`lib/nerves_gate.ex`](lib/nerves_gate.ex).** `NervesGate` exposes named
commands and status queries for LiveView, IEx/SSH and future interfaces. No dispatcher,
client object or command/query framework is needed.

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
| `remote_disconnect(opts \\ [])` | `:ok`; disconnect accepted; enrollment kept |
| `remote_login_url(opts \\ [])` | `{:ok, url_or_nil}`; private sign-in URL |
| `equipment_share(opts \\ [])` | `:ok`; confirmed equipment subnet advertisement read back |
| `equipment_unshare(opts \\ [])` | `:ok`; equipment subnet withdrawal read back |
| `bus_configure(port, params, opts \\ [])` | `:ok`; apply live CAN settings or RS485 opt-in |
| `bus_capture(port, opts \\ [])` | `:ok`; bounded receive-only capture accepted |
| `modbus_read(port, params, opts \\ [])` | `:ok`; one authorized register read accepted |
| `identify(opts \\ [])` | `:ok`; five-second LED identification started |

Failures return `{:error, %{code: code, message: message}}`. Read `NervesGate.status()`
separately after commands. Remote acceptance is not completion; check its operation
and error. An unknown outcome requires reading status before retrying.

Internally, one Network GenServer owns commands, USB auto-save, the independent
rollback timer and a bounded hardware worker. Remote is another bounded GenServer.
VintageNet owns saved LAN settings; Tailscale owns its identity and preferences.
There is no central state server, trial journal or connectivity retry agent.
Saving several interfaces is not a transaction: interruption can leave partially
saved settings. USB remains independent for recovery.

Each domain reports conditions through Alarmist. Restore/recovery faults are immediate
errors; Internet loss, Tailscale availability/health, equipment discovery and enabled
bus-port loss become warnings after two continuous seconds. Intentional disabled
states are not faults. VintageNet observes the permitted Internet-facing interfaces; Tailscale
Running is not an Internet-availability signal.
Use `Alarmist.info()` or `Alarmist.subscribe_all()`. Alarms never control trials or
trigger automatic remedies. There is no agent/AI dependency stack.

See the [action API](docs/action-api.md) for return values and UI mapping, and the
[architecture](docs/architecture.md) for ownership, lifecycle,
persistence tradeoffs and fault reporting.

## Develop

Use Elixir 1.20 and the Erlang/OTP major version required by your Nerves system
(current EC100: OTP 29).

```sh
mix deps.get
mix ci                    # compile, format, tests, Credo, Dialyzer, duplication, architecture
mix dev.ec100             # device backend + local UI at http://localhost:4000
mix dev.qemu              # x86 Nerves backend + local UI
```

For local Phoenix development against a device backend, use `mix dev.ec100` or
`mix dev.qemu` after the [one-time setup](docs/development.md). The launchers select
the backend before compilation and start a UI-only host with code reload,
LiveReload and Tidewave. The existing API runs on the device over Erlang distribution.

There is one backend, on EC100 or x86 Nerves. Both the device's Phoenix UI and
optional workstation Phoenix UI use it. The workstation runs no device services,
VPN daemon or hardware simulator. Its HTTP endpoint listens on loopback only.
Hardware fakes live under `test/support` and compile only for tests.

All browser assets are local and checked in. Rebuild CSS with
`cd assets && npm ci && npm run build`. Node.js is not needed on the device or to
compile firmware.

### Integration checks

These bootstrap isolated runtimes and are deliberately separate from `mix test`:

```sh
scripts/test_bridge.sh
scripts/test_equipment.sh
scripts/test_routing.sh
MIX_TARGET=host mix run --no-start test/integration/buses_test.exs --pty
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

The routing check uses a private namespace and `iptables` to verify firmware's
default-deny IPv4 forwarding, local recovery access, and fail-closed setup. It does
not test Tailscale's rules/NAT or authenticated end-to-end equipment access.

The equipment check uses a private namespace for ARP/vcan. The bus check requires
`socat` and tests only disposable serial PTYs: fragmented Modbus replies, CRC/errors,
timeouts, no retry, passive capture bounds and cleanup. See [bus safety](docs/buses.md).
None of these checks substitutes for a firmware boot or hardware test.

## Build firmware

```sh
export MIX_TARGET=ec100    # x86_64 is the development/QEMU test target
export MIX_ENV=prod        # omit development tooling from firmware
mix deps.get
mix firmware --overwrite
```

Erlang distribution starts automatically once Tailscale is online, named
`nerves_gate@<assigned-Tailscale-IPv4>`. No build-time node name or tailnet is needed.
**Overview → Erlang distribution** shows the node name and cookie. Production uses
OTP's persistent cookie; `MIX_ENV=dev` builds always use the public `:mycookie`.
Anyone who can read that page and reach distribution has full VM access.
Use trusted networks or Tailscale. See [connecting Livebook](docs/networking.md#erlang-distribution-and-livebook).

All targets share `mix.lock`. EC100 uses the local system checkout at
`/home/n0gg1n/Development/Work/ism/dev/nerves_system_ec100`, retaining its bootloader,
GPT and A/B update contract. The x86/QEMU system lives under
[`test/support/nerves_system_x86_64`](test/support/nerves_system_x86_64/GATEWAY.md).
It shares EC100's gateway runtime configuration while retaining x86-specific
boot and driver support; build/boot validation is still pending.

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
