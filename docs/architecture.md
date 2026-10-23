# Architecture

Device domains own commands, admission, deadlines and persistence. The gateway UI
reads a device-owned projection and submits commands through
[`NervesGate`](../firmware/lib/nerves_gate.ex). EC100 and QEMU run the same
firmware; the workbench observes devices over Erlang distribution. Third-party OTP
applications run in the same BEAM and use only the SDK.

## Source map

| Path | Responsibility |
| --- | --- |
| `firmware/lib/nerves_gate.ex` | Public commands, status and subscriptions |
| `firmware/lib/nerves_gate/` | Device domains, adapters, projection, SDK backend, storage and apps |
| `firmware/lib/nerves_gate_web/` | Gateway endpoint, LiveViews and components |
| `firmware/config/` | Firmware profiles; `host.exs` is for checks and assets only |
| `firmware/test/unit/` | Host tests of pure firmware behaviour |
| `sdk/lib/nerves_gate_sdk/` | App API, structs, backend behaviour and package validation |
| `lib/dev/` | Workbench sessions, apps, discovery, builds, firmware updates, factory provisioning and release checks |
| `lib/dev_web/`, `config/`, `priv/dev/` | Workbench endpoint, LiveViews, CLI API and session launchers |
| `lib/simulator.ex`, `lib/simulator/` | QEMU lifecycle, virtual hardware and the shared scenario runner |
| `lib/dev/scenarios/`, `lib/dev/scenarios.ex` | Portable device/SDK assertions and requirement-aware execution |
| `lib/dev/test_device.ex`, `lib/dev/test_fixture.ex` | Bounded device access and explicit host-side bench controls |
| `lib/simulator/scenarios/` | QEMU-specific integration scenarios |
| `priv/simulator/` | Simulator node script and bench configurations |
| `priv/templates/` | SDK app scaffolding |
| `systems/` | EC100 and QEMU Nerves systems |

## Board configuration

Each device target declares hardware wiring in `:nerves_gate, :board`:
`firmware/config/ec100.exs` for EC100 and `x86_64.exs` for QEMU. The latter is not
an arbitrary-PC hardware profile. `NervesGate.Board` reads the modem profile,
bus/indicator/recovery adapters and storage paths for device domains. Host builds
have no board hardware; the UI continues to use device-owned status.

The Nerves system/BSP owns drivers, device trees, boot and Linux device naming.
Board config selects hardware; domains own policy, deadlines and persistence;
applications use the SDK. The current two-port network model is unchanged.
EM300 support, including its three-port layout, is future work.

## Data flow

```text
UI / IEx → NervesGate command → domain GenServer → bounded worker
         → NervesGate.status → domain reads → Status.build

Subsystem observations → ProjectionServer → sanitized domain replacements
LiveView → subscription + snapshot → Projection reducer → UI
Domain conditions → Alarmist → LEDs / subscribers
```

`NervesGate.status/1` reads domains directly; it is not an atomic snapshot.
Commands return their result without a status read. See the
[public API](action-api.md).

## Ownership and supervision

| Owner | Responsibility |
| --- | --- |
| VintageNet | Interfaces, saved network settings, connectivity, DNS and routes |
| Tailscale | Identity, preferences, enrollment and VPN routes |
| Network | Admission, trials, USB auto-save, SIM commissioning and PIN storage, deadlines and rollback |
| Remote | One bounded daemon worker and sanitized operation metadata |
| Equipment | Neighbors, scoped labels and scan observations |
| Indicators | LED/button policy, identification and recovery |
| Buses | One diagnostic worker; opt-in, bounded results |
| SSH | Public-key validation, persistence and authentication |
| Storage | SD-card commissioning, detection, mounting and formatting |
| Apps | Trusted OTP application admission, lifecycle and version selection |
| ProjectionServer | Shared sanitized UI read model |
| LiveView | Drafts, presentation, subscriptions and command submission |

