# Nerves Gate SDK

A pure Elixir application API. It has no Nerves or Linux dependencies. Gateway
firmware implements `NervesGateSDK.Backend`; on a workstation, calls return
`{:error, :backend_not_configured}`. Run applications on real firmware, including
the QEMU gateways of the Nerves Gate developer workbench.

```elixir
alias NervesGateSDK.{CAN, Events, Network, Storage, System}

{:ok, info} = System.info()
{:ok, interfaces} = Network.interfaces()
:ok = Events.subscribe(:network)
{:ok, directory} = Storage.data_dir(:my_app)
:ok = CAN.subscribe("can0")
:ok = CAN.send("can0", %CAN.Frame{id: 0x123, data: <<1, 2>>})
```

Subscriptions deliver `%NervesGateSDK.Events.Event{topic: topic, value: value}`
to the calling process. Backends monitor subscribers and RS485 claim owners;
resources are released when their owner exits. SDK structs are the public contract,
not firmware status maps. Commands return `:ok`, `{:ok, value}` or `{:error, reason}`.
A timeout means an unknown outcome, not cancellation or permission to retry.

The runtime selects the backend with `config :nerves_gate_sdk, backend: Module`.
Applications should not select a device backend themselves. SDK APIs do not manage
Internet/USB, Tailscale enrollment or credentials, SSH, apps or firmware, expose
cookies, or reboot/reset the device.

## Isolated local-network access (SDK 0.2.0-dev checkout)

An operator must explicitly enable a non-Internet Ethernet port for applications.
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
See `apps/tailnet_subrouter` in the source repository for an optional, disabled-on-start
example. Use the local SDK with requirement `~> 0.2.0-dev`; the published 0.1.0
package does not contain this API. The device installer enforces the declared range.

Applications on a device are trusted same-BEAM OTP applications, not sandboxed.

## Equipment ownership

Applications own identities, discovery and protocol sessions. The SDK has no
`Equipment` compatibility module or equipment event topic. Use
`Network.interfaces/0` for platform link observations.

## Application packages

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
other installed application names/modules. Native code must be built for the
device architecture; this task does not cross-compile it.

An optional `:nerves_gate_health_check` environment entry contains an MFA that
must return `:ok` within five seconds after startup. A failed upgrade restarts the
previous version without changing its persisted selection. The administrative
`NervesGate.Apps` lifecycle API belongs to firmware, not the SDK.
