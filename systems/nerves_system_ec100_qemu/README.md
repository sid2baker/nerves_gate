# EC100 QEMU system

`nerves_system_ec100_qemu` runs the real Nerves Gate backend on virtual x86_64
hardware with EC100-aligned system capabilities. It does not emulate EC100
peripherals or its ARM boot chain. The application's Mix target remains `x86_64`.

This package has its own semantic version in `VERSION`, independent of the
application, Buildroot and upstream Nerves system versions. See
[CHANGELOG.md](CHANGELOG.md) for this system's releases and
[GATEWAY.md](GATEWAY.md) for alignment and hardware differences.

`mix setup` in the application root downloads the matching prebuilt system from
GitHub Releases. Maintainers bump `VERSION` and add a dated changelog section when
build inputs change. The main-branch workflow builds and publishes
`ec100-qemu-v<VERSION>` automatically; it never replaces a published artifact.
See the [release workflow](../../docs/development.md#maintaining-the-qemu-system).

The source is based on `nerves-project/nerves_system_x86_64` commit
`5d755dba94fff478eac2bfd90ba91d2e0025d4eb` (1.34.2). Original
[documentation](UPSTREAM_README.md), [changelog](UPSTREAM_CHANGELOG.md), SPDX
annotations and licenses are retained for attribution and reference.
