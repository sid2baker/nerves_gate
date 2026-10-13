# Local Phoenix, device backend

One project, one device API, ordinary Erlang distribution. There is no second
backend implementation or connection manager. Firmware still serves its own UI.

## Daily commands

```sh
mix dev.ec100   # local Phoenix against the EC100
mix dev.qemu    # prepared Nerves QEMU image + local Phoenix
```

These are native Mix aliases in `mix.exs`. They select the backend before
compilation, start Erlang distribution, then run `phx.server` in the same VM at
**http://localhost:4000** with LiveReload and Tidewave. They always select
`MIX_TARGET=host`, `MIX_ENV=dev`, even if your shell still has firmware-build
settings exported. They do not build firmware, flash hardware, run sudo or change
host networking. Run `mix deps.get` once after checkout or dependency changes.

`mix dev.ec100` uses `nerves_gate@100.88.166.70`, configured in `config/dev.exs`.
The local node address is derived from the route to the device. No prompts,
node-name arguments or environment variables are required. Nerves mDNS discovery
is local-network discovery; it does not discover devices across Tailscale.

For QEMU, first prepare the image and TAP using the instructions below. The
launcher uses `_build/qemu/gateway.img`, `ng-qemu`, backend
`nerves_gate@192.168.77.2`; the local node address is derived in the same way.

**Every `MIX_ENV=dev` build uses `:mycookie`**, on both the local UI and the device.
No cookie variables or prompts are needed. Build the EC100/QEMU firmware with
`MIX_ENV=dev` too; production firmware retains its private native OTP cookie.
The development override never writes to the persistent cookie file.

The QEMU console is written to `_build/qemu/console.log`. When either QEMU or
Phoenix exits, the launcher stops the other process.

## Manual startup

Use the same Elixir minor version and compatible OTP as the firmware. The device
must run this revision of Nerves Gate and have distribution enabled. EC100 starts
it automatically when Tailscale is online; its Distribution page shows the node
and cookie. Both nodes must be able to reach each other's advertised addresses.

```sh
mix deps.get
export MIX_TARGET=host
export NERVES_GATE_BACKEND_NODE='nerves_gate@<device-address>'
mix compile --force
iex --name 'nerves_gate_ui@<workstation-address>' -S mix phx.server
```

Open **http://localhost:4000**. Phoenix code reload, browser live reload and
Tidewave (`http://localhost:4000/tidewave/mcp`) run locally. The endpoint is bound
to loopback. Tidewave and LiveReload are host-development dependencies only,
never firmware dependencies.

`NERVES_GATE_BACKEND_NODE` is read by `config/host.exs` **at compile time**.
The launchers handle recompilation. For manual startup, after changing or
unsetting it, stop the server and run `mix compile --force` with the new
environment before restarting. Mix cannot track external environment
variable changes from source timestamps alone. Changing application environment
at runtime does not switch backends. The host
starts only PubSub and the Phoenix endpoint, not device services or simulators.

EC100 and QEMU use the same underlying startup; only the device node/address
differ. There is no node discovery service or second application.

The development cookie is public. Erlang distribution grants full VM access and
is not encrypted. Use a trusted Tailscale network or
an isolated trusted network. Never expose EPMD (4369), distribution (device 9100),
or the development endpoint to the public Internet. The workstation's default
distribution port is dynamic; restrict it with normal OTP kernel flags if your
firewall requires a fixed port.

## What happens

- `NervesGateWeb.Backend` calls the existing `NervesGate` API, locally in firmware
  or via `:erpc.call/5` in remote development. Device commands and admission rules
  are unchanged. There is no local fallback.
- The device builds the full status, including its target, runtime and node.
  Cookie and enrollment URL reads remain separate from status and notifications.
- Remote LiveViews read fresh status every five seconds and on node up/down
  events. Local firmware views retain their existing property subscriptions.
  There is no observation bridge, mirrored state, reducer or operation log.
- Disconnection clears the displayed device state and disables commands. Erlang
  node notifications refresh the view promptly; later reads reconnect normally.
  Commands are never automatically retried. A lost reply can mean the command
  ran: read status before deciding to retry.
- Local HTTP addresses are not evidence of USB access to the remote device.
  Remote network changes always use the protected confirm/cancel trial.

## QEMU development network

The x86 system source is at
[`test/support/nerves_system_x86_64`](../test/support/nerves_system_x86_64/GATEWAY.md).
Its gateway artifact must be built; an upstream stock artifact is not equivalent.
Supply a verified x86 `tailscaled` binary as described in the main README.

```sh
MIX_TARGET=x86_64 MIX_ENV=dev mix deps.get
MIX_TARGET=x86_64 MIX_ENV=dev mix nerves.artifact.build nerves_system_x86_64
MIX_TARGET=x86_64 MIX_ENV=dev mix firmware
```

