# Firmware builds and device updates

The Workbench separates reviewed SSH A/B updates from destructive initial EC100
provisioning over USB. Finding or connecting a gateway never authorizes a write.

## Build

On **Develop → Firmware**, choose EC100 or x86_64 and build. Builds run in an
isolated process, never flash hardware, and show the resulting `.fw` path.
Alternatively run `mix firmware ec100` or `mix firmware x86_64` at the root.
See [system releases](releases.md#systems) for local system builds.

## Reviewed EC100 update

1. On **Devices**, select a verified connected physical gateway. Candidates connect
   over distribution with development cookie `mycookie`; disconnected entries show
   their last-seen time. Adding an address does not upload anything.
2. On the gateway page, select an EC100 image and request a review. Review privately
   snapshots the exact archive, checks platform/product/architecture and full build
   revision, reads identity and health over distribution, checks saved immutable
   plugin artifacts against the image, and verifies SSH trust/authentication.
3. Compare the gateway address, serial, versions and SHA-256. Type the exact
   reviewed address to confirm. Reviews expire after ten minutes, are invalidated
   by another job, and are consumed once.
4. Confirmation rechecks the snapshot, boot identity, health and plugin metadata.
   The standard SSH `fwup` subsystem receives the image once. No uncertain upload
   is retried.
5. After acceptance, read-only distribution probes wait up to three minutes for a
   different boot ID of the same serial, the exact reviewed version/source revision,
   validated firmware and healthy state without a pending trial or recovery.
   Acceptance alone is not successful verification. If access does not return,
   inspect the gateway; never upload again automatically.

Unsupported firmware fails explicitly. There is no legacy identity protocol,
manual-verification downgrade or alternate transport fallback. An update changes
firmware, not saved plugin selection or hardware assignments. Changed plugin bytes
require a new version; never erase saved metadata to bypass a conflict.

`mix firmware.update GATEWAY [IMAGE] [--sha256 SHA]` and the `firmware-update` Pi
skill use the same `Workbench.Jobs` review/confirmation path on the attached
Workbench node. The task also prints read-only gateway state before and after. It requires explicit user authorization;
inspection, building or discovery is not authorization to flash.

## Physical checks

The gateway page offers the separate `Scenarios.physical/0` catalogue: readiness,
operator-assisted Ethernet/4G failover, and physical-button reboot observation.
These run one at a time through Jobs, not the QEMU catalogue. Management must stay
independent from the link under test. The operator unplugs/restores Ethernet or
presses the button; the Workbench sends no physical reboot or switch command.
Never hold the button for a reset while testing reboot. Follow
[LEDs and button](indicators.md) for exact device-side semantics.

Gateway configuration and restore belong to the gateway's own UI. Reconnection
never replays network configuration, enrollment, credentials or writes.

## SSH access

Firmware uploads authenticate as `nerves_gate` with a public key and require the
host's key in `~/.ssh/known_hosts` under the exact reviewed address. Unknown or
changed keys are rejected, never saved automatically. With `SSH_AUTH_SOCK`, OTP
uses that agent; otherwise it uses standard key files in `~/.ssh`. Interactive
passphrase/password prompts are unsupported.

This is OTP SSH, not OpenSSH: `~/.ssh/config`, proxies, jump hosts, per-host identity
settings and hashed known-host entries are not supported. Use a directly reachable
address on port 22. Distribution handles inspection and post-update verification;
SSH is not a generic remote-evaluation or diagnostics protocol.

## Initial USB factory provisioning

**Provision** (`/provision`) replaces the EC100 bootloader, partition layout,
firmware and data. It needs separate explicit authorization. Normal A/B updates
do not require this procedure.

1. Build EC100 firmware. Install `rkdeveloptool` and provide USB access with udev
   or explicitly selected noninteractive `sudo -n` after `sudo -v`. The UI never
   stores or requests a sudo password.
2. Identify the intended board, connect its Type-C download port and enter MASKROM
   per the board instructions. Disconnect other Rockchip devices; keep stable
   power. The FTDI UART is not the flashing link.
3. Select the image/backup mode and load RAM transport for review. This checks for
   exactly one RK3506, privately snapshots image/boot inputs, loads RAM transport,
   reads eMMC capacity and checks disk space. It does not write eMMC.
4. Check USB location, image hash/version, capacity, backup mode and artifact path.
   A full eMMC backup defaults on. Required free space is three times capacity with
   backup, twice without, plus firmware size and 256 MiB.
5. Acknowledge the physical board and type `ERASE EC100 <USB location>` (plus
   ` WITHOUT BACKUP` when skipping backup). Confirmation is one-use and expires.
   The shared flash engine backs up if selected, writes, and reads back every
   region. Readback verification is mandatory; boot0/boot1 are untouched.
6. Reset occurs only after all readbacks pass. This proves the storage write, not
   a healthy firmware boot. After the board joins the network it can appear in the
   verified directory. Check its identity and health separately; no browser/USB
   reconnect heuristic is used as proof.

Backups, checksums and readbacks remain outside the checkout, normally under
`~/.local/share/nerves_gate/ec100-backups/`, including after failure. The review
shows the exact path; hosts may set `:nerves_gate_workbench, :backup_directory`.
Keep the original backup: a later attempt may back up partially written contents.
Old backup directories are never moved, deleted or uploaded automatically.

### Safety and troubleshooting

- USB VID/PID/location identify a controller, not a verified EC100 serial. Never
  swap boards, disconnect or run another flasher during an operation.
- Location and capacity are rechecked before installation and every write/reset.
  RAM readiness requires a fresh flash-info query, not a `Maskrom` label.
- Interrupted writes have unknown outcomes. Nothing is automatically replayed.
  Re-enter MASKROM and inspect before a new separately authorized review.
- MuonTrap owns firmware subprocesses and deadlines. Timeout, overflow or lost
  exit status never means success. Recovery files stay visible after failure.
- `Creating Comm Object failed` can mean missing USB permissions even when device
  listing works. Fix udev access or choose sudo; close other flashers.
- Never replay commands from expired `_build/factory-reviews/` snapshots.

The terminal equivalent is `MIX_TARGET=ec100 mix ec100.flash` in `firmware/`.
