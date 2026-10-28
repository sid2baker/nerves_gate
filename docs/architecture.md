# Architecture

Nerves Gate has three core projects (root, firmware and SDK), firmware-selected
plugin projects and two Nerves system projects, not an umbrella. Device domains hide commands, admission, deadlines and persistence behind
named APIs. EC100 and owned QEMU devices run the same application with different
board profiles and target binaries. The workstation runs the workbench and owns
disposable QEMU hardware; it does not run device services.

## Projects and dependencies

| Project | OTP application | Build/runtime role | Version |
| --- | --- | --- | --- |
| Root | `:nerves_gate_workbench` | Host tooling, workbench and simulator | Root `VERSION` |
| `firmware/` | `:nerves_gate` | Host-compiled helpers/checks; EC100 or QEMU runtime | Root `VERSION` |
| `sdk/` | `:nerves_gate_sdk` | Typed plugin contract and packaging; no application supervisor | `sdk/VERSION` |
| `plugins/tailnet_subrouter/` | `:tailnet_subrouter` | Selected, disabled-on-first-boot subnet plugin | Plugin `mix.exs` |
| `plugins/modbus/` | `:modbus_plugin` | Selected Modbus TCP/RTU client/server plugin with yamodbus | Plugin `mix.exs` |
| `systems/nerves_system_ec100/` | `:nerves_system_ec100` | ARM Linux, toolchain, boot and board support | System `VERSION` |
| `systems/nerves_system_ec100_qemu/` | `:nerves_system_ec100_qemu` | x86_64/musl Linux, toolchain and QEMU support | System `VERSION` |

```text
root (always host) ──path──→ sdk
                  └─path──→ firmware (host, runtime: false) ──path──→ sdk

firmware (ec100/x86_64) ──→ selected system source + fingerprinted artifact
```

SDK calls use the fixed `NervesGate.SDKBackend.call/2` firmware entry point on both
EC100 and QEMU. The SDK invokes it in the actual caller's process without a Mix
dependency on firmware or configurable backend selection. Missing firmware reports
`:runtime_unavailable`; loaded firmware with unavailable services reports
`:unavailable`. UI plugins declare their shared Phoenix/LiveView dependencies directly;
the core SDK has no web dependencies.

Each project keeps its own Mix configuration, lockfile and build directory.
Shared root/firmware dependencies must have matching locks. Device dependencies
normally select immutable system Git tags; internal local builds use the checkout's
system sources. Only the SDK is published on Hex; see [releases](releases.md).

`runtime: false` prevents automatic firmware application startup, **not compilation
or host code reuse**. The workbench shares firmware components/layouts, projection
subscriptions and status derivation.
It never starts the firmware application to obtain them. Another shared project or
an umbrella would not remove target/toolchain or release isolation; extract a
library only when a measured benefit justifies another owner and package.

## Source map

| Path | Responsibility |
| --- | --- |
| `firmware/lib/nerves_gate.ex` | Direct `status/0`, caller-owned `subscribe/0`, domain API index |
| `firmware/lib/nerves_gate/` | Device domains, policies, implementations, projection and SDK backend |
| `firmware/lib/nerves_gate/cellular/` | Board profile, SIM/PIN lifecycle, private PAP storage and modem/UART implementation |
| `firmware/lib/nerves_gate_web/` | Local gateway UI and shared read-only presentation |
| `firmware/config/` | Board profiles, device services and host-only checks/assets |
| `sdk/lib/nerves_gate_sdk/` | Typed plugin API, fixed firmware bridge contract and archive validation |
| `lib/workbench/` | Sessions, gateway directory, plugin projects, builds, updates, provisioning and release checks |
| `lib/workbench_web/`, `config/`, `priv/workbench/` | Workbench browser UI, host config and session script |
| `lib/simulator.ex`, `lib/simulator/` | Locally supervised owned QEMU lifecycle and virtual hardware |
| `lib/scenarios.ex`, `lib/scenarios/` | One catalogue, reservations/runner, bounded device access, owned QEMU fixture and cases |
| `priv/simulator/`, `priv/templates/` | Trusted bench configs/scripts and ordinary SDK plugin scaffolding |
| `test/`, `firmware/test/{unit,web}/`, `sdk/test/` | Host tooling/shared UI integration, firmware policy/web checks and SDK tests |
| `plugins/` | Firmware selection and independently tested first-party plugin projects |
| `systems/` | Independently versioned Nerves system artifact inputs |

