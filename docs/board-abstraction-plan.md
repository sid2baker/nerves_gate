# Step 1: put hardware settings in one place

## Assignment

Implement this plan in one pass: configuration, readers, tests and documentation.
Read `AGENTS.md` first. Do not commit, push or delegate unless separately asked.

Keep it simple. This is a configuration cleanup preparing for another board,
not a new hardware abstraction framework or an EM300 port.

## Goal

Each target declares its existing hardware settings in one `:board` map.
Device domains read that map instead of separate application settings.
Everything behaves as before.

Ownership stays clear:

- **Nerves system/BSP:** kernel drivers, device tree, boot, partitions and stable
  Linux device names.
- **Board config:** which hardware and existing adapters this device uses.
- **Domains:** commands, admission, deadlines and persistence.
- **Applications:** the existing SDK, not board-specific branches.

## 1. Group the existing settings

In `firmware/config/ec100.exs`, replace the separate hardware keys with:

```elixir
config :nerves_gate, :board, %{
  cellular: %{
    interface: "wwan0",
    config: %{type: VintageNetECM, vintage_net_ecm: %{at_tty: "ttyUSB2"}}
  },
  buses_adapter: {NervesGate.Buses.EC100, nil},
  indicators_adapter: {NervesGate.Indicators.EC100, "/sys/class/leds"},
  recovery_adapter: {NervesGate.Recovery.EC100, nil},
  data_partition: "/sys/class/block/mmcblk0p3/dev",
  apps_device: "/dev/mmcblk1p1"
}
```

Check the current values before moving them; this change must preserve them.
Do the same in `x86_64.exs`, keeping its existing storage paths and nil hardware
adapters/modem. Remove the old shared `:cellular` default in `firmware.exs`;
each device board declares it explicitly. Host configuration starts no device
services and has no hardware; optional board lookups there return nil.

Leave ordinary service settings (`:network_adapter`, `:remote_adapter`,
`:equipment_adapter`, metadata paths, mount policy) where they are.
Leave VintageNet bootstrap configuration unchanged, including recovery `usb0`
and QEMU's management-only `eth2`.

Add `firmware/lib/nerves_gate/board.ex` with only the small accessors needed to
read this map. Optional hardware can be nil; required device settings should
fail clearly when missing. No process, registry, schema framework, inheritance,
runtime discovery or compatibility fallback to the old settings.

Do not add unused board IDs, labels, port descriptors or capabilities.

## 2. Update the readers

Follow references to the moved settings, starting with:

- `firmware/lib/nerves_gate/network/cellular.ex`
- `firmware/lib/nerves_gate/buses.ex`
- `firmware/lib/nerves_gate/indicators.ex`
- `firmware/lib/nerves_gate/storage.ex`
- `firmware/lib/nerves_gate/recovery/data_init.ex`

Read board defaults through `NervesGate.Board`. Preserve existing explicit
startup options used to inject adapters in tests. Remove old env-key readers
rather than supporting both representations.

Keep existing adapter modules and invocation signatures. In particular, keep
`Buses.EC100` and its fixed, safe port allowlist. Another real board can motivate
extracting shared driver code later; do not rename adapters speculatively.

Do not read board configuration from pure status/policy functions, projections,
the SDK or workstation UI. Those consumers do not need to change in this step.

## 3. Update tests and documentation

- Update `firmware/test/unit/build_config_test.exs` to inspect each target's board
  map. Assert that EC100 retains its modem/adapters/storage, QEMU retains its
  storage with unsupported hardware nil, and bootstrap networking is unchanged.
  Preserve existing early data-initialization assertions.
- Update `firmware/test/unit/cellular_test.exs` and any other tests that override
  moved env keys. Restore the entire previous board setting after each test;
  tests mutating application config must be synchronous.
- Use the existing firmware/root tests. No fake hardware suite, alternate board
  layouts, new scenario runner or elaborate board validation tests.
- Add a short explanation of the board config and ownership to
  `docs/architecture.md`. Note that today's `x86_64` configuration describes QEMU,
  not arbitrary x86 PCs. Avoid claiming EM300 support or that arbitrary port
  layouts already work.

## Explicitly deferred

The current two-port network model, `eth0`/`eth1` settings keys, bus identifiers,
UI labels/routes, public status and SDK contracts remain unchanged.

Variable Ethernet layouts, removal of fixed port-name assumptions, device-owned
UI port metadata and reusable fieldbus drivers are later work, driven by actual
hardware. The EM300's three Ethernet ports will require a separate network-model
change. Wi-Fi, I/O expansion, UPS handling and its BSP are also out of scope.

Do not edit `systems/`. Do not change persistence, network trials/rollback,
Tailscale behaviour or PIN safety. VintageNet still owns networking and its
persistence; `VintageNetECM.command/3` still owns modem commands.

## Validation and completion

1. Inspect Git status and preserve unrelated changes.
2. Use semantic Elixir tools for structural edits; use exact edits for small
   replacements. Do not perform blind global rewrites.
3. Run `mix format --force` and root `mix ci` (host checks only).
4. For device verification, use the user's existing `mix dev` bench with updated
   firmware. Rebuild/reset/start actions require authorization; do not launch a
   session or `--ci` bench. On an authorized updated bench, run focused
   `public_status` and `topology` scenarios with `mix test.qemu --only ID`.
   If unavailable, finish host checks and report device verification as pending.
   Do not edit reloaded code while scenarios run. No physical flashing.
5. Check the diff: one source for hardware settings, no stale env-key readers,
   no behaviour/API changes and no new abstractions beyond the board accessor.

Report the changed files, checks and any pending device verification. Leave the
changes uncommitted unless asked otherwise.
