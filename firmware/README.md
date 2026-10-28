# Device firmware

Nerves Gate runtime and shared gateway UI for EC100 and owned x86_64 QEMU devices.
Domains own named commands, admission, persistence and deadlines. `NervesGate`
provides direct `status/0` and caller-owned `subscribe/0`; plugins use the
separate typed SDK. Workstation tooling never substitutes fake hardware services.

This is an independent Nerves project inside the workbench checkout. It reads the
root `VERSION` and `CHANGELOG.md`; it is not published as a Hex package.

Run from the repository root:

```sh
mix setup                 # tools, locked dependencies and artifacts; boots nothing
mix firmware x86_64       # host assets, then isolated QEMU firmware build
mix firmware ec100        # host assets, then isolated EC100 firmware build
mix firmware ec100 --env prod
```

Device builds never run in the workbench VM, boot a guest or flash hardware.
EC100's separately published system artifact must be available. A build is not
authorization to update/reprovision a physical device or reset saved settings.
Incompatible saved cellular driver configuration fails startup before UART access;
there is no driver compatibility alias or automatic migration/erasure.

Host config starts no device domains. Root host checks enter this project through
native `Mix.Project.in_project/4`; unit/policy/codecs live in `test/unit/` and
gateway rendering/socket-security checks in `test/web/`. Real I/O uses the shared
owned-device scenarios. `mix dev` serves the workbench, not a gateway command proxy;
open each running device's own gateway URL. Gateway Elixir/HEEx changes require
rebuilt guests and an explicitly authorized runtime cutover.

See the [domain API index](lib/nerves_gate.ex), [administrative API](../docs/action-api.md),
[architecture](../docs/architecture.md), [development](../docs/development.md),
[plugins](../docs/plugins.md) and [changelog](../CHANGELOG.md).
