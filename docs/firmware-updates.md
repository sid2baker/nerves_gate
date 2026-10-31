# Firmware builds and device updates

The Workbench separates reviewed SSH A/B updates from destructive initial EC100
provisioning over USB. Finding or connecting a gateway never authorizes a write.

## Build

On **Develop → Firmware**, choose EC100 or x86_64 and build. Builds run in an
isolated process, never flash hardware, and show the resulting `.fw` path.
Alternatively run `mix firmware ec100`, `mix firmware em300` or `mix firmware x86_64`
at the root. EM300 builds need the locally built, unpublished
`nerves_system_em300` artifact (see `systems/nerves_system_em300/README.md`).
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

Firmware uploads authenticate as `nerves_gate` with a public key authorized in the
gateway's **Settings → SSH keys**. Review reads the SHA-256 fingerprints of the
host keys the gateway's SSH daemon serves over the already authenticated
distribution connection and pins them for that review; any other presented host
key is rejected. `~/.ssh/known_hosts` is neither read nor written, so a factory
reset's new host key needs no manual trust step. Firmware that cannot report its
host keys is rejected; update it once through an explicitly authorized external
procedure. With `SSH_AUTH_SOCK`, OTP uses that agent; otherwise it uses standard
key files in `~/.ssh`. Interactive passphrase/password prompts are unsupported.

This is OTP SSH, not OpenSSH: `~/.ssh/config`, proxies, jump hosts and per-host
identity settings are not supported. Use a directly reachable
address on port 22. Distribution handles inspection and post-update verification;
SSH is not a generic remote-evaluation or diagnostics protocol.

An explicitly authorized manual OpenSSH upload (after verifying the host key) is:

```sh
cat firmware/_build/ec100_dev/nerves/images/nerves_gate.fw | ssh -F /dev/null -s nerves_gate@GATEWAY fwup
```

`-F /dev/null` keeps OpenSSH from sending `SendEnv` variables: the gateway's OTP
SSH server answers an `env` request by starting its shell handler and then refuses
the `fwup` subsystem ("subsystem request failed on channel 0"). A successful
upload reboots into the new slot; verify the new boot before any further update.

## Initial USB factory provisioning

**Provision** (`/provision`) replaces the bootloader, storage layout, firmware and
data of a physical EC100 (eMMC) or EM300 (SPI NAND). It needs separate explicit
authorization. Normal A/B updates do not require this procedure.

Both boards enumerate as the same RK3506, so USB cannot tell them apart. The
selected image's `meta-platform` chooses the board: its boot artifacts, accepted
capacity range and flash engine (`ec100.flash` or `em300.flash` from the board's
system). The board name is part of the erase confirmation.

1. Build firmware for the board. Install `rkdeveloptool` and provide USB access
   with udev or explicitly selected noninteractive `sudo -n` after `sudo -v`. The
   UI never stores or requests a sudo password. EM300 staging also needs
   `ubinize` (mtd-utils).
2. Identify the intended board and enter MASKROM: EC100 through its Type-C
   download port per the board instructions; EM300 by holding the LOADER key while
   applying power, then connecting USB-C. Disconnect other Rockchip devices; keep
   stable power. A serial UART is not the flashing link.
3. Select the image/backup mode and load RAM transport for review. This checks for
   exactly one RK3506, privately snapshots image/boot inputs, loads RAM transport,
   reads the flash capacity (EC100 eMMC range, or exactly the EM300's 512 MiB NAND)
   and checks disk space. It does not write flash.
4. Check board, USB location, image hash/version, capacity, backup mode and
   artifact path. A full flash backup defaults on. Required free space is three
   times capacity with backup, twice without, plus firmware size and 256 MiB.
5. Acknowledge the physical board and type `ERASE <BOARD> <USB location>` (plus
   ` WITHOUT BACKUP` when skipping backup). Confirmation is one-use and expires.
   The board's flash engine backs up if selected, writes, and reads back every
   region. Readback verification is mandatory. EC100 leaves eMMC boot0/boot1
   untouched; EM300 erases the entire NAND (including the vendor system and
   vendor-storage area) before writing the IDB loader, GPT, U-Boot, kernel slot A,
   the UBI image and the environment. Identity and capacity are rechecked before
   every device-changing command.
6. Reset occurs only after all readbacks pass. This proves the storage write, not
   a healthy firmware boot. After the board joins the network it can appear in the
   verified directory. Check its identity and health separately; no browser/USB
   reconnect heuristic is used as proof.

Backups, checksums and readbacks remain outside the checkout, normally under
`~/.local/share/nerves_gate/<board>-backups/` (`ec100-backups`, `em300-backups`),
including after failure. The review
shows the exact path; hosts may set `:nerves_gate_workbench, :backup_directory`.
Keep the original backup: a later attempt may back up partially written contents.
Old backup directories are never moved, deleted or uploaded automatically.

### Safety and troubleshooting

- USB VID/PID/location identify a controller, not a verified board or serial. Never
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
