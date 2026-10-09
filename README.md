# Nerves Gate

A two-port Ethernet remote-access gateway for EC100 and x86_64, built with
Nerves 2 and Phoenix LiveView. This repository is being rebuilt in small milestones.

## Development

Use Elixir 1.20 and the Erlang/OTP major version required by the target system.

```sh
mix deps.get
mix test
mix phx.server
# http://localhost:4000
```

Host mode must never modify the workstation's network. All browser assets are
local and checked in. To rebuild CSS: `cd assets && npm ci && npm run build`.
Node.js is not needed to compile firmware or use the setup page.

## Targets

```sh
MIX_TARGET=ec100 mix deps.get
MIX_TARGET=ec100 mix compile
MIX_TARGET=x86_64 mix deps.get
MIX_TARGET=x86_64 mix compile
```

Both systems are pinned to reviewed upstream commits in `mix.exs`. EC100 uses
its existing Nerves 2 system, bootloader, GPT storage layout and A/B firmware
contract. Upstream x86 supports Nerves 2, but neither current kernel configuration
provides the bridge support needed here. System enablement is a separate gate
from application compilation. The old x86 system is retained temporarily, not
used by the application.

## Current scope

The replacement host application has an offline LiveView shell. Networking,
persistence and guarded changes are the next milestone. Tailscale will use only
`sid2baker/tailscale_ex`; cellular and firmware upload are not implemented yet.
The target web listener remains loopback-only until LAN access controls exist.
SSH recovery is key-only; set `NERVES_GATE_SSH_KEYS` to public keys at build time.

EC100 upstream currently disables USB following reconnect problems. USB0's
previous peripheral configuration and USB1 host wiring were found in its history;
neither is considered fixed or validated. Do not depend on USB provisioning yet.
Keep serial and Ethernet recovery available. Modem transport remains unverified.

No EC100 hardware behavior has been validated during this rebuild.
