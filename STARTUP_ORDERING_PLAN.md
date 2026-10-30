# Startup ordering plan

**Status:** implemented and qualified on rebuilt QEMU guests.

## Problem

`NervesGate.Plugins` starts before `NervesGate.SDKBackend`, which plugins call
during startup. It therefore polls every second until `Network`, `Hardware` and
`SDKBackend` are registered, then restores plugins at some later moment. It also
polls `Storage.identity/0` every second to notice card changes.

Because restoration is "eventually", clients must wait for it: scenarios use
`ManagedPlugin.await_idle/1` and "plugin manager observed storage" loops, and
commands can return `:plugins_not_ready`.

## Principles

- Supervision order is the startup barrier. A child may rely on every earlier
  sibling having completed `init/1`.
- `init/1` performs only bounded setup. Longer work runs in `handle_continue/2`
  and is reported as an explicit state, never as a reason for callers to poll.
- `:rest_for_one` restarts dependents after a dependency restarts, so no process
  keeps a stale PID or binding.
- Asynchronous facts outside boot (card insertion, DHCP, NTP, Tailscale login)
  arrive as notifications that the owner subscribes to.

## Target order

```text
PubSub, Plugins.UI
Network.Vintage, Properties, Settings, SSH, Network, Remote, Indicators, Hardware
PluginTasks, Storage, IO, IO.Manual
SDKBackend
Plugins
ProjectionServer, Endpoint
```

- `SDKBackend` moves before `Plugins`: plugins call it while starting.
  `Plugins.Owner.resolve/2` already returns `:plugin_not_running` while the
  generation table does not exist, so SDK calls before `Plugins` are safe.
- `Plugins` comes after everything plugins depend on, but before
  `ProjectionServer` and `Endpoint`. With `:rest_for_one`, a UI or projection
  crash must not restart every plugin. Plugin pages and administrative views
  call `Plugins` at runtime, never during their own `init/1`.
- The generation table stays owned by `Plugins`: its loss on a controller
  restart remains the fence that revokes every activation.

## Plugins behaviour

1. `init/1` reads metadata and hardware assignments and creates the generation
   table, as today.
2. `handle_continue(:restore, ...)` starts the restore job immediately. The
   `Process.whereis` readiness check and its 1 s `:storage` poll are removed.
3. Firmware-bundled plugins restore without storage. Development artifacts are
   restored when `Storage` reports a usable card.
4. `Plugins` subscribes to the existing `["storage"]` observation published by
   `Storage` and reacts to identity changes in `handle_info`, replacing the
   poll. It subscribes before its first `Storage.identity/0` read ("subscribe
   before reading"), so a change between the two is never lost.
5. While the restore job runs, commands still return `:plugins_not_ready`
   immediately; nothing sleeps. Restoration cannot run inside `init/1`:
   plugin start callbacks call back into `Plugins` (for example `Network`
   authorizing a port claim), which would deadlock.
6. The poll also detected plugin applications that stopped on their own. Each
   running plugin's top supervisor (`:application.get_supervisor/1`) is now
   monitored instead. Outside a lifecycle job, `:DOWN` records the stopped
   activation directly: the application controller can still list the application
   as started when its supervisor exits. During a job, completion rereads current
   applications because that job may intentionally restart the plugin.
7. Storage notifications trigger a fresh identity read. Changes during a job are
   reconciled after completion. Blocked cleanup remains fail-closed.

## Waits that remain

- `Recovery.DataInit` waits for the first `fwup status` because
  `nerves_runtime` 0.13.13 lets a timed-out `FwupOps` call crash `KV` during
  boot. Remove the workaround when the dependency handles that timeout.
- `Remote` waits for the external Tailscale daemon's login state.
- Scenarios still observe asynchronous physical facts (links, addresses, NTP).
- `ManagedPlugin.await_idle/1` and the `sd_plugins` storage precondition read
  explicit restore/job state and Storage identity. They wait for a real
  asynchronous operation (the restore job, a reconciliation job after a card
  change), not for hidden readiness, so they remain.

## Validation

- Firmware unit tests start `Plugins` after its supervision-order
  prerequisites. Restore and storage reactions need the real Network,
  SDKBackend and card, so they are qualified on QEMU rather than with a mock.
- Root `mix check` passed: 363 tests, formatting and static checks.
- Rebuilt-QEMU `plugins`, `qemu_sdk`, `sd_plugins`, `plugin_lan`,
  `restart_intensity` and `process_chaos` passed. The SDK scenario now checks
  unexpected plugin application stop; four consecutive admitted runs passed
  after fixing the application-controller race.
- The final full standard catalogue passed **43/43** in one run:
  `70ab33168f52cd8cdb44b4e61eaaf4ac:runner:7232`.
  Result: `/tmp/startup-all2-final.json`; observer log:
  `/tmp/startup-all2-watch.log`. Opt-in `tailscale_auth` was excluded.
- Registry recovery expectations follow the new SDKBackend restart scope;
  `dependency_restart` passed individually and in the final full run.
- No physical device changes; EC100 boot uses the same supervision tree but
  was not qualified on hardware.
