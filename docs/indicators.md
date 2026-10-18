# LEDs and physical button

One `NervesGate.Indicators` process owns LED policy, blink timing and button state.
EC100 uses standard Linux LED and input devices. Workstation UIs control the
device's indicators; QEMU has none.

## LEDs

| Channel | EC100 GPIO / sysfs name | Normal meaning |
| --- | --- | --- |
| RUN | GPIO1_A7 / `ec100:run` | Solid while Indicators runs; off on orderly shutdown |
| USER1 | GPIO1_A6 / `ec100:user1` | Off intentionally disconnected/unconfigured Tailscale; solid confirmed Internet + healthy Tailscale; slow connecting/unknown/debouncing; fast managed connectivity fault |
| USER2 | GPIO1_A4 / `ec100:user2` | Off no known alarms, slow warning/unknown alarm observations, fast critical fault |

Brightness 1 is on and 0 off. Slow is one cycle per second (500 ms per half-cycle);
fast is four (125 ms). RUN has no early-boot blink. A crashed VM can leave the last
output latched until reboot: LEDs are not an independent health monitor.

`network_restore_failed`, `led_restore_failed` and `recovery_failed` are immediate
errors. Availability faults become warnings after two continuous seconds and clear
on recovery. USER2 follows Alarmist severity, including dependency alarms; no alarms
means *no known alarms*, not proof of health.

Internet means VintageNet's per-interface `connection` on the permitted uplinks
(Ethernet/`br0` and optionally the modem), never USB or the global best connection.
Working 4G backup counts as Internet: USER1 can stay solid while USER2 warns about
backup use or unavailable cellular. Before ports are assigned, a unique Internet
candidate may show online without raising alarms. `:lan` is not Internet, and
missing observations are unknown.

USER1 is solid only with confirmed Internet, authenticated online Tailscale, no
Tailscale health warnings and no managed connectivity fault. Stopped or needs-login
is off; unknown is slow, never healthy.

Network, Remote and Alarmist events refresh policy; a five-second reconciliation
repairs missed events and retries unavailable LEDs. A monotonic 125 ms tick drives
blinks, and unchanged outputs are not rewritten. Only the three mapped binary LEDs
are used; active kernel triggers are left alone. A failed channel does not affect
the others.

**Identify gateway** blinks all status channels slowly for five seconds, rejects
overlapping requests and then resumes the *current* patterns. It requires all three
channels.

## Button gestures

Actions happen on release after a known, uninterrupted press:

| Hold duration | Feedback while held | Release action |
| --- | --- | --- |
| Under 2 s | Normal | Identify for 5 s |
| 2–under 5 s | Normal | Nothing |
| 5–under 25 s | RUN slow | Reboot |
| 25–under 30 s | USER2 fast | Reboot |
| 30 s or longer | All fast | Factory-reset request |

Discovery matches `gpio-keys` and KEY_PROG1, not an event-device number. The first
release after startup, reconnection or input loss only arms the button, so a key
already held at startup never triggers recovery. Presses shorter than the 50 ms
debounce are ignored; repeats do not extend a press. Disconnect, reader exit,
invalid key values and SYN_DROPPED disarm it, and a dropped-event report discards
the batch. Durations use monotonic receipt time.

Button feedback takes priority over Identify, which takes priority over normal
patterns. There are no button modes and no web reboot or reset.

## Recovery

Recovery runs in one worker outside the LED loop, with a 15-second deadline and no
retry. Each Indicators instance accepts one attempt; the EC100 adapter also latches
its attempt for the VM lifetime and reboots with `Nerves.Runtime.reboot/0`. A
timeout is an unknown outcome. Failure appears in Settings, status and USER2.

**EC100 factory reset deletes everything in `/root` (`/data`)**, including
credentials, Tailscale identity, network settings and shell history. It does not
change GPT, firmware slots, U-Boot, its environment or hardware identity. Network
access may disappear, so keep serial recovery.

The adapter blocks SSH firmware uploads; stops application writers, Tailscale,
VintageNet, SSH, time persistence and RingLogger persistence; closes shell history;
and unmounts every mount of the data partition. A busy mount aborts the reset; there
is no lazy or forced unmount. After **any** admitted SSH upload, even a failed one,
recovery requires a reboot, so reset cannot race an update.

Only after unmount readback does it call `Nerves.Runtime.FwupOps.factory_reset()`,
which reboots immediately. The BSP invalidates the first 128 KiB and Nerves
reformats the partition on the next boot. The initialization hook requires `/root`
to be the expected ext4 partition mounted read-write, and runtime starts before
data users in fatal-on-error mode, so a failed format or mount cannot silently start
services.

After a failure, services stay stopped and nothing is retried. USER2 reports it;
Settings stays readable only if connectivity survived. This is a logical reset,
**not secure erasure**: old blocks may remain recoverable.