`firmware/config/firmware.exs` lists the device services, started `rest_for_one`:
PubSub, routing setup, workflow PropertyTable, SSH, Network, Remote, Equipment,
Indicators, Buses, the app task supervisor, Storage, Apps, ProjectionServer,
SDKBackend and Endpoint. Dependencies supervise VintageNet, tailscaled and
Alarmist. `nerves_gate` is `transient`: an exhausted restart limit stops the BEAM
and erlinit reboots the device.

Workers are linked and bounded; owners stop and join them before restoration or
new work. Network trials, scans and sharing reply after completion; cellular
commissioning and Remote acknowledge acceptance and report completion in status.
A caller timeout means **unknown outcome**, not cancellation or permission to
replay. Cross-domain commands enter through the facade, and UI availability never
replaces backend checks.

## Persistence and recovery

Network applies saved settings before accepting proposals; unreadable settings
fail closed. Trials and deadlines live in RAM; confirmation saves each interface
through VintageNet. **Multi-interface saves are not transactional**: see
[saving and rollback](networking.md#saving-and-rollback). Tailscale owns its
identity and preferences, Equipment its labels and SSH its authorized keys.

Both firmware targets require writable ext4 data before starting data users.
Startup sets default-deny IPv4 forwarding before enabling forwarding. See
[reset safety](indicators.md#recovery).

## UI projection

[`ProjectionServer`](../firmware/lib/nerves_gate/projection_server.ex) coalesces
observations for 20 ms, reads dirty domains and broadcasts changed sanitized
inputs as `{:replace, domain, snapshot}`.
[`Projection`](../firmware/lib/nerves_gate/projection.ex) and
[`Status`](../firmware/lib/nerves_gate/status.ex) derive the same status on the
device and on clients.

Subscribing returns `{:ok, server_pid, projection}`. Clients monitor that server,
ignore replaced instances and resubscribe after loss; drafts stay separate.
Private login URLs and cookies never enter the stream. On the workstation the
backend is an explicit remote node, and disconnected clients show unavailable.

## Fault reporting

Domains publish fixed, sanitized conditions through SASL to Alarmist; named domain
instances scope their alarms. Restore/recovery failures are immediate errors;
availability faults warn after two continuous seconds and clear on observed
recovery. Unknown stays unknown. Alarms never admit commands or trigger remedies.
See [LED policy](indicators.md#leds).

## Applications and SDK

`NervesGate.SDKBackend` translates domain state into SDK structs and events; it
never exposes status maps or administrative commands. `NervesGate.Buses` owns
CAN/RS485 for both diagnostics and the SDK, so they cannot share a port.
`NervesGate.Apps` installs, starts, upgrades and rolls back `.ez` OTP archives
from the SD card. See [applications](applications.md).

## Host mode and the simulator

Devices serve the gateway UI; the workstation serves only the developer
workbench. Firmware's host build supplies shared components, read models and
checks, without starting device services or a gateway HTTP endpoint. Native
networking dependencies compile on the host for their types but never start there.

`Simulator` owns build, start, stop and reset; `Simulator.Device` owns each QEMU
process, disk, QMP socket and Ethernet relay; `Simulator.QemuTests` admits
lifecycle, configuration, manual control and scenario runs. The workbench, CLI
and CI share these modules and [the scenarios](development.md#scenarios).
Portable scenarios use `Dev.TestDevice` and declare device resources separately
from fixture controls. `Dev.Scenarios` checks requirements before the owner's
preparation callback. Unsupported hardware/control capabilities produce a skipped
row with a reason. Missing declared hardware, assertions, unavailable devices and
failed controls are failures, not skips. Link/enabled state does not determine
hardware support. The runner never boots or resets a target by itself. QEMU
admission, reservations, fault cleanup and failure disk replacement remain owned
by `Simulator.QemuTests`.

`Simulator.TestQemu` implements `Dev.TestFixture` for owned QEMU handles. Other
benches can supply the same small host-only control contract, but no physical
fixture or automatic physical-device runner is provided. Test controls are not
part of the application SDK. Scenarios may inspect private domains to verify
recovery; that is not a public API. Firmware's `.reach.exs` enforces API boundaries
and pure status/policy code.
