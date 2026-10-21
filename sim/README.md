# QEMU engine

`sim/` is the independent, host-only QEMU subsystem of the Nerves Gate developer
platform. It owns real disposable devices, private socket networking, virtual SD
cards, faults, scenario admission and per-device reservations. There is no fake
hardware backend and it never attaches to arbitrary VMs.

The workbench UI, session launchers, app commands and release tools live at the
repository root. Run `mix dev [SOLUTION]` there, and explicitly start devices in
the workbench. `mix test.qemu --only ID` attaches to that session;
`mix test.qemu --ci --only ID` owns a separate disposable bench when authorized.

Independent use:

```sh
cd sim
mix deps.get --check-locked
mix ci                  # pure host tests, no devices
mix qemu.setup          # workstation prerequisite checks
```

`NervesGateSim.Simulator` owns lifecycle and QEMU hardware. `QemuTests` owns shared
UI/CLI/CI admission. `scenarios/` modules are compiled by the platform root, not
the engine, so workbench-level scenarios do not introduce a reverse dependency.
`Simulator.config/2` resolves custom firmware paths relative to its trusted config
file, or uses `:local` to select the checkout's firmware project.

The engine starts no devices automatically. It shares the root platform version
and is no longer published on Hex. See [architecture](../docs/architecture.md)
and [development](../docs/development.md).
