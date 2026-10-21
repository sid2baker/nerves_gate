# Nerves Gate firmware

The `nerves_gate` device application: network, Tailscale, equipment, bus, LED and
SSH domains, the gateway LiveView UI, the device SDK backend and the trusted OTP
application runtime. EC100 (`MIX_TARGET=ec100`) and QEMU (`MIX_TARGET=x86_64`)
build the same application; host builds are for quality checks and assets only.

Use repository-root `mix setup` and `mix dev` for product development.
Firmware-specific commands run **inside this directory**, never through a root
firmware alias. Set `NERVES_GATE_LOCAL_DEPS=1` to use the repository's SDK and
systems:

```sh
NERVES_GATE_LOCAL_DEPS=1 mix ci                 # quality gates
NERVES_GATE_LOCAL_DEPS=1 mix assets.build       # commit priv/static/assets/
NERVES_GATE_LOCAL_DEPS=1 MIX_TARGET=ec100 MIX_ENV=prod mix firmware
NERVES_GATE_LOCAL_DEPS=1 MIX_TARGET=x86_64 mix firmware
```

Integration scenarios live in `test/scenarios/` and run on the
[QEMU simulator](https://github.com/sid2baker/nerves_gate/blob/main/sim/README.md).
See the [repository README](https://github.com/sid2baker/nerves_gate/blob/main/README.md)
and [guides](https://github.com/sid2baker/nerves_gate/blob/main/docs/development.md).

This package has its own VERSION and CHANGELOG; releases use `firmware/vX.Y.Z` tags.
