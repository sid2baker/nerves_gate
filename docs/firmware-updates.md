# Firmware builds and device updates

The workbench separates normal SSH A/B updates from destructive initial EC100
provisioning over USB. Finding a device or opening a page never writes to it.

## Build

On **Firmware**, choose **EC100 physical controller** or **x86_64 QEMU** and
**Build firmware**. Builds run in a separate process, never flash hardware, and
show the resulting `.fw` path. EC100 builds use the published EC100 system
artifact; see [system releases](releases.md#systems) for local system builds.

## Update over SSH

1. On **Devices**, add the gateway's hostname or IPv4 address (Tailscale DNS
   names work). This stores an unverified entry and connects nowhere.
2. On its **Firmware** tab, pick an image. The list shows EC100 archives in
   `firmware/_build/ec100_*/nerves/images/` with their real versions.
3. **Review firmware and device** checks the archive, snapshots it privately,
   verifies the SSH host key and reads the device's identity. It sends nothing.
4. Compare hostname, target, serial, versions and SHA-256. Product and platform
   must match the device.
5. Type the reviewed hostname/address and choose **Update firmware and reboot**.
   The snapshot and identity are rechecked before the standard SSH `fwup`
   subsystem receives the image.
6. Success means the device accepted the image and will reboot, not that it booted
   healthy. Reconnect and check its version. Nothing is retried automatically;
   inspect the device after a timeout or ambiguous failure.

Reviews expire after ten minutes, are invalidated by another operation and can be
confirmed once. The device's own fwup checks and data partition are untouched.

**Read device information** on a device's Overview tab performs the same verified
SSH identity read without a review. Results are kept for the session with a
timestamp; this is not a live connection.

### SSH access

Updates and reads authenticate as `nerves_gate` with a public key and require the
host's key in `~/.ssh/known_hosts` under the exact hostname you entered. Unknown or
changed host keys are rejected, never accepted or saved by the workbench. With
`SSH_AUTH_SOCK` set, OTP signs through that agent (`ssh-add` your key); otherwise
it uses the standard key files in `~/.ssh`. Passphrase prompts are unsupported.

This is OTP's SSH client, not OpenSSH: `~/.ssh/config` (proxies, jump hosts,
`IdentityAgent`, per-host identity files) and hashed known-hosts entries are not
supported. Use a directly reachable address on port 22.

## Initial USB factory provisioning

**Provision** (`/provision`) replaces the EC100 bootloader,
partition layout, firmware and data. Use it for initial installation or deliberate
re-provisioning; otherwise use the SSH update, which also works over USB networking.

1. Build EC100 firmware. On the workstation running `mix dev`, install
   `rkdeveloptool` and give it USB access, either through udev or by selecting
   noninteractive `sudo -n` after `sudo -v` in a terminal. The UI never asks for
   or stores a password.
2. Identify the intended EC100, connect its Type-C download port and enter
   MASKROM per the board instructions (watchdog jumper, stable power). Disconnect
   other Rockchip devices. The FTDI UART is a console, not the flashing link.
3. Choose the image and backup mode, then **Load RAM transport and review**. This
   checks for exactly one RK3506, snapshots the image and boot files, loads a RAM
   transport, reads eMMC capacity and checks disk space. It writes nothing.
4. Check the USB location, image hash and version, capacity, backup mode and
   artifact directory. A full eMMC backup is on by default; **Skip full backup**
   means the previous contents cannot be restored. Free space needed is three times
   eMMC capacity with backup, or twice without, plus firmware size and 256 MiB
   (about 12 GB or 8 GB for a 4 GB board).
5. Acknowledge the physical board and type the displayed phrase:
   `ERASE EC100 <USB location>`, plus ` WITHOUT BACKUP` when skipping it. The
   shared `ec100.flash` engine backs up (if enabled), then writes and reads back
   every region. Readback verification is never skipped; boot0/boot1 are untouched.
6. The board resets only after every readback passes. The workbench then waits up
   to three minutes for USB Ethernet on the same physical port and reads the
   gateway's Settings page to confirm firmware version and target. Keep `mix dev`,
   USB and power connected until it finishes.

Backups, checksums and readbacks stay in `ec100-backups/`, including after failure.
Copy them somewhere safe, and keep the **original** backup: a later attempt may
back up partially written contents.

### Safety limits

- USB VID/PID and location identify a controller, **not a verified EC100 serial**.
  Don't unplug, swap boards or run another flasher during an operation.
- Location and capacity are rechecked before installation and before every write
  or reset. A working RAM transport may still be listed as `Maskrom`; readiness is
  proven by a fresh flash-info query, not that label.
- Provisioning is not power-loss atomic. An interrupted run has an unknown outcome;
  nothing is retried automatically. Re-enter MASKROM before a new review.
- Reconnection is read-only. It uses only a direct, gateway-free route on the
  reviewed USB port, sends no credentials and changes no host networking; the
  workstation must already accept USB DHCP. A reconnect failure after a verified
  reset is reported separately and never replays writes.
- Firmware subprocesses run under MuonTrap with deadlines; timeouts, overflowed
  output or lost exit status never count as success.

### Troubleshooting

- `Creating Comm Object failed`: the loader is fine but USB open/claim failed.
  `rkdeveloptool ld` can list a device it cannot download to. Fix udev access or use
  the sudo option, and close other flashers.
- `Opening loader failed`: rkdeveloptool could not read the loader; check the boot
  artifacts and tool installation.
- Never replay a command from an old `_build/factory-reviews/` path; failed reviews
  delete their temporary files.

The terminal equivalent is `MIX_TARGET=ec100 mix ec100.flash` in `firmware/`.
