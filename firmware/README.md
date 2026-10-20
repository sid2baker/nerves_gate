# Nerves Gate firmware

The `nerves_gate` device application: network, Tailscale, equipment, bus, LED and
SSH domains, the gateway LiveView UI, the device SDK backend and the trusted OTP
application runtime. EC100 (`MIX_TARGET=ec100`) and QEMU (`MIX_TARGET=x86_64`)
build the same application; host builds are for quality checks and assets only.

Develop from the repository root (`mix setup`, `mix dev`, `mix firmware ec100`).
Inside this directory, set `NERVES_GATE_LOCAL_DEPS=1` to use the repository's SDK
and systems:

```sh
NERVES_GATE_LOCAL_DEPS=1 mix ci                 # quality gates
NERVES_GATE_LOCAL_DEPS=1 mix assets.build       # commit priv/static/assets/
```

Integration scenarios live in `test/scenarios/` and run on the
[QEMU simulator](../sim/README.md). See the [repository README](../README.md) and
[guides](../docs/development.md).

This package has its own VERSION and CHANGELOG; releases use `firmware/vX.Y.Z` tags.