Development x86 firmware defaults to `nerves_gate@192.168.77.2` without any
node environment variable. `NERVES_GATE_DEVICE_NODE` can override this
**compile-time, development-only** firmware identity. It does not require
Tailscale enrollment, and Tailscale will not rename it. Production retains automatic Tailscale naming and its native OTP
cookie. Development firmware uses `:mycookie`.

Development x86 firmware reserves **eth2 at 192.168.77.2/24** for management.
Use three NICs: eth0 Internet, eth1 equipment, eth2 management. Trials only manage
eth0/eth1, so they cannot remove the management connection. The static eth2
configuration is not included in production firmware.

Create an isolated TAP on the workstation (requires permission; these commands
create a new interface, not modify the workstation's existing LAN):

```sh
sudo ip tuntap add dev ng-qemu mode tap user "$USER"
sudo ip addr add 192.168.77.1/24 dev ng-qemu
sudo ip link set ng-qemu up
mkdir -p _build/qemu
# Use a new disposable regular file, NEVER a physical disk. This erases its contents.
fwup -a -i _build/x86_64_dev/nerves/images/nerves_gate.fw -d _build/qemu/gateway.img -t complete
qemu-system-x86_64 -m 1024 -nographic \
  -drive file=_build/qemu/gateway.img,format=raw,if=virtio \
  -netdev user,id=wan -device virtio-net-pci,netdev=wan \
  -netdev user,id=equipment,net=10.0.3.0/24 -device virtio-net-pci,netdev=equipment \
  -netdev tap,id=management,ifname=ng-qemu,script=no,downscript=no \
  -device virtio-net-pci,netdev=management
```

Use backend `nerves_gate@192.168.77.2` and UI node
`nerves_gate_ui@192.168.77.1`; both development nodes use `:mycookie`. This avoids
NAT/EPMD port forwarding tricks and keeps distribution off the workstation's
public interface. Stop a manually started QEMU before using `mix dev.qemu`.
Keep the TAP for subsequent development runs;
remove it with `sudo ip link delete ng-qemu` when you no longer need it.

**QEMU build and boot verified.** The gateway system and development firmware
build successfully. `mix dev.qemu` starts the Nerves backend and workstation UI;
both HTTP endpoints respond, and both report the same x86 device node over
Erlang distribution. The workstation runs no device workers or hardware fakes.
A/B update and recovery behavior have not been qualified in QEMU.

There is no runtime host simulator: host startup requires a device backend.
Hardware fakes are compiled only for tests.

## Automated QEMU regression

```sh
mix test.qemu
```

Requires Linux with unprivileged user/network namespaces enabled, `unshare`,
`ip`, QEMU, fwup, and the locally built x86 system and verified x86 tailscaled
binary described above. The command rebuilds development firmware from current
source, then runs ordinary ExUnit in a fresh network namespace. It does not start
Phoenix on the workstation or use the development VM's image, TAP or QMP socket.
No sudo is needed. A missing system artifact must be built with the command above.

`test/support/qemu.ex` holds the test-only VM and QMP controls:
`start/0`, `disconnect_wan/1`, `reconnect_wan/1`, `reboot/1`, public API calls and
bounded status waits. `test/integration/qemu_test.exs` contains ordinary ExUnit
scenarios, each starting with a fresh disk:

- Cable loss and recovery under the x86 image's default Ethernet DHCP setup.
- Three consecutive disconnect/reconnect cycles.
- Invalid configuration rejected, with settings and management access preserved.
- Confirmed configuration survives a QMP hard reset and regains an address.

Boot has a 100-second deadline; baseline and recovery waits have 30-second
deadlines; each test has a 240-second timeout. This namespace has no upstream
Internet: **these are Ethernet/persistence tests, not Internet-availability tests**.

QMP stays reachable independently of guest networking. The management NIC is
never faulted. `try/after` restores the link, and ExUnit-owned MuonTrap processes
terminate the VM and EPMD even on test failure or timeout. The disposable disk is
removed after the test; the network namespace disappears with its processes.
Serial output, QEMU output, QMP messages, status snapshots and phase timestamps
remain in the printed `_build/qemu-tests/<run>/` directory for CI artifacts.
A failed scenario exits nonzero. No EC100 fault path exists.

The persistence scenario covers two failures found in real QEMU runs: the old
1.5-second shared interface-settling deadline was too short, and a hard reset
could truncate OTP's freshly generated cookie file. Interface changes now have
an 8-second budget inside the existing 10-second worker limit. Development
firmware supplies its public cookie in VM arguments before OTP reads persistent
state; production cookie handling is unchanged. Tests do not retry failed writes.

`mix dev.qemu` also exposes `_build/qemu/qmp.sock` for manual QMP control; its WAN
device is named `wan-nic`. Automated tests never connect to that socket.

## Checks

```sh
MIX_TARGET=host mix ci
```

The distributed test starts separate device/UI BEAM nodes. It checks UI-only
startup, compile-time selection, device-authoritative status, command execution,
USB-access stripping, unknown timeout outcomes, disconnected page
rendering and reconnection without replay. No real hardware is changed.