## Host mode and the simulator

### Session processes

[`Workbench.Launcher`](../lib/workbench/launcher.ex) owns the launch chain under
`flock` and MuonTrap. The lock lasts through child cleanup; never unlink it to
bypass ownership. The workbench session is a uniquely named hidden node with an
inbound listener for local Pi attachment. It supervises the simulator locally.

```text
Workbench.Supervisor (:nerves_gate_workbench, one_for_one)
├─ Workbench.Tasks
└─ Workbench.Plugins

session supervisor
├─ Simulator → per-device owners → QEMU, disks, QMP and Ethernet relays
└─ Workbench.SessionServices (rest_for_one)
   ├─ NervesGate.PubSub
   ├─ Workbench.Gateways (verified directory)
   ├─ Scenarios.Runner (lifecycle and reservations)
   ├─ Workbench.Jobs (serialized long jobs and reviews)
   └─ WorkbenchWeb.Endpoint
```

[`priv/workbench/session.exs`](../priv/workbench/session.exs) explicitly starts
`:nerves_gate_workbench` and attaches
[`Workbench.SessionServices`](../lib/workbench/session_services.ex) to its session
supervisor. Ordinary host tasks start none of these session services. Root config
leaves `:nerves_gate, :services` empty and the firmware application stays stopped.
The shared bus name is deliberately `NervesGate.PubSub`; its host owner is the
session. Shutdown stops the endpoint, jobs, runner, directory and PubSub before the
simulator. It does not stop the workstation's shared EPMD or delete prepared network
resources. The loopback endpoint serves only the browser; CLI control uses distribution.

There is no host gateway endpoint, VintageNet service or Tailscale daemon. Native
networking dependencies compile for helpers, not workstation service startup.
The session sets its own distribution cookie; firmware cookie initialization and
cellular credential filtering do not run on the workstation. Phoenix reload
plugs and asset watching are host-owned.

The session node is `workbench_<checkout-id>@127.0.0.1`, explicitly hidden with
`mycookie` and a local inbound distribution listener. `Workbench.Gateways` connects
known dev gateways through ordinary EPMD. Pi-elixir attaches directly to this node;
inspection uses its verified directory rather than another connection process.
The node name hashes the checkout path and machine ID, remaining stable across
session restarts while distinct checkouts/workstations coexist; session tokens
still distinguish individual runs. Interactive session state is `_build/workbench/`; explicitly requested
CI sessions use `_build/workbench-ci-<run>/`. Simulator diagnostics/disks are under
`_build/simulator/<session>/`. Internal session inputs use `WORKBENCH_*`; actual
simulator configuration is selected by `QEMU_SIM_CONFIG`.

CLI and Pi verify a Session handshake against locked metadata: canonical checkout
root, session ID, protocol revision and compatibility inputs. The explicit manifest
in `Workbench.Session` covers the session/admission wire contracts and SDK bridge,
not arbitrary source freshness. Jobs/Runner recheck the expected identity and
compatibility at write admission. Changed protocol inputs or loaded SDK/platform
versions block mutation until coordinated session replacement; inspection remains
available. There is no fallback attachment or automatic restart.

Starting the session boots no devices. An explicit Start builds selected local
firmware if needed and starts configured disposable devices from this checkout.
Host tools and guest firmware must be updated together; a source change does not
authorize stopping an old session, resetting disks or erasing saved settings.

