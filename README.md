# Nerves Gate

A two-port Ethernet remote-access gateway for EC100 and x86_64, built with
Nerves 2 and Phoenix LiveView. This repository is being rebuilt in small milestones.

## Development

Use Elixir 1.20 and the Erlang/OTP major version required by the target system.

```sh
mix deps.get
mix test
mix phx.server
# http://localhost:4000
```

Host mode must never modify the workstation's network. All browser assets are
local and checked in. To rebuild CSS: `cd assets && npm ci && npm run build`.
Node.js is not needed to compile firmware or use the setup page.

## Targets

```sh
MIX_TARGET=ec100 mix deps.get
MIX_TARGET=ec100 mix compile
MIX_TARGET=x86_64 mix deps.get
MIX_TARGET=x86_64 mix compile
```

Development currently uses these local checkouts in `mix.exs`:

- EC100: `/home/n0gg1n/Development/Work/ism/dev/nerves_system_ec100`
- Tailscale: `/home/n0gg1n/Development/Work/opencode/tailscale_ex`

EC100 retains its existing Nerves 2 system, bootloader, GPT storage layout and
A/B firmware contract. The x86 variant in `systems/x86_64` adds bridge and firewall
support to upstream commit `5d755dba94fff478eac2bfd90ba91d2e0025d4eb`.
Target system enablement/build verification is still in progress. See
[`systems/README.md`](systems/README.md) for the x86 source and changes.

## Firmware builds

`mix firmware` automatically prepares the official static `tailscaled` **1.102.3**
for the selected architecture, verifies its pinned SHA-256, and includes it at
`/usr/sbin/tailscaled`. The CLI is not needed by `tailscale_ex`. Packaging requires
`curl`, `sha256sum`, `tar`, and `install` on the build host. Verified archives are
cached under `_build/tailscale`; subsequent builds can use them without internet.
No software is downloaded on the device. Kernel TUN support is required to start
in kernel mode; starting the daemon does not enroll the device or enable LAN routing.

Nerves 2 requires a source timestamp. Target builds use the latest Git commit's
Unix timestamp, or `SOURCE_DATE_EPOCH` when supplied (required for source archives
without Git history). EC100 firmware assembly has been verified with OTP 29;
this is not an EC100 boot or Tailscale connectivity test.

## Networking and settings

`NervesGate.Network` owns Ethernet settings through VintageNet. Both `eth0` and
`eth1` always belong to `br0`; a missing or disconnected port does not block the
other. Only the bridge gets a management address. DHCP is the default; static
IPv4, a contiguous subnet mask (/1–/30), and an optional same-subnet router are
supported. No Ethernet DHCP server or NAT is configured. STP is enabled to reduce
loop risk; a newly connected port may take about 30 seconds to forward traffic.
The Layer 2 bridge stays up during management IP changes.

Settings live in `/data/nerves_gate.json` (host: `tmp/dev/nerves_gate.json`). The
version-1 file is validated and written by fsync + atomic rename with mode 0600.
No credentials or discovery status are stored in it. Corrupt/unsupported files
are not overwritten. Setup reviews changes, starts a 60-second trial, then asks
you to check equipment connectivity and explicitly confirm. Confirmation requires
an active bridge and matching address. Internet access is not required.

A GenServer, not the browser, owns the timeout. Only confirmed settings are on
disk; restarting the manager or rebooting cancels any trial. Failed apply/save
operations restore previous settings; rejected restore requests are retried.
VintageNet retries asynchronous interface failures, which remain visible in
bridge status. Keep an independent recovery path when changing your local IP.

## Tests

```sh
mix test                           # host simulation, configuration, rollback, LiveView
scripts/test_bridge.sh             # real Linux bridge in isolated user/network/mount namespaces
```

The integration script requires Linux user namespaces, `ip`, `brctl`, `ifconfig`,
`udhcpc`, `dnsmasq`, and `ping` in PATH. It never configures the workstation LAN.
It creates two disposable LAN peers and tests one/missing/two ports, hotplug,
gateway-to-peer traffic, transparent peer-to-peer traffic, real DHCP, static IP
changes and rollback. Its DHCP server exists only in the simulated existing LAN,
not in the gateway. This is **not** a Nerves boot or EC100 hardware test.

## Current scope

The offline LiveView setup and dashboard share the network manager and update
from discovery automatically. Host mode is explicitly labeled simulation; use
`NervesGate.Network.Host.simulate/1` in IEx to change observations. Tailscale will
use the refactored `sid2baker/tailscale_ex` LocalAPI interface. Its OTP application
starts automatically on firmware targets, supervising `/usr/sbin/tailscaled` in
kernel mode. Identity stays in `/data/tailscale_ex`; the socket is under `/run`.
Host simulation does not start or attach to the workstation's Tailscale daemon.
Enrollment UI, subnet forwarding, cellular and firmware upload remain unfinished.
The target web listener remains loopback-only until LAN access controls exist.
SSH recovery is key-only; set `NERVES_GATE_SSH_KEYS` to public keys at build time.

The local EC100 checkout includes fixed-role USB restoration (`d375405`). USB0
reconnection and USB1 modem transport have not been tested by this application
rebuild. Do not depend on USB provisioning yet.
Keep serial and Ethernet recovery available. Modem transport remains unverified.

No EC100 hardware behavior has been validated during this rebuild.
