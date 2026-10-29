# Nerves Gate SDK

A pure Elixir plugin API. It has no Nerves or Linux dependencies. Gateway
firmware supplies the fixed `NervesGate.SDKBackend.call/2` runtime entry point,
which implements the `NervesGateSDK.Backend` callback. Without that firmware module,
calls return `{:error, :runtime_unavailable}`; firmware code loaded without running
device services reports `{:error, :unavailable}`. Run plugins on real firmware, including
the QEMU gateways of the Nerves Gate developer workbench.

```elixir
alias NervesGateSDK.{Events, Hardware, Network, Storage, System}

{:ok, info} = System.info()
{:ok, interfaces} = Network.interfaces()
:ok = Events.subscribe(:network)
{:ok, directory} = Storage.data_dir(:my_app)
{:ok, assigned_ports} = Hardware.resources() # managed plugin caller only
```

## Plugin configuration (SDK 0.2.0-dev.2 checkout)

```elixir
:ok = Storage.save_config(%{clients: [...], servers: [...]})
{:ok, config} = Storage.restore_config() # or :not_found
:ok = Storage.delete_config()            # or :not_found
```

One opaque term per running plugin version, stored on commissioned SD storage.
The platform derives plugin and version from the actual managed caller. Saves
are atomic replacements (at most 1 MiB serialized); `{:error, :commit_unknown}`
means the new term may or may not be durable. Restores refuse atoms/functions
unknown to the running system and malformed files (`{:error, :invalid_configuration}`,
left in place). A new plugin version starts from `:not_found`; older versions'
terms are kept and never loaded or migrated automatically. Without storage, calls
return `{:error, :storage_unavailable}`; there is no `/data` fallback.

Subscriptions deliver `%NervesGateSDK.Events.Event{topic: topic, value: value}`
to the calling process. The backend monitors subscribers. Plugins supervise their
own serial/CAN libraries and handles; ordinary OTP shutdown must close them. Stateful calls require an installed,
starting/running managed plugin. The backend derives activation identity from
the actual PID, never a supplied plugin name. Activation generations fence stale
subscriptions/claims/in-flight work; restart/rollback requires fresh subscriptions
and handles. Outside managed plugins, general platform read-only queries remain available,
but resource calls fail with `plugin_not_running` (network errors use the
string code). Use administrative domain APIs for IEx/RPC maintenance.
SDK structs are the public contract,
not firmware status maps. Commands return `:ok`, `{:ok, value}` or `{:error, reason}`.
A timeout means an unknown outcome, not cancellation or permission to retry.

Both physical and QEMU firmware supply the same runtime entry point. There is no
backend configuration or host hardware emulation. The bridge is an ordinary module
call in the plugin's process, not a proxy process; the SDK has no compile-time
Mix dependency on firmware. SDK APIs do not manage
Internet/USB, Tailscale enrollment or credentials, SSH, plugins or firmware, expose
cookies, or reboot/reset the device.

## I/O: Readings, Desires and Apply (SDK 0.2.0-dev.3 checkout)

A **Reading** is the latest observation of an input; a **Desire** is what the
current controller of an output wants; **Apply** is the plugin's attempt to make
it so; **Status** is the platform's judgement of whether the evidence agrees.
Shared types: `IO.InputDefinition`, `IO.OutputDefinition`, `IO.Evidence` and
`IO.Reading`. Definitions persist on firmware; Readings, Desires and Authority do not.

Inputs: managed plugin processes call `IO.register_input/1` and `IO.publish/3` with
local IDs. Readers use `input/1`, `output/1`, `subscribe/1` and `unsubscribe/1` with
full IDs; subscribe before reading and resubscribe after controller loss.

Outputs: start `NervesGateSDK.Output` under your supervision with the output
definitions and a module implementing `apply/3`:

```elixir
@behaviour NervesGateSDK.Output

@impl true
def apply(id, nil, state), do: {:applied, state}   # Desire ended: your release behaviour

def apply(id, value, state) do
  case MyDevice.write(state.device, id, value) do
    :ok -> {:applied, state}
    {:error, :timeout} -> {:unknown, state}
    {:error, reason} -> {{:failed, reason}, state}
  end
end
```

The runtime registers the outputs, runs `apply/3` in its own process, always
applies the newest Desire and reports outcomes under the current claim epoch;
results for an ended claim or superseded Desire are discarded. It never calls
`apply/3` merely because it started and never retries; use `Output.reapply/2` or
`Output.reapply_after/2` for repeatable operations. A module defining `apply/3`
must call `Kernel.apply/3` qualified.

