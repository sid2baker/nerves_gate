# QEMU management network

The simulator is virtual hardware. Guest firmware owns the real management IP,
EPMD and distribution listener, just as on EC100. Workbench connects normally:

```text
Pi → hidden Workbench
          ├─ physical gateway IP → EPMD → distribution
          └─ private bridge → TAP → QEMU eth2 IP → EPMD → distribution
```

## Explicit preparation

Choose a free private IPv4 /24 that does not overlap host/VPN routes. Authorize
privileged network operations, then, while this checkout's Workbench is stopped:

```sh
sudo -v
mix dev.network setup --subnet 10.203.42.0/24
# For a different trusted bench, also supply --config path/to/config.exs.
mix dev
```

The address above is an example, not a subnet to impose without checking. Setup
rejects overlapping routes and existing interface names. It uses `sudo -n ip`
and a bridge-scoped `sudo -n sysctl`, never an interactive sudo prompt. The host
requires iproute2 (Fedora: iproute). QEMU itself stays unprivileged.

Setup creates one bridge and one persistent user-owned TAP per configured device,
with unique names and management MACs. The host bridge is `.1`, sorted devices
use `.2` onward. Firmware receives its static management IP through the virtual
disk serial (`qemu-<IPv4>`), avoiding a DHCP service or custom discovery protocol.
Firmware reads the full kernel hostname (Erlang's short-hostname lookup truncates
at a dot). USB recovery explicitly uses the same full serial for its standard
VintageNetDirect subnet calculation. The firmware's normal network configuration
supplies no management default route.

Only the newly created bridge has IPv4 forwarding disabled. There is no physical
uplink, NAT, workstation-wide forwarding toggle, firewall rewrite, DNS change,
VPN change or Tailnet subnet advertisement. Existing shared EPMD is untouched.
Other developers' machines cannot automatically reach these private guests.

The configuration and exact interface indices are recorded privately in
`_build/workbench/network.term`, including partial setup. Normal startup does not
create interfaces or invoke sudo. It verifies prepared interface identities before
QEMU starts. With no prepared network, Workbench can still inspect physical
gateways, but cannot boot QEMU devices.

The network is checkout-owned and reusable across sessions. After a host reboot,
Linux removes the bridge/TAPs but the ownership record survives. With Workbench
stopped, rerun the same explicit setup command:

```sh
sudo -v
mix dev.network setup --subnet 10.203.42.0/24
mix dev
```

Setup recreates the recorded interface names, addresses and MACs only when **all**
recorded bridge/TAP names are absent and the subnet, device set and user match.
It rechecks current host/VPN routes, clears obsolete kernel indices only after
preflight, and journals each newly created interface. No preliminary cleanup is
needed for this all-absent case. Normal `mix dev` startup still never repairs networking.

Any surviving or conflicting interface, incomplete setup record, changed owner or
changed configuration is refused. Inspect it and use explicit cleanup; do not delete
the journal to bypass ownership checks. To change the device set or subnet, stop the
session, explicitly clean up, then prepare again.

## What remains isolated

Only protected `eth2` management uses TAP. Existing Unix-socket Ethernet LANs,
libslirp Internet and injected LAN faults remain owned by the simulator. USB
recovery retains its distinct loopback SSH forward and guest USB network; it is
not ordinary gateway discovery. HTTP and regular SSH use the guest IP directly.

The directory includes verified physical and simulated gateways. Simulator ownership
is recorded only for this session's running guests. Reachability or knowing a node
name never grants QMP, disk or network-fault control. Multiple
checkouts on one workstation need distinct prepared subnets; their interface names
and ownership records are independent.

## Cleanup and failure handling

Stop the Workbench normally before removing its prepared network:

```sh
mix dev.stop
sudo -v
mix dev.network cleanup
```

Cleanup verifies recorded interface indices, refuses a bridge with unowned members,
then deletes only its TAPs and bridge. It does not stop a shared EPMD, flush routes,
kill processes by name or modify other interfaces. QEMU shutdown still belongs to
its supervised owner. Network cleanup is explicit, not an implicit startup action.

Partial setup is journaled. Inspect and run explicit cleanup before retrying. A
mismatched interface identity requires operator inspection; do not delete an
interface merely because its name starts with `ngb` or `ngt`.

## Qualification boundary

Pure planning/ownership tests, QEMU argument tests, hidden BEAM connectivity and
Pi attachment can run without privileged setup. Real bridge/TAP startup, two
simultaneous prepared environments, guest boot/recovery and physical/VPN isolation
must be qualified on explicitly authorized owned environments. Host tests and
firmware builds do not establish those runtime properties.