### Admission and hardware ownership

`Workbench.Jobs` serializes builds, plugin commands, reviewed firmware/plugin
installation, factory provisioning and operator-assisted physical scenarios. Private
reviews carry their owner and immutable snapshot; public metadata never does.
`Scenarios.Runner` owns lifecycle, manual control and per-device reservations for
UI, CLI and CI. Jobs reserve lifecycle/shutdown admission with Runner until their
worker exits. QEMU plugin installation reserves its target before packaging.
UI availability is not admission. Standalone firmware/assets/plugin build workflows
use cross-process build-output exclusion without requiring a session.

Jobs and Runner each own session-qualified IDs and bounded in-memory observations;
there is no shared operations service. Accepted work is distinct from successful
completion. Maintenance errors with unproven effects and interrupted controls expose
an `uncertain` outcome and block further maintenance/control. Client wait timeouts
never cancel workers or release reservations. History is lost with its owner/session,
which is not evidence that an uncertain write is safe to repeat. Mix commands and
LiveViews invoke these same owners; [development](development.md#commands) is the
canonical operational command map.

Independent devices can run concurrently. `devices: :all` reserves the whole
bench, including exclusion of manual actions. Reservations last until worker exit,
not merely until it reports a result. Known-safe owner loss releases resources;
uncertain RPC/control outcomes block further writes and cleanup until recovery.
There is no blind command replay or automatic disk replacement in that state.

[`Simulator.Device`](../lib/simulator/device.ex) owns its QEMU process, disks,
QMP connection and network supervisor. Scenario/UI workers receive controlled
handles, not ownership. QMP operations verify the supervised process relationship.
Discovery, node names and reachable IPs never grant hardware-control authority.

Virtual LANs are real Ethernet over private Unix sockets with libslirp Internet
access. A separate, explicitly prepared bridge/TAP management path bypasses injected
LAN faults. It has no physical uplink, NAT, global forwarding or VPN changes. The
checkout-owned network persists until explicit cleanup; QEMU stays unprivileged.
Guest firmware owns EPMD at its actual management IP, without management port forwards. QEMU has separate system and plugin-SD
disks. Stop preserves them; Reset erases them and invalidates the prepared build.
Fresh-disk scenarios use the runner's explicitly owned disposable-state lifecycle.
See [development](development.md#workbench-and-simulator).

## Platform and plugin boundary

Nerves Gate is an industrial gateway extended by trusted pure-BEAM plugins.
`plugins/selection.exs` explicitly selects projects for firmware assembly. Their
private dependency closures and verified inventory live in firmware `priv/plugins`,
not a device store. Bundled code starts without SD; plugins using SD data directories
must handle unavailable storage. Adding/updating/removing code requires firmware.
There is one namespace per BEAM; incompatible plugin selections fail the build.
The standard UI exposes Hardware: gateway interfaces,
health, availability, shared configuration and access ownership. Plugins own
equipment identities, Modbus/S7 endpoints, register maps, polling and control.
Shared libraries do not imply device-owned protocol sessions or a universal driver
framework. An exclusive Hardware assignment lets one plugin use a free LAN without
IP configuration; that plugin requests isolated addressing using caller-owned SDK leases. Network
journals route ownership before writes and withdraws owned advertisements before
removing temporary addresses. Unknown cleanup blocks reuse, including after owner
or Network restart. No enable intent is restored automatically. The optional
`plugins/tailnet_subrouter` project demonstrates this boundary and starts disabled.
Network owns addresses/routes/bridges. Hardware inventories allowlisted physical
ports without opening handles or capturing traffic. Plugins owns persistent exclusive
assignments and checked stop-before-reassignment. Plugins supervise ordinary
transport libraries and per-port workers; Hardware shows assigned plugin identity,
not protocol controls. A plugin may own multiple ports.

Overview keeps Internet and Remote access together as operational entry points.
Remote access groups Tailscale enrollment and advanced Erlang distribution without
combining their credentials. Plugin storage administration belongs to Settings.

## Board configuration

Each device target declares wiring in `:nerves_gate, :board`:
`firmware/config/ec100.exs` for EC100 and `x86_64.exs` for owned QEMU, not arbitrary
PCs. `NervesGate.Board` supplies modem, bus, indicator, recovery and storage
configuration. QEMU leaves unsupported EC100 peripherals unavailable rather than
providing fake plugin backends.

The BSP owns drivers, device trees, boot and Linux device naming. Board config
selects actual hardware; domains own policy. The network model currently has two
LAN ports. EM300 and a three-port layout are not implemented.

Fixed infrastructure is called directly: `Network.Vintage` and `Remote.Tailscaled`.
Board-selected buses, indicators and recovery remain real
variation points, as does the published SDK backend contract.

## Device ownership and supervision

| Owner | Responsibility |
| --- | --- |
| VintageNet | Interfaces, saved network settings, connectivity, DNS and routes |
| Tailscale | Identity, preferences, enrollment and VPN routes |
| Network | Single admission/worker for trials, cellular and plugin leases; USB auto-save/rollback |
| Network.Local | Lease transitions, overlap/readiness policy, route journal and owned cleanup |
| Cellular | Named SIM/PIN/PAP operations and eligibility; uses Network's worker, no separate GenServer |
| Remote | Serialized bounded daemon operations and sanitized metadata |
| Indicators | LED/button policy, identification and recovery |
| Hardware | Allowlisted Ethernet/serial/CAN inventory; Plugins owns exclusive assignment intent |
| SSH | Public-key validation, persistence and authentication |
| Storage | SD detection, commissioning, mounting and formatting |
| IO | Persisted I/O definitions, live plugin bindings, latest input snapshots, coalesced hints and process-owned desired outputs |
| Plugins | Trusted plugin admission, lifecycle, version selection and exclusive hardware assignment; guards destructive storage changes |
| ProjectionServer | Sanitized UI read model, not command coordination |
| SDKBackend | Translation into the separate typed plugin contract |
| LiveView | Drafts, presentation, subscriptions and command submission |

Before networking/data users, `nerves_runtime` verifies writable data, validates
saved cellular driver configuration and installs cellular INPUT protection.
Incompatible saved driver atoms fail startup visibly before UART ownership;
there is no driver alias, silent migration or automatic settings erasure. Physical
reprovisioning/reset requires a separately authorized procedure. See
[cellular](networking.md#cellular-modem).

Dependencies supervise VintageNet, tailscaled and Alarmist. The device's
`rest_for_one` application children are ordered as follows:

```text
PubSub → Network.Vintage → workflow PropertyTable → persistent Settings PropertyTable
       → SSH → Network → Remote → Indicators → Hardware → PluginTasks
       → Storage → IO → Plugins → ProjectionServer → SDKBackend → gateway Endpoint
```

See [`firmware/config/firmware.exs`](../firmware/config/firmware.exs) and
[`NervesGate.Application`](../firmware/lib/nerves_gate/application.ex). An earlier
child's failure restarts later children. The application is `transient`: exhausting
its restart limit stops the BEAM and erlinit reboots the device. This is not the
host session's supervision tree.

Workers are linked and bounded; owners stop/join workers before restoration or new
work. Trials and plugin lease commands reply after completion. Cellular, Remote and
storage operations acknowledge acceptance and publish completion. A caller timeout
does not cancel admitted work or permit replay. Safe errors originate where their
meaning is known; `Error` only defines the safe shape and `GenServer.call` failure
boundary. Missing owners are unavailable; lost acknowledgments mean unknown
outcome. SDK typed errors remain a separate contract.

## Data flow

```text
gateway LiveView / IEx → named domain command → admission → bounded implementation
NervesGate.status     → independent domain reads → pure Status.build

subsystem observations → ProjectionServer → sanitized replacements → LiveView
trusted plugin → NervesGateSDK → SDKBackend → typed values, events and assigned hardware
Mix task / Pi → distribution → Workbench.Jobs / Scenarios.Runner / Workbench.Gateways
```

`NervesGate` has only `status/0` and `subscribe/0`, plus its domain API index.
Status is non-atomic and does not query a projection cache. Commands return their
result without an implicit follow-up status read. See the [API](action-api.md).

### Observable inputs and desired outputs

`NervesGate.IO` owns one controller for plugin-scoped definitions, live bindings,
latest input observations, subscriptions, exclusive writer ownership and desired
values. **Inputs describe what we observe; outputs describe what we want.** Only
repeatable state-setting operations qualify as outputs. There are no commands,
reliable event occurrences, write journals or physical completion states.

Definitions persist; all other I/O state is runtime-only. Restart, binding loss and
writer loss never establish a replacement target or cause a device operation.
Writers must claim an available output and explicitly set desire. Releasing clears
it, not the device's physical state. Feedback is an ordinary input, optionally linked
by an output definition. Availability, observation quality and freshness are distinct.
UTC timestamps remain nil until clock synchronization; freshness is monotonic.

Input subscribers and bound output handlers receive one outstanding dirty hint per
endpoint. Updates coalesce until that recipient reads the snapshot; reads by other
PIDs do not consume its dirty flag. A final change still causes a hint without any
later publication. The read atomically returns current state and clears the flag.
Consumers subscribe before reading and monitor the controller to resubscribe after
loss. Short-lived transitions may be missed; this is not an event-delivery protocol.

Plugins own device reconciliation, readback, retry policy and shutdown. I/O performs
no protocol writes and cannot guarantee safety. Managed-generation checks and PID
monitors fence endpoints; a periodic sweep also detects revoked/quiescing generations
without requiring a new publication. I/O precedes Plugins in the supervision tree,
so a controller restart also invalidates managed activation bindings.

`NervesGateSDK.IO` calls run in the actual managed caller. The Modbus plugin registers
mapped registers/coils from its runtime processes. I/O projections/UI and Automation
are not implemented.
See [I/O domain API](action-api.md#io-state-and-desire).

### UI projection

[`ProjectionServer`](../firmware/lib/nerves_gate/projection_server.ex) coalesces
changes for 20 ms, reads dirty domains and emits changed sanitized inputs as
`{:replace, domain, snapshot}`. Notifications are invalidation hints, not a command
log. Subscription registers the caller before returning
`{:ok, server_pid, projection}`; later operations come from that owner.

Pure [`Projection`](../firmware/lib/nerves_gate/projection.ex) and
[`Status`](../firmware/lib/nerves_gate/status.ex) derive administrative schema v11:
`device` availability, `remote` observations and domain-qualified action keys such
as `indicators.identify`; physical inventory is under `hardware`.
[`Observations`](../firmware/lib/nerves_gate_web/observations.ex) is an explicit
read-only client: local source for gateway views, `{ProjectionServer, node}` for
`WorkbenchWeb.GatewayLive` for both simulated and physical gateways. It monitors owners, ignores replaced instances, clears
availability on loss and resubscribes with a fresh snapshot. Drafts stay separate.

Gateway commands always run locally. Private enrollment URLs and cookies are
explicit reads cached only in the requesting gateway view, never projections or
notifications. Workbench gateway pages consume the same read-only projection
stream; hardware ownership remains separate from connectivity.

### Plugins and SDK

Plugins are trusted same-BEAM OTP code, **not a sandbox**. The SDK exposes typed
observations/events, caller-derived hardware assignments and narrowly scoped local-network leases,
not administrative maps, arbitrary network configuration, SSH, firmware or recovery
commands. Equipment identities, labels, scans and industrial protocols belong to
plugins.
Plugins and Network receive SDK calls from the actual caller. Stateful calls require
managed activation membership, resolved through OTP and Plugins-owned protected ETS,
not a caller-supplied plugin name or synchronous Plugins call. PID/ref ownership remains;
private generations fence revoked activations and in-flight work. No Task becomes
owner on a caller's behalf. Read-only SDK queries remain available outside plugins.

Host packaging/device installation share SDK `.ez` validation. Private OTP
dependencies can be bundled, platform dependencies cannot. New and obsolete
platform application/module names remain reserved. Packaging is not cross-compilation,
a dependency solver or hot-code upgrade. Installation does not start a plugin.
`Plugins.Artifact` verifies immutable archive/content identity. `Plugins.Loader` owns
verified module loading and one checked unload path; Plugins owns admission,
generation bindings and synced selection while linked workers perform effects.
Upgrades stop/start cold, run bounded health checks and restore the verified prior
artifact with a fresh generation on failure. Uncertain cleanup blocks reactivation. Ordinary plugin callbacks still execute in the shared runtime. See
[plugins](plugins.md).

### Plugin pages

`/plugins` and `/plugins/:app` are fixed gateway routes. Plugins may declare an optional
verified LiveComponent with `:nerves_gate_ui`; it renders inside the gateway shell
without router recompilation or its own web server. Components call their plugin's
supervised command process, never borrow SDK ownership from the gateway LiveView.
`Plugins.UI` tracks local page PIDs with OTP process groups. Admission is bound to a
running activation; checked unload closes those processes before removing code.
A controller restart closes surviving sessions before restoration. Shared Phoenix
libraries are excluded from plugin archives and exact dependency versions are checked.
See [optional plugin UI](plugins.md#optional-ui).

## Persistence and recovery

| Owner/store | Durable state |
| --- | --- |
| VintageNet | Confirmed interface settings |
| Tailscale | Device identity and preferences |
| Settings PropertyTable | Small private settings, including SIM-bound PIN and APN-bound PAP |
| SSH | Authorized public keys |
| Network.Local: `/data/nerves_gate/local_network.json` | Temporary link/route ownership and incomplete cleanup; never enable intent |
| Plugins: `/data/nerves_gate/plugins.term` | Schema 2 artifact SHA/source/name/module catalog, selection, enabled intent and committed sequence |
| Firmware `priv/plugins` | Build-generated inventory and read-only plugin artifacts |
| Plugins: `/data/nerves_gate/hardware.term` | Bounded exclusive port assignment and enablement intent |
| IO: `/data/nerves_gate/io.term` | Schema 1 input/output definitions only; no desired values, observations or ownership |
| Plugin SD: `/mnt/plugins` | Development plugin archives and plugin data |

Both targets require writable ext4 data before data users start. Unreadable saved
network settings fail closed. Trials and monotonic deadlines live in RAM;
confirmation saves through VintageNet. **Multi-interface saves are not
transactional**; see [rollback](networking.md#saving-and-rollback). Startup installs
default-deny IPv4 forwarding before enabling forwarding.

Card insertion never formats media. Storage commissioning is explicit and Plugins
guards destructive changes. Uninstall preserves plugin data; plugin rollback
does not roll that data back. See [storage](plugins.md) and
[reset safety](indicators.md#recovery).

Domains publish fixed sanitized conditions through SASL to Alarmist. Restore and
recovery failures are immediate errors; availability faults warn after two
continuous seconds and clear on observed recovery. Unknown stays unknown. Alarms
never admit commands or trigger remedies; see [LED policy](indicators.md#leds).

## Build, test and release boundaries

Root host checks enter SDK/firmware through `Mix.Project.in_project/4`, restoring
Mix env/target, project, code path, compiler options, environment variables and
firmware app config, and stopping a newly started subsystem app. This is **not
whole-VM isolation**: loaded modules and other app state can survive.
`Workbench.configure/0` merges root config rather than deleting unrelated settings.
Residual endpoint config is not proof of a running listener. Root checks reload
config and compile last; see [`mix.exs`](../mix.exs).

`mix setup` prepares locked dependencies, checksum-pinned QEMU tailscaled, Nerves
artifacts and host tools. It does not build firmware or boot devices. Limited
native target entries fetch dependencies/initialize Nerves, never compile target
application code in the host VM.

Device and external plugin builds use isolated supervised OS processes.
[`Workbench.Builds`](../lib/workbench/builds.ex) builds shared Volt assets on the
host **before** target packaging. Both UIs share one definition and tracked output;
devices only serve it. Host/target native ports must not mix. See
[development](development.md#assets) and [CI](ci.md).

Firmware host tests own policies/codecs and gateway rendering/security; root tests
own tooling/shared UI integration; SDK tests own its contract/packaging. Real I/O
and recovery use the single explicit catalogue in `Scenarios`, with all cases in
`lib/scenarios/cases/`. Requirements precede preparation. Unsupported resources
skip; missing declared hardware, unreachable targets and broken controls fail.
An entirely skipped run is not a pass. The only supplied control fixture is
`{:qemu, owned_handle}`; there is no automatic physical attachment.

Privileged deliberate crashes live in `Scenarios.Recovery`, which discovers live
children through owning supervisors rather than generated registry names.
Ordinary cases use bounded domain RPC/observations. Firmware Reach rules protect
public UI/domain boundaries and pure policies/read models; they are not a complete
root dependency policy. Pure checks/builds do not prove guest callback, restart,
Internet or physical behavior: those need explicitly authorized runtime checks.

Root `mix check` runs host tests, SDK/generated-plugin/plugin tests and all firmware
quality gates except dialyzer. Root `mix ci` additionally runs dialyzer. Neither
starts devices. Routine CI also builds EC100 dev/prod and QEMU firmware and packages
generated plugins and both bundled plugins, but boots no devices. QEMU integration and publishing are explicit workflows with
independent version rules. Publishing credentials never belong in the workbench;
see [CI](ci.md) and [releases](releases.md).

## Trust and physical operations

The gateway has **no user sign-in** and listens on all IPv4 interfaces. Cellular
filtering, CSRF/session checks and CSP do not authenticate LAN/VPN users. Management
access, including SIM controls and cookie display, must remain on trusted networks;
see [HTTP exposure](networking.md#local-recovery-and-http-exposure). USB proof for
first-network auto-save and USB password recovery are separate server-observed
checks, not a general USB-only management rule.

Discovery is unverified metadata, never authentication or permission to update.
Physical SSH uses known-host verification separate from disposable-QEMU trust.
`Workbench.SSH` owns strict host-key/authentication policy and a single firmware
upload. Identity, health and plugin transfer use distribution. Permissive
owned-QEMU SSH is reserved for explicit SSH scenarios. `System.maintenance_info/0`, `System.hardware_info/0` and
`Plugins.install_review/1`/`install_reviewed/2` are compiled device APIs. Unsupported
firmware is rejected; there is no alternate identity protocol or verification downgrade.
Firmware stores the build commit in Nerves VCS metadata and exposes it as
`System.info().source_revision`, independently of its semantic version.

An update snapshots the image, verifies identity, requires explicit confirmation
and rechecks before upload. Acceptance does not prove a healthy reboot. Destructive
USB provisioning has separate review/confirmation and verified writes; RAM
transport review is not a disk write. Reconnection is read-only and never replays
flashing. See [firmware updates](firmware-updates.md).

Workstations and trusted plugins are privileged. Keep credentials, private URLs,
cookies and VM identity disks out of read models, diagnostics and uploaded
artifacts. Never attach simulator controls to arbitrary VMs or physical gateways.
