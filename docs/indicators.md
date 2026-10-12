# LEDs and physical button

One `NervesGate.Indicators` process owns policy, blink timing and button state.
EC100 uses the standard Linux LED/input devices; host mode only changes memory.

## LEDs

| Channel | EC100 GPIO / sysfs name | Normal meaning |
| --- | --- | --- |
| RUN | GPIO1_A7 / `ec100:run` | Solid while Indicators runs; off on orderly shutdown |
| USER1 | GPIO1_A6 / `ec100:user1` | Off intentionally disconnected/unconfigured Tailscale; solid confirmed Internet + healthy Tailscale; slow connecting/unknown/debouncing; fast managed connectivity fault |
| USER2 | GPIO1_A4 / `ec100:user2` | Off no known alarms, slow warning/unknown alarm observations, fast critical fault |

The operator confirmed brightness **1 = on, 0 = off**. Slow means one complete
cycle per second (500 ms per half-cycle); fast means four (125 ms per half-cycle).
RUN has no early-boot blink. An abrupt VM crash can leave the last output latched
until watchdog recovery/reboot; the LED is not an independent health monitor.

Alarmist assigns error severity immediately to `network_restore_failed`,
`led_restore_failed` and `recovery_failed`. Availability faults become managed
warnings after two continuous seconds and clear immediately on factual recovery.
USER2 uses Alarmist severity, including alarms from dependencies. No alarms means
*no known alarms*, not proof that every subsystem is healthy.

VintageNet's per-interface `connection` reports Internet availability on the
configured uplink (`br0` in shared mode), never USB or the global best connection.
Before port assignment, a unique observed Internet candidate may indicate online,
but there is no configured uplink requirement to alarm. `:lan` is not Internet;
missing observations are unknown. Tailscale `Running`/`:online` is a separate
backend state; health warnings can report control-server failures while it remains
Running. USER1 is solid only with confirmed Internet, authenticated online Tailscale,
no health warnings and no managed connectivity fault. Stopped/needs-login is off;
unknown is slow, never healthy. There is no separate LED connection-history latch.

Network, Remote and Alarmist events refresh policy. Five-second reconciliation repairs
missed notifications and retries unavailable LEDs. A monotonic 125 ms tick drives
blinks. Successful output values are cached; unchanged outputs are not rewritten.
Only the three mapped binary LEDs are eligible. Active kernel triggers are never
changed or taken over. A failed channel does not prevent the others from working.

**Identify gateway** blinks all available status channels slowly for five seconds,
rejects overlapping requests and then resumes the *current* normal patterns, not
an old brightness snapshot. Identify requires all three channels to be controllable.

## Fixed button gestures

Actions occur only on release after a known uninterrupted press:

| Hold duration | Feedback while held | Release action |
| --- | --- | --- |
| Under 2 s | Normal | Identify for 5 s |
| 2–under 5 s | Normal | Nothing |
| 5–under 25 s | RUN slow | Reboot |
| 25–under 30 s | USER2 fast | Reboot |
| 30 s or longer | All fast | Factory-reset request |

Discovery matches `gpio-keys` and KEY_PROG1, not an event-device number. The first
release after startup/reconnection/input loss only arms the button. This prevents
the input library's initial held-key snapshot from becoming a recovery gesture.
There is a 50 ms debounce interval; shorter presses are ignored. Duplicates and
repeats do not extend a press. Disconnect, reader exit, invalid key values and
SYN_DROPPED disarm it. A dropped-event report invalidates the entire batch.
Durations use monotonic receipt time; the input library does not retain kernel
event timestamps. Device-level bounce/loss/timing qualification remains necessary.

Button feedback takes priority over Identify, which takes priority over normal
patterns. There are no configurable button modes and no web reboot/reset action.

## Recovery

Recovery runs outside the LED loop in one worker, with a 15-second deadline.
There is no automatic retry, and only one recovery attempt is accepted per
Indicators instance. The host adapter additionally records only one attempt per
simulator lifetime. The EC100 adapter latches its attempt for the VM lifetime
and uses `Nerves.Runtime.reboot/0`. A timeout is an unknown outcome, not proof that
an independent OS shutdown stopped. Failure appears in Settings, status and USER2.

**EC100 factory reset deletes everything in `/root` (`/data`)**, including
software credentials, Tailscale identity, network settings and persistent shell
history. It does not change GPT, firmware slots, U-Boot, its environment or
hardware identity. Network access may disappear; keep local serial recovery.

The adapter blocks SSH firmware uploads, stops application writers, Tailscale,
VintageNet, SSH and time persistence, closes shell history, leaves the data working
directory, and normally unmounts every mount of the data partition. Shell history
remains persistent across ordinary reboots; it is disabled only during reset.
RingLogger is in-memory. Busy mounts abort reset—no lazy or forced unmount.
After **any** admitted SSH upload (even a failed one), recovery requires a reboot,
so reset cannot race an update or its delayed reboot callback.

Only after unmount readback does it call `Nerves.Runtime.FwupOps.factory_reset()`
with the default immediate reboot. The BSP invalidates the first 128 KiB; Nerves
reformats the actual expanded partition on the next boot. The Nerves initialization
hook requires `/root` to be the expected partition mounted read-write as ext4.
Runtime starts before data users with a fatal-on-error boot mode, so failed format
or mount cannot silently start services. No custom formatter or reset journal.

Failure leaves services stopped; no cleanup, remount, graceful shutdown or retry
is requested after invalidation. USER2 reports failure; Settings remains readable
only if connectivity survives writer shutdown. A timeout is an unknown outcome.
Host simulation records reset followed by reboot only on success.

This is a logical reset, **not secure erasure**; old blocks may remain recoverable.
Hardware qualification remains pending: expanded p3, busy mounts and I/O failures,
power cuts during invalidation/reformatting, usable empty storage after boot, and
unchanged firmware/identity. Nothing here erases or reboots a workstation.

For host button preview in IEx, release once, wait at least 50 ms, then press and
release with `NervesGate.Indicators.Host.button(0)` / `.button(1)`. Inspect
`NervesGate.Indicators.Host.snapshot(NervesGate.Indicators.Host).recoveries` to see
simulated recovery actions. Restart the preview to clear its one-shot attempt.
