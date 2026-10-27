# Tailnet subnet router — optional starter app

An ordinary SDK application, not a built-in gateway service. Install/start it explicitly;
startup is disabled and never configures a link or advertises a route. No configuration
or enable intent is replayed after restart. No separate web server, credentials, packet probes,
DHCP server, Internet sharing or automatic discovery is included.

## Install a published release from the gateway

On updated firmware, open **Applications → Check GitHub releases**, select the
subnet router and **Review install / upgrade**, then confirm the displayed version,
digest and compatibility requirements. The gateway fetches the package itself.
New installs remain stopped: choose **Start**, then **Open application**.
No SSH file copy or IEx command is needed for this path.

The release workflow is prepared separately from publication. If no app release
has been published, the page reports that; a local source/build is not a public
release. Publication and device installation remain separate explicit operations.

## Prepare and package

Requires firmware from this checkout implementing managed SDK activations and app UI
mounting. The UI uses the firmware's Phoenix/LiveView libraries; packaging records exact
platform versions and rejects mismatches. No SDK release is implied by this source example.

From the repository root:

```sh
mix app.test apps/tailnet_subrouter
mix app.package apps/tailnet_subrouter
```

The workbench's Applications page also has **Open starter app source**, followed by
ordinary Test/Package actions. Opening or packaging installs nothing. On the app
details page, **Install on physical device → Review package and device** builds a
private snapshot and reads verified identity/storage before a one-use typed-address
confirmation. Installation leaves the app stopped and disabled; then deliberately
start it with the gateway's **Applications → Start** button, or
`NervesGate.Apps.start(:tailnet_subrouter)` in trusted SSH IEx.
Existing installations are rejected, never automatically upgraded. See
[app development](../../docs/app-development.md) for the full review/start procedure.

1. Enroll the gateway in Tailscale using its Remote access page.
2. Keep independent USB management and use a dedicated, authorized equipment network.
3. Finish Internet setup, then enable a non-Internet Ethernet interface in **Hardware**.
   Legacy joined/equipment configurations are rejected, never automatically changed; migrating them remains
   an administrator API operation, not something this app may do.
4. Choose an unused gateway-side IPv4 address on a non-overlapping local subnet.

## Gateway UI

After explicitly starting the app, open **Applications → tailnet_subrouter → Open
application** on the gateway, or `/apps/tailnet_subrouter`.

1. Select the application-enabled interface, unused gateway-side IPv4 address and
   prefix, then **Configure address**. This does not advertise anything.
2. Connect the local cable and **Refresh status** to confirm the link is ready.
3. Choose **Enable sharing**, then approve the subnet in the Tailscale admin console
   and allow it in tailnet policy. Advertisement does not prove approval/reachability.
4. Choose **Disable and release** to withdraw the app-owned advertisement and remove
   its temporary address.

No command is retried automatically. After an unknown outcome, refresh and inspect
status before continuing. Stop/upgrade closes open app pages before unloading code;
reload once the new activation is ready. This first version uses the gateway's
existing styles and has no custom JavaScript. Device app code is not loaded by
host-only `mix dev.ui` previews: use the gateway's own HTTP service for app pages.

The initial release version is 0.1.0. The UI adds no automatic configuration or
enable intent. Earlier local development installs numbered 1.0.0 or 1.1.0 are not
published releases, but remain immutable on-device: the GitHub installer rejects
0.1.0 as a downgrade. Moving such a device to the initial release requires an
explicitly authorized uninstall/reinstall; no saved state is migrated or erased
automatically.

## Explicit application commands

In the gateway's trusted SSH IEx session, after installation and startup:

```elixir
# Example only: replace these values for your authorized network.
:ok = TailnetSubrouter.configure("eth1", "192.168.50.2", 24)
TailnetSubrouter.status()
# Connect the local cable and check link_ready before explicitly enabling.
:ok = TailnetSubrouter.enable()
TailnetSubrouter.status()
```

`configure/3` claims the interface and applies only a temporary static address. It does
not advertise it. `enable/0` explicitly adds that exact subnet to the daemon's existing
advertisements. It refuses a route already advertised by someone else; it never adopts
it. Management enrollment, DNS, Serve, Internet and unrelated routes are unchanged.

Approve the subnet in your Tailscale admin console and allow it in tailnet policy, then
test access deliberately from an authorized peer. `advertised: true` means advertised,
not approved or reachable. `tailnet_approval: :unknown` is intentional: the gateway's
current daemon observations do not prove control-plane approval. No approval is inferred
from an advertisement or link status. Overlapping client LANs/VPNs remain unsupported.

## Disable and cleanup

```elixir
:ok = TailnetSubrouter.disable()
# Before stopping/uninstalling, check the completed result.
TailnetSubrouter.status()
```

Disable withdraws **only the advertisement introduced by this claim**, then removes its
temporary address. The operator's application-enable setting remains. It never calls
Tailscale down or disconnects management. Claim references are private to the supervised
app process and excluded from its public status.

If the owner stops/crashes, Network schedules the same cleanup. A small device-owned
journal records the interface/address and whether a route write may have happened,
before the effect. Network restarts retain the cleanup obligation, not enable intent.
Unknown/corrupt state blocks reuse; it is not silently erased or treated as success.
Do not retry an uncertain configure/enable command. Inspect app and gateway status first.

An incomplete cleanup retains the journal, blocks new claims and network reconfiguration,
and requires inspection. Once any continuing daemon operation has settled, an administrator
can explicitly request `NervesGate.Network.recover_local/0` for an orphaned claim. This
only withdraws/removes its recorded resource; it never advertises again. Do not delete
the journal or credentials to force recovery.

This first implementation supports **one application local-network claim per gateway**,
on one independent Ethernet interface. It does not join ports, configure Internet, borrow
USB, change workstation routes, or arbitrate privileged commands issued outside the gateway.
