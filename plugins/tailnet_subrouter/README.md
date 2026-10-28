# Tailnet subnet-router plugin

A trusted, firmware-selected OTP plugin. It uses the gateway's existing network
and Tailscale services; it starts no web server or separate Tailscale daemon.

`plugins/selection.exs` includes this project. Root `mix firmware` builds its pure-BEAM
artifact and read-only inventory. Add/update/remove plugin code through firmware,
not a separate release or runtime install. The plugin manager starts it disabled;
no Ethernet configuration or route advertisement occurs on startup or page load.

## Use

1. Under **Hardware**, enable and exclusively assign a free LAN to `tailnet_subrouter`.
   Confirm the checked stop of affected plugins. Internet and management interfaces
   cannot be assigned; leave them unchanged.
2. Open **Plugins**, Start `tailnet_subrouter`, then **Open plugin**.
3. Select an eligible interface and enter an unused gateway-side IPv4 address and
   prefix. The picker disables Internet, claimed, addressed and operator-disabled
   or differently assigned interfaces with explanations. Refresh after assignment changes.
4. **Configure address** claims the interface and applies a temporary local address.
   It does not advertise a route or set DHCP, DNS or a default route.
5. Once link readiness is observed, explicitly **Enable sharing**. Approve the
   subnet in the Tailscale admin console and permit access in tailnet policy.
   Advertisement does not prove approval or reachability.
6. **Disable and release** withdraws the owned route and removes the temporary address.

The supervised `TailnetSubrouter` process owns SDK calls and their lease. Its
LiveComponent only sends commands. The backend revalidates availability and subnet
overlap; UI filtering never replaces admission. Keep independent management available.

```elixir
TailnetSubrouter.configure("eth1", "192.168.50.2", 24)
TailnetSubrouter.enable()
TailnetSubrouter.status()
TailnetSubrouter.disable()
```

Configuration is volatile and is not replayed after restart. The platform retains
a durable cleanup journal so a crash cannot silently forget an address or owned
advertisement. Incomplete cleanup blocks reuse and is reported, not retried blindly.
No SD card is needed for this plugin's own configuration or bundled code.

## Development

```sh
cd plugins/tailnet_subrouter
mix test
```

See [plugin development](../../docs/plugin-development.md) and
[runtime](../../docs/plugins.md). Native dependencies and automatic sharing
restoration are outside this plugin's contract.
