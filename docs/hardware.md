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

Protected console, USB-management and Internet resources are not assignment
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
for the actual managed calling process. It accepts no plugin name or arbitrary path and
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

`modbus_plugin` uses yamodbus for saved Modbus clients and servers over TCP or RTU.
Its page owns roles, unit IDs and register/coil mappings, not Hardware. Definitions
are saved through plugin configuration storage on SD. Startup and saving open no connection;
Start and Stop are explicit, and a running connection must be stopped before saving.
Mapped holding registers and coils become platform inputs and repeatable outputs.
See the [plugin README](../plugins/modbus/README.md).

RTU requires an enabled RS485 assignment, detected device, and confirmation that the
operator is authorized to use the bus. One running connection per serial port; assign
both ports to run a server and a client against each other. The EC100 uses automatic
direction control with configurable speed, parity and stop bits (8 data bits). No
DE/RTS modes are offered.

The plugin declares `circuits_uart` as a dependency, but the native 1.7.0 driver is
provided by target-built firmware and excluded from plugin archives. Packages remain
pure BEAM and pin the exact platform library version. No device library downloads.

Clients write only repeatable setters for a held desire and never write when no desire
exists. The library may reconnect an explicitly started transport; Stop or plugin stop
terminates it. Check wiring/termination and use only networks/buses you are authorized
to access.

## Validation limits

Modbus host tests cover validation, storage and admission without opening ports.
The QEMU `plugins` scenario runs the real platform and plugin over loopback TCP.
QEMU guests have no RS485 ports: RTU between the EC100 ports, electrical, direction
control, PLC and CAN qualification are separate, authorized physical activities. No
real bus traffic or device deployment is implied by implementation or firmware builds.
