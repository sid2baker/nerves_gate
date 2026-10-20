# Nerves Gate Simulator

Disposable QEMU gateways running real Nerves Gate firmware. There is no
in-memory hardware backend: the simulator requires Linux (x86_64 or aarch64),
QEMU 8.2+ with `user` and `stream` networking, `fwup`, `flock` and `mkfs.ext4`,
and reports what is missing.

```sh
mix nerves_gate.sim --firmware path/to/nerves_gate.fw   # serves http://localhost:4000
mix nerves_gate.sim.install [device]                    # in another terminal
```

The site starts no device until you press Start. Each device has its own disk
image, a prepared ext4 virtual SD card (`/dev/vdb`, mounted by firmware at
`/mnt/apps`), and private socket networks with an Internet router on LAN1 or
LAN2. Manual controls unplug cables, add uplink loss or latency, and pause the VM.
They never change workstation networking or attach to other virtual machines.

`mix nerves_gate.sim.install` packages the current Mix application with
`mix nerves_gate.package`, then installs and starts it through the device's own
`NervesGate.Apps`. Installation reserves its device through the same runner as
scenarios; release manual control first. Results appear on the device page.
Versioned upgrades retain health-checked rollback; reinstalling the same version
replaces the development copy. Both preserve the application's data directory.
Applications use the firmware's real SDK backend.

`mix qemu.status` and `mix qemu.stop` inspect and gracefully stop the session
(the repository's `mix dev.status` and `mix dev.stop`); `mix dev.ui <device>`
serves the gateway UI against a device.

Reset erases every device disk and SD card. Session files and logs live under
`_build/qemu-dev` (private: they may contain device state). Never delete its
`session.lock`. The QEMU system does not emulate EC100 CAN, RS485, LEDs or the
recovery button; those SDK calls report unavailable hardware.

## Repository development

From the repository root, `mix setup` prepares the x86_64 firmware inputs and
`mix dev` builds the local firmware when devices start. `mix dev.status`,
`mix dev.stop` and `mix dev.ui <device>` manage the session and serve the gateway
UI with code reload. `mix test.firmware --only <scenario> [--device <id>]` runs
firmware's integration scenarios (`firmware/test/scenarios`) on the running
session. Scenarios on different devices run concurrently; `devices: :all`
reserves every device.
