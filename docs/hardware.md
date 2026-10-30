# Hardware assignments and Modbus

Hardware offers independent non-Internet `eth0`/`eth1` LAN ports alongside
allowlisted EC100 `ttyS3`/`ttyS4` RS485 and `can0`/`can1` interfaces. Internet uplinks
are managed under Internet, not displayed as assignable hardware. It never opens traffic sockets, captures frames or issues Modbus reads.
There is no built-in capture/Modbus diagnostic API. Opening Hardware is read-only.

## Exclusive assignment

Start setup from the plugin. In Modbus, save a stopped RTU definition, then use
**Assign port / enable access** beside it. In Tailnet, review LAN assignment before
entering volatile address settings. Both navigate to a gateway-owned review page
that survives plugin UI shutdown. Return to the plugin for explicit connection
Start or address/sharing commands; no resource is opened by saving a definition.

Hardware is the cross-plugin overview. Assigning a compatible plugin grants access;
there is no separate enablement prerequisite in ordinary setup. **Release** removes
ownership. Advanced **Disable access** retains ownership for maintenance, and
**Enable access** explicitly restores permission. Saved disabled intent is preserved.
One port has zero or one assigned plugin; a plugin can own several ports. Assignment
is persistent intent, not proof of an open handle or equipment readiness. Only plugins
declaring the corresponding hardware kind appear.

Changing ownership/permission stops BOTH affected plugins, including all their other
ports and TCP connections, through checked cleanup. The review binds current ownership,
permission, artifact/lifecycle state and LAN configuration. Stale reviews fail before
effects; Network rechecks LAN state inside reservation admission. Unchanged ownership
and permission do not stop a plugin unnecessarily.

Plugins remain stopped unless **Start the target plugin after assignment** was
explicitly reviewed (default off). Only the target may start; the previous owner is
never restarted. Plugin startup can have plugin-defined effects; first-party Modbus
and Tailnet startup start no connections or sharing. Assignment saved but plugin
start failed is reported as partial completion, never rolled back or replayed.
Busy/unknown cleanup or persistence blocks reuse. No forced takeover or automatic retry.

Protected console, USB-management and Internet resources are not assignment
candidates. Unsupported or absent ports cannot be assigned/enabled. A missing port's
saved assignment remains visible; an operator may disable/unassign it without
opening it. Missing plugin intent is retained, never silently reassigned.

Administrative API:

```elixir
NervesGate.Plugins.hardware()
# Explicitly authorize stopping both affected plugins; all their connections stop.
{:ok, review} = NervesGate.Plugins.review_assignment("ttyS3", true, "modbus_plugin", false)
# Show the whole-plugin stop scope, then confirm this exact review.
:ok = NervesGate.Plugins.confirm_assignment(review)
```

The manager serializes assignments with plugin lifecycle, keeps bounded current-only
state at `/data/nerves_gate/hardware.term`, and rejects malformed state intact.
Firmware artifact selection remains separate. No automatic migration/reset of saved
intent is performed.

## Plugin-owned transport

`NervesGateSDK.Hardware.candidates/0` provides typed, read-only presence, assignment
and permission for setup. It grants no resource access and does not replace Network
admission. `NervesGateSDK.Hardware.resources/0` returns typed assigned/enabled allowlisted ports
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
