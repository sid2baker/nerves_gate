# Target system sources

The application uses the external EC100 checkout configured in `mix.exs`. Do not
copy it into this repository. Its bootloader, GPT layout and A/B update contract
remain owned by that system.

## x86_64

`x86_64/` is based on
[`nerves-project/nerves_system_x86_64`](https://github.com/nerves-project/nerves_system_x86_64)
commit `5d755dba94fff478eac2bfd90ba91d2e0025d4eb` (1.34.2). Upstream supports Nerves 2,
but its kernel lacks the bridge support this gateway requires.

The local changes are limited to:

- Built-in bridge, TUN and IPv4/IPv6 iptables support in `linux/gateway.fragment`.
- `bridge-utils`, `iptables` and a tar root filesystem for Nerves 2.
- A distinct artifact version (`1.34.2-gate.1`) and local artifact builds only.
- `nerves_system_br 1.34.5` (Buildroot 2026.05.3 / OTP 29.0.6), matching EC100
  instead of upstream's `1.35.0`. Mix resolves all targets into one lockfile;
  the system definitions must agree on shared dependency versions.

Bridge netfilter is disabled: ordinary Ethernet bridge traffic must not be
processed by the gateway's IP firewall. Merely enabling kernel features does not
enable routing, NAT or a DHCP server. Boot layout and firmware update tasks are
unchanged. Upstream licenses and source documentation are retained in the directory.

Build with the Erlang/OTP major version selected by the system:

```sh
MIX_TARGET=x86_64 mix deps.get
MIX_TARGET=x86_64 mix nerves.artifact.build nerves_system_x86_64
MIX_TARGET=x86_64 mix tailscale.install rootfs_overlay/x86_64/usr/sbin/tailscaled
MIX_TARGET=x86_64 mix firmware
```

**Not yet build- or boot-validated.** Host namespace bridge tests do not replace a
Nerves boot test. Do not publish or flash this variant as validated firmware.
