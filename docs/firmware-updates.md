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
3. Choose the image and backup mode, then click **Load RAM transport and review**.
   A full eMMC backup is enabled by default. **Skip full backup** explicitly opts
   out: this run will not preserve the previous firmware/data. Keep any original
   backup safe. Review checks exactly one matching RK3506 controller, snapshots
   the image and boot files, loads the transport into RAM, reads eMMC capacity and
   checks disk space. It does not write eMMC.
4. Review the USB location, image hash/version, capacity, backup mode and artifact
   directory. The conservative disk budget is three times eMMC capacity with backup,
   or twice without, plus firmware size and 256 MiB for staging/readbacks. A typical
   4 GB board needs roughly 12 GB or 8 GB free respectively. Space is checked again
   before installation. This selection is fixed by the review, not confirmation fields.
5. Check the physical-EC100 acknowledgement and type the exact displayed phrase:
   `ERASE EC100 <USB location>`, or `ERASE EC100 <USB location> WITHOUT BACKUP` when
   skipping. Confirm provisioning. The shared `ec100.flash` engine stages/validates
   the factory layout, completes and hashes the full backup if enabled, then writes
   and reads back every region. Skipping backup never disables readback verification.
   Boot0/boot1 are not written.
6. The EC100 resets only after all readback checks pass. The workbench then waits
   up to three minutes for the reviewed USB port to return with USB Ethernet and
   DHCP, and reads the gateway's existing Settings page. Matching firmware, target
   and runtime information appear in the operation panel and Devices directory,
   with links to open the gateway or its device information. Keep `mix dev`, USB and
   power connected until completion. Backups (when enabled), checksums and readbacks
   remain under `ec100-backups/`, including after failure. Copy them somewhere safe.

The USB VID/PID identifies the controller, **not a verified EC100 serial number**.
The review is bound to the USB location and capacity, but cannot distinguish a
replacement board at the same location. Never unplug/swap devices or run another
flasher during the operation. The backend rechecks location and capacity before
installation and location before every write/reset. A working RK3506 RAM transport
may still be labelled `Maskrom` by `rkdeveloptool ld`; the label alone does not
prove readiness or failure. The backend verifies one matching controller at the
reviewed location before and after a successful read-only flash-info query, and
requires unchanged capacity before every write/reset. An actual ROM-only device
that cannot answer flash-info is rejected. No download or write is retried.
The review expires after ten minutes, is invalidated by another operation, and is
consumed once before flashing.
After expiry, cancellation or failure, re-enter MASKROM before reviewing again.

USB reconnection is a read-only Linux-host operation. Review captures the full
sysfs USB topology; after reset, only an active, non-overlapping /30 Ethernet link
on that exact port is eligible. The host checks a direct, gateway-free kernel
route and binds HTTP to the USB source address; it does not choose a LAN mDNS
advertisement, change DHCP/routes/VPN, send credentials or accept SSH host keys.
The workstation must already accept DHCP on the USB interface. Firmware must
report the reviewed version and `ec100` target. Only firmware, target and runtime
text is retained; private HTML, session tokens and key listings are discarded.
This is a timestamped USB HTTP observation, not authenticated SSH identity or a
persistent live connection. If topology cannot be tracked, the review warns that
manual connection will be needed. A reconnect timeout or worker failure after
verified reset is shown separately from the successful flash; it never replays a
write/reset. Operations already in flight are not retroactively changed.

A failed review removes its private temporary artifacts. Never replay a command
using an old `_build/factory-reviews/` path. The UI reports RAM transport loading
as a progress step rather than a reusable shell command, verifies the staged
loader immediately before download, and displays failures as alerts.
`Creating Comm Object failed` means the loader opened but USB open/claim failed;
`rkdeveloptool ld` can list a device without permission to download to it. Check
udev read/write access or explicitly select the form's noninteractive sudo option
with appropriate workbench-process authorization, and close competing flashers.
The UI never changes USB permissions, escalates privileges or retries a download
automatically. `Opening loader failed` instead means rkdeveloptool could not read
or parse the loader; inspect the selected boot artifacts and tool installation.

Firmware/USB subprocesses use MuonTrap's containment wrapper with bounded
execution and a 64 MiB output window, read without stdin acknowledgements. This
avoids MuonTrap 1.x's short-command EPIPE acknowledgement race. Timeout, output
overflow or lost exit status never count as success and never replay a command.
Cancellation closes the wrapper's port so its owned command is terminated.
Worker failures report a fixed exit category without dumping private arguments;
the confirmed factory operation keeps its backup directory visible even if the
worker dies.

Factory provisioning is not power-loss atomic. An interrupted command has an
uncertain outcome: inspect the device and preserve backups; there are no automatic
write retries. Keep the original pre-provisioning backup: a backup from a later
attempt may already contain partially written firmware. When enabled, backup
completion is checked before the first write, but a backup is not a guarantee
that interrupted provisioning can be recovered automatically. Without a full
backup, readbacks cannot restore the previous contents.
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
