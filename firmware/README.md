# Device firmware

The Nerves Gate runtime and shared gateway UI, for EC100 and x86_64 QEMU. Device
domains own commands, admission, persistence and deadlines. Apps use the SDK;
workstation tooling never substitutes fake hardware services.

This is an independent Nerves project inside the developer-platform checkout.
It reads the root `VERSION`; it is not published as a Hex package.

```sh
cd firmware
export NERVES_GATE_LOCAL_DEPS=1 # use this checkout's system sources, as setup does
mix deps.get --check-locked
mix ci                         # host checks and pure unit tests; no device
MIX_TARGET=x86_64 mix firmware  # build only, never flash hardware
```

Use root `mix setup` first for host tools, tailscaled and system artifacts.
Device builds always run in a separate process from the workbench and root host
checks. A physical EC100 build selects `MIX_TARGET=ec100`; its system artifact is
separate and must be available. Building does not authorize updating hardware.

Host config starts no device domains. Root `mix dev.ui DEVICE` explicitly starts
the shared gateway UI against a running simulated or development gateway.

See the [public API](lib/nerves_gate.ex), [architecture](../docs/architecture.md),
[applications](../docs/applications.md) and [platform changelog](../CHANGELOG.md).