Declare `evidence` (inputs, possibly from other plugins, with a role, settle time
and expectation) and `on_release` (`:hold` or `{:value, v}`, descriptive only) in
the output definition. Writers use `claim_output/1`, `set_output/2` and
`release_output/1` with full IDs; success stores only a Desire. Calls preserve actual
PID ownership. See the [I/O domain API](../docs/action-api.md#io-state-and-desire).
There is no command, request-journal or safety contract.

Use the local SDK requirement `~> 0.2.0-dev.3` for these APIs. They are not in the
published 0.1.0 package.

## Isolated local-network access (SDK 0.2.0-dev checkout)

An operator must enable and exclusively assign a non-Internet LAN to the plugin
under Hardware. The plugin declares `nerves_gate_hardware: [:ethernet]`.
`Network.claim_local(interface, address, prefix)` gives the actual caller exclusive
access to one temporary static local interface, without DHCP, DNS or a default route.
`Network.local_status/0` reads only that caller's private lease, including its handle
when a claim reply was lost. `Network.advertise_local/1` explicitly advertises the
claim's ready subnet through the platform's enrolled tailnet, refusing an already
advertised route. It does not enroll/disconnect Tailscale or prove route approval.

`Network.release_local/1` withdraws the claim-owned advertisement before removing
its address. Owner death schedules cleanup; unresolved cleanup and corrupt ownership
journals block reuse, including after platform restart. Never blindly retry an
uncertain write. Lease references are private and must not enter logs/projections.
The first implementation supports one independent Ethernet claim per gateway.
See `plugins/tailnet_subrouter` in the source repository for an optional, disabled-on-start
example. Use the local SDK with requirement `~> 0.2.0-dev`; the published 0.1.0
package does not contain this API. The device installer enforces the declared range.

Plugins on a device are trusted same-BEAM OTP applications, not sandboxed.

## Exclusive hardware assignments

Plugins declare the kinds they use (`:ethernet`, `:serial`, `:can`) in `nerves_gate_hardware` in their main OTP
environment. `Hardware.resources/0` returns enabled allowlisted assignments for the
actual managed caller, as `%Hardware.Port{id: ..., kind: ..., present?: ..., path: ...}`.
It opens nothing and accepts no plugin name or arbitrary operator-supplied path. One
port belongs to one plugin; a plugin may own several ports with supervised workers.

The plugin uses its ordinary transport library directly. Hardware assignment and
enablement changes require checked whole-plugin stop before mutation, including
both affected plugins, and leave them stopped. Native handles must drain. Unknown
cleanup/persistence blocks reuse. Assignments persist independently of plugin code.
The SDK is not a sandbox; trusted code can bypass coordination conventions.

Ordinary TCP connections need no hardware assignment. Reconfiguring a dedicated
local Ethernet interface requires its assignment plus `Network.claim_local/3`.
`Network.Interface.assigned_plugin` is a public read model for plugin UIs, not authority. UART's native driver is platform
provided; plugins declare compatible `circuits_uart` and packaging excludes its
native payload while recording an exact version requirement. No native plugin
binaries are introduced. See [hardware assignments](../docs/hardware.md).

## Equipment ownership

Plugins own equipment identities, discovery and protocol sessions. The platform
reports only its own links, through `Network.interfaces/0`.

## Plugin packages

`mix nerves_gate.package` builds production code into a standard
`<app>-<version>.ez` OTP archive. Declare
`env: [nerves_gate_sdk_requirement: "~> 0.2.0-dev"]` for this checkout (or the
matching published range for a released SDK) in `application/0` and
`def cli, do: [preferred_envs: ["nerves_gate.package": :prod]]` to select production
before dependency discovery on a clean checkout.

Bundled applications contain ordinary `<app>-<version>/ebin/*.app`, BEAM files
and optional `priv/` directories. There is no custom manifest or dependency
solver. OTP, Elixir, the SDK, Jason, Telemetry and Phoenix PubSub are supplied by
the platform, never bundled. The packager records exact versions of referenced
common libraries in the main application's `:nerves_gate_platform` environment;
the installer checks them and the SDK requirement against the running platform.
Other runtime dependencies are included and must not conflict with platform or
other plugin application names/modules. Absent optional dependencies are not
required. Contributed native payloads and direct NIF loaders are rejected; ordinary
`priv` data is allowed. The selected pure-BEAM plugins ship in firmware.

An optional `:nerves_gate_ui` OTP environment entry names a `Phoenix.LiveComponent`
in the main application's package. Current firmware hosts it at `/plugins/<app>` while
that activation is running. UI plugins declare their Phoenix/LiveView dependencies
directly and compile against versions compatible with the gateway. The core SDK
stays independent of web libraries; it does not wrap LiveView. These dependencies
are shared platform libraries, not bundled copies. The firmware's Req/Finch/Mint
HTTP libraries are likewise shared when a plugin depends on them. Packaging pins exact platform
versions, including transitive UI libraries. The gateway closes plugin-page processes
before unloading code. Component callbacks run in a gateway-owned LiveView: call
commands on your plugin's supervised process rather than acquiring SDK resources there.
Custom scripts/assets and dynamic subroutes are not part of this first integration.
See [optional plugin UI](../docs/plugins.md#optional-ui).

An optional `:nerves_gate_health_check` environment entry contains an MFA that
must return `:ok` within five seconds after startup. A failed upgrade restarts the
previous verified artifact with a fresh generation. Uncertain cleanup or rollback
failure blocks activation rather than claiming restoration. Versions are immutable:
bump the plugin version for changed package bytes. The administrative
`NervesGate.Plugins` lifecycle API belongs to firmware, not the SDK.
