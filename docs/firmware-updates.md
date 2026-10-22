# Firmware builds and device updates

Run `mix dev`. No shell target variables are required. This workbench performs
normal SSH A/B firmware updates, not initial provisioning, SD-card flashing or
factory resets. Finding or adding a device never writes to it.

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
