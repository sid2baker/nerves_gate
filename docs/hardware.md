# Hardware assignments and Modbus

Hardware offers independent non-Internet `eth0`/`eth1` LAN ports alongside
allowlisted EC100 `ttyS3`/`ttyS4` RS485 and `can0`/`can1` interfaces. Internet uplinks
are managed under Internet, not displayed as assignable hardware. It never opens traffic sockets, captures frames or issues Modbus reads.
There is no built-in capture/Modbus diagnostic API. Opening Hardware is read-only.

## Exclusive assignment

On a port's Hardware page, choose operator enablement and a compatible plugin, then
review and confirm. One port has zero or one assigned plugin; a plugin can own several
ports. Assignment is persistent intent, not proof of an open handle or device readiness.
Only plugins declaring the corresponding `:ethernet`, `:serial` or `:can` kind in
`nerves_gate_hardware` appear. Unassigned or missing resources are valid observable states.

Changing ownership/permission stops BOTH affected plugins, including all their other
ports and TCP connections, through the checked lifecycle path. A review is bound to
the observed old assignment; stale reviews are rejected. Cleanup must succeed before
the assignment is committed. Plugins remain stopped; starting and connecting are
explicit separate operations. Busy/unknown cleanup or persistence outcomes block
reuse. No forced takeover, automatic restart or command replay.

Protected console, USB-management and Internet resources are not bus assignment
candidates. Unsupported or absent ports cannot be assigned/enabled. A missing port's
saved assignment remains visible; an operator may disable/unassign it without
opening it. Missing plugin intent is retained, never silently reassigned.

Administrative API:

```elixir
NervesGate.Plugins.hardware()
# Explicitly authorize stopping both affected plugins; all their connections stop.
NervesGate.Plugins.assign_port("ttyS3", true, "modbus_plugin", true)
NervesGate.Plugins.assign_port("ttyS4", true, "modbus_plugin", true)
```

The manager serializes assignments with plugin lifecycle, keeps bounded current-only
state at `/data/nerves_gate/hardware.term`, and rejects malformed state intact.
Firmware artifact selection remains separate. No automatic migration/reset of saved
intent is performed.

## Plugin-owned transport

`NervesGateSDK.Hardware.resources/0` returns typed assigned/enabled allowlisted ports
for the actual managed calling process. It accepts no app name or arbitrary path and
opens no handles. Presence and assignment do not imply connected equipment. Plugins
supervise their own libraries and transport workers, not SDK claim/byte-I/O proxies.
The former CAN/RS485 SDK transport APIs are removed without compatibility shims.

Libraries must close their handles on OTP shutdown. The manager also checks that
observed native BEAM ports owned by the activation have closed before accepting
cleanup. Unmanaged/detached transport processes are not supported. Trusted same-BEAM
code can bypass conventions; this is coordination, not a security sandbox.

Ordinary Modbus TCP/S7 clients use sockets without claiming/reconfiguring Ethernet.
Ethernet addressing requires both an enabled exclusive hardware assignment and an
actual-PID network lease. The subnet-router declares `nerves_gate_hardware: [:ethernet]`.
Its supervised owner claims only its assigned LAN; a UI process or another plugin
cannot borrow that permission. The platform still owns addressing, routes and durable
cleanup. Assignment reserves network admission while affected plugins are stopped
and drained. An assigned LAN must be disabled and unassigned before becoming Internet;
a pending network trial prevents assignment. No assignment starts traffic or sharing.

## Modbus TCP and RTU

`modbus_plugin` 0.2.0 uses yamodbus for read-only holding/input register polling over
TCP or RTU. Its page owns unit/register configuration, not Hardware. Startup and
saving configuration open no connection. Connect/poll and disconnect are explicit.

RTU requires an enabled RS485 assignment, detected device, and confirmation that the
operator is authorized and no other master is active. One connection per serial
port is allowed; assign both ports to supervise independent connections concurrently.
The initial EC100 profile is automatic direction, **9600 baud, 8 data bits, no parity,
1 stop bit**. No unqualified speed/parity/DE/RTS modes are offered.

The plugin declares `circuits_uart` as a dependency, but the native 1.7.0 driver is
provided by target-built firmware and excluded from plugin archives. Packages remain
pure BEAM and pin the exact platform library version. No device library downloads.

TCP and RTU reads use FC3/FC4, units 1–247, zero-based addresses and bounded counts,
timeouts and polling. No register writes, broadcasts, scans or ASCII transport are
exposed. The library may reconnect an explicitly started transport; subsequent
polls are reads only. Disconnect/plugin stop terminates clients. Restart clears
configuration and never connects automatically. Check wiring/termination and use
only networks/buses you are authorized to access.

## Validation limits

Host tests use the real yamodbus/circuits_uart implementation against disposable
loopback TCP and supervised `socat` pseudo-terminals, including RTU CRCs, exceptions,
timeouts and close/reopen. Tests never attach to physical ports. Host tests require
`socat`; failure to provide it fails the RTU suite rather than silently skipping it.
PTY tests are protocol/cleanup evidence, not electrical, RS485 direction-control,
PLC or CAN qualification. QEMU runtime and physical qualification are separate,
authorized activities. No real bus traffic or device deployment is implied by
implementation or firmware builds.
