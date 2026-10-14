# Development and QEMU scenarios

One application backend runs on EC100 or x86 Nerves. Workstation Phoenix calls its
public API over Erlang distribution; it does not emulate device services.

## Daily commands

```sh
mix dev.qemu                     # boot one disposable device and Phoenix
# Open http://localhost:4000/tests
mix test --only cable_loss        # another terminal: run one scenario
mix test                         # run all scenarios on that same device
mix test --ci                    # boot clean, run the same scenarios, shut down
mix ci                           # static quality gates, then mix test --ci
mix dev.ec100                    # workstation UI against the real EC100
```

`mix test.qemu` is a compatibility alias for `mix test`, not a different suite.
The commands select host dev/test even if firmware environment variables remain
exported. Command implementations live in `dev/mix/tasks/`, not `mix.exs`.

`mix dev.qemu` builds current development firmware, boots a new disposable disk,
and keeps it running. It never opens the old `_build/qemu/gateway.img` or any
physical disk. Restart the command to use new firmware. Use `--port 4001` if
another development server already owns port 4000. A session lock prevents two
launchers sharing the same socket; after an abrupt crash, remove
`_build/qemu-dev/session.lock` only after checking that the session has stopped.

## One scenario folder, one runner

`test/scenarios/*.ex` contains ordinary modules with `name/0` and `run/1`.
They use ExUnit assertions against the real public device API and concrete QEMU
fault controls. There is no scenario DSL, host fake or separate smoke suite.

The `/tests` page lists every scenario. Run one or all; see the active phase,
results, durations and assertion failures. CLI-triggered runs appear on that same
page. Only one run is admitted at a time; only the latest result is kept in memory.
Do not manually change device settings while scenarios run.

The runner establishes an eth0 DHCP baseline before each ordinary scenario.
It reuses the booted device. A scenario that needs a fresh disk declares
`boot_options/0`: disk-write failures and the boot-time receive stall do this.
Reset/crash scenarios reboot that same device as part of their assertions.
A failed scenario causes a fresh boot before continuing; failed fault cleanup or
a runner timeout blocks further runs until the session is restarted.

The page, CLI endpoints, runner and scenarios are compiled only for host dev/test.
They are absent from production and device firmware. The runner refuses to run
without its owned VM context; it never attaches to EC100 or an arbitrary VM.
CLI requests use the page's session and CSRF protection through a private Unix socket.

## One-time QEMU setup

Requires Linux user/network namespaces, `unshare`, `ip`, `nft`, `tc`, `socat`,
`curl`, QEMU and fwup. No sudo or workstation TAP setup is needed.
Supply a verified x86 `tailscaled` binary as described in the main README, then:

```sh
MIX_TARGET=x86_64 MIX_ENV=dev mix deps.get
MIX_TARGET=x86_64 MIX_ENV=dev mix nerves.artifact.build nerves_system_x86_64
```

The BSP is at [`systems/nerves_system_x86_64`](../systems/nerves_system_x86_64/GATEWAY.md).
An upstream stock artifact is not equivalent. A cold system build can take an hour.

Development and CI both run the same session inside an empty user/network namespace.
The device has eth0 (Internet), eth1 (equipment), and eth2 (management at
192.168.77.2). Management is never faulted. The controller uses 192.168.77.1 and
the public development cookie `mycookie`. Production retains its native cookie.

Phoenix listens on a private Unix socket. In development, a loopback-only socat
proxy exposes it at localhost:4000. This keeps all faultable network interfaces,
firewall rules, DNS probe fixtures and distribution inside the namespace, while
allowing the browser and CLI to reach the page. No workstation routes or firewall
rules are changed. This namespace deliberately has no public Internet access.

## Coverage and limits

Scenarios cover public status, invalid inputs, DHCP receive stalls, cable loss,
PCI NIC removal, VM freeze, configuration confirmation/cancellation/expiry,
concurrent confirmation, reboot/crash persistence, disk write errors, and upstream
probe outages, latency and loss. The source folder is the authoritative list.

Upstream fixtures accept actual TCP/53 probes to VintageNet's default target IPs
inside the namespace. They do not prove public Internet or Tailscale availability.
The receive-stall filter delays all WAN receive traffic, not just DHCP.
Disk faults return real EIO; removing the filter does not heal a read-only guest
filesystem, so these scenarios use disposable replacement disks. SIGKILL of QEMU
is not physical power loss: host disk caches remain intact.

Boot waits are bounded at 100 seconds, ordinary recovery at 30 seconds, and normal
Internet detection at up to 90 seconds. A scenario has a five-minute outer limit.
No guest observations or timers are mocked. Logs remain under
`_build/qemu-tests/<session>/`; normal shutdown deletes the disposable disk.

Buses, physical indicators/recovery, authenticated Tailscale traffic, full
forwarding/NAT isolation and browser workflows are not yet device-qualified.
QEMU does not reproduce Rockchip peripherals, flash behavior or EC100's boot chain.

## EC100 UI development

`mix dev.ec100` uses the node configured in `config/dev.exs`, derives the local
address from the route to that device, and runs Phoenix on loopback. Both ends
must use compatible OTP/Elixir and development firmware with cookie `mycookie`.
No QEMU scenarios run against it. Manual startup remains available:

```sh
MIX_TARGET=host NERVES_GATE_BACKEND_NODE='nerves_gate@<device-address>' mix compile --force
# Keep those environment variables set for the next command:
iex --name 'nerves_gate_ui@<workstation-address>' -S mix phx.server
```

Backend selection is compile-time. Device status remains authoritative; remote
LiveViews poll every five seconds and on node events. Commands are not replayed
on reconnection. Host HTTP access never implies trusted USB access to the device.
Use trusted networks: development distribution and the UI grant device access.

## CI

`.github/workflows/qemu.yml` is opt-in (`workflow_dispatch`) on a trusted Linux x64
runner labelled `nerves-gate-qemu`. It checks tools, verifies the pinned x86
Tailscale download, builds the system, runs `mix ci`, and uploads logs, never disks.
It does not run untrusted PR code. CI uses the same session, runner, scenario
modules and baseline as development; only boot/run/shutdown is automatic.
Remote runner registration and a GitHub execution still require operator setup.
