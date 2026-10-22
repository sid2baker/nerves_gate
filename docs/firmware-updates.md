# Firmware builds and device updates

Run `mix dev`. No shell target variables are required. The workbench separates
normal SSH A/B updates from destructive initial EC100 provisioning over USB
MASKROM. Neither finding a device nor opening a page writes to it. SD-card
flashing and factory reset are not offered.

## Build

On the **Firmware** page, choose **EC100 physical controller** or
**x86_64 QEMU**, then **Build firmware**. Builds run in an isolated process and
never flash hardware. The result shows the `.fw` path.

EC100 builds require the fingerprinted EC100 system `0.3.0` artifact from
`system-ec100/v0.3.0`. Builds cannot complete until that release is published.
System maintainers can build changed systems locally with the standard Nerves 2
artifact task; see [system releases](releases.md#systems). You can also review a
previously built compatible EC100 `.fw` file. Do not substitute a QEMU image or
silently upload an old file when a new build fails.

## Review and explicitly update

1. On **Devices**, add the device's **hostname or IPv4 address**, including a
   Tailscale DNS name. This saves an unverified entry; it does not connect or
   configure the VPN.
2. Open that device and its **Firmware** tab. Choose an image from the dropdown.
   It lists compatible EC100 archives in `firmware/_build/ec100_*/nerves/images/`
   with their actual firmware versions. Use **Refresh firmware list** after a
   build. SSH uses fixed port **22**; the selected device fixes the destination.
3. Select **Review firmware and device**. This checks archive integrity, copies
   the selected bytes into a private immutable review snapshot, verifies the
   SSH host key and reads the device's public identity/version. It sends no
   firmware and does not reboot the device.
4. Check the hostname, target, serial, current/new versions and SHA-256. The
   archive product and platform must match the authenticated Nerves Gate device.
5. Type the exact reviewed hostname/address and select **Update firmware and
   reboot**. This is the explicit authorization to write firmware. Keep power
   connected. The snapshot is rechecked and device identity re-read before the
   standard SSH `fwup` subsystem is opened.
6. A successful transfer means the device accepted the image and will reboot;
   it does not prove that the new firmware booted healthy. Reconnect and verify
   its running version. Inspect the device before retrying any timeout or
   ambiguous failure. No automatic upload retries occur.

A review expires after ten minutes and is invalidated by a new operation.
Confirmation is single-use. The snapshot is deleted after update or expiry.
Nothing formats the physical device's data partition or bypasses its own
recovery/update admission and fwup compatibility checks.

## Initial USB factory provisioning

Use **Firmware → Factory provisioning** (`/factory`) only for initial installation
or explicit factory re-provisioning. It replaces the EC100 bootloader, partition
layout, firmware and application data. For an already provisioned device, prefer
the normal SSH update above; that also works over USB networking.

1. Build EC100 firmware. Install `rkdeveloptool` and arrange USB permissions on
   the workstation hosting `mix dev`, not the browser's machine. Use direct udev
   access or select noninteractive `sudo -n` after authorizing it in a terminal
   (`sudo -v`). No password is requested or stored by the UI. Sudo policy may
   require explicit permission for noninteractive commands from the workbench.
2. Physically identify the intended EC100, connect its Type-C download port, and
   enter MASKROM according to the board instructions. Follow the watchdog-jumper
   instructions and keep stable power connected. Disconnect other Rockchip USB
   devices. The FTDI UART adapter is a console, not the flashing connection.
3. Choose the image and click **Load RAM transport and review**. This is an
   explicit device operation: it checks exactly one matching RK3506 controller,
   verifies/snapshots the image and boot files, loads the transport into RAM,
   reads eMMC capacity and checks disk space. It does not write eMMC.
4. Review the USB location, image hash/version, capacity and backup directory.
   The disk budget conservatively reserves three times eMMC capacity plus the
   firmware size and 256 MiB for backup, staging and readbacks. A typical 4 GB
   board needs roughly 12 GB free. Space is checked again before installation.
5. Check the physical-EC100 acknowledgement and type the exact displayed
   `ERASE EC100 <USB location>` phrase. Click **Back up, erase and provision EC100**.
   The existing `ec100.flash` engine stages/validates the factory layout, completes
   and hashes the full eMMC user-area backup, then writes and reads back every
   region. Backup cannot be disabled in the UI. Boot0/boot1 are not written.
6. The EC100 resets only after all readback checks pass. The global operation
   panel shows progress across pages. Keep `mix dev`, USB and power connected
   until completion. Backups, their checksum and readbacks remain under
   `ec100-backups/`, including after failure. Copy them somewhere safe.

The USB VID/PID identifies the controller, **not a verified EC100 serial number**.
The review is bound to the USB location and capacity, but cannot distinguish a
replacement board at the same location. Never unplug/swap devices or run another
flasher during the operation. The backend rechecks location and capacity before
installation and location before every write/reset. The review expires after ten
minutes, is invalidated by another operation, and is consumed once before flashing.
After expiry, cancellation or failure, re-enter MASKROM before reviewing again.

Factory provisioning is not power-loss atomic. An interrupted command has an
uncertain outcome: inspect the device and preserve backups; there are no automatic
write retries. Backup completion is checked before the first write, but a backup
is not a guarantee that interrupted provisioning can be recovered automatically.
The equivalent terminal workflow remains `MIX_TARGET=ec100 mix ec100.flash` from
`firmware/`; the UI calls its shared staging/backup/readback functions, not the
interactive Mix task. No system artifact rebuild is needed for this host feature.

## Read device information

A manual entry initially stores only its hostname/address. On the device's
Overview tab, **Read device information** fetches target, running firmware version,
architecture and serial over verified SSH on port 22. It sends no firmware and
never opens the update subsystem or reboots the device. Successful observations
are retained for the session with a timestamp; they are not a live connection.
Firmware review also refreshes this information. Both actions use the same SSH
credentials and host-key checks below. LAN mDNS generally does not cross Tailscale.

## SSH access

Updates and information reads use `nerves_gate` public-key authentication and
require the requested hostname/address to have a verified host key in the
workstation user's `~/.ssh/known_hosts`. The hostname is preserved for this check,
not replaced by its resolved IP. Unknown/changed host
keys are rejected; they are never accepted automatically or saved by the
workbench. Verify a new fingerprint using a trusted device connection before
accepting it in your SSH client.

When `SSH_AUTH_SOCK` is available, OTP's standard SSH agent callback signs through
that agent; load the authorized key into it (for example with `ssh-add`). Without
an agent, OTP uses standard key files in `~/.ssh`. Private keys are not copied to
the device, workbench projections or logs. Password/passphrase prompts are not
supported; USB password recovery remains a separate manual operation.

This is a direct SSH connection, not an OpenSSH subprocess: custom OpenSSH proxy
commands, jump-host rules, `IdentityAgent` and per-host identity-file settings are
not imported. Set `SSH_AUTH_SOCK` to the agent your terminal uses. Known-hosts
parsing is provided by OTP; hashed OpenSSH host entries are not supported.
Use a directly reachable hostname/IP and an authorized key. The device UI uses
standard SSH port 22; the lower-level review API still accepts an explicit port.
