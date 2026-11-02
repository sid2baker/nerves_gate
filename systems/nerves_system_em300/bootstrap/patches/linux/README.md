# Local kernel patches

These patches were developed on the EC100, which shares the EM300's SoC, USB
wiring style and Quectel modem, with the pinned Armbian Rockchip 6.12 kernel.
They are not all confirmed mainline Linux bugs. Patch 0001 tracks an upstream
fix with local additions; 0002 bundles downstream EC100 workarounds; 0003
identifies the board's cellular modem; 0004 quiets a USB PHY probe error.
Retain upstream fixes until our pinned kernel includes them, not merely until
their PRs merge.

## Shared patch maintenance

Kernel patches 0001–0003 and the Buildroot patches match EC100's copies.
Patch 0004 is EM300-only until EC100 is qualified with it. Keep fixes in
sync deliberately, not through a shared board framework. Review both systems
when changing one, and document any intentional divergence. The comparison
commands are in the [EC100 patch notes](../../../../nerves_system_ec100/bootstrap/patches/linux/README.md#shared-patch-maintenance).
U-Boot environment patches intentionally differ. A shared patch does not imply
EM300 hardware qualification.

## 0001 — Keep the Type-C port in device mode

[Patch](0001-phy-initialize-fixed-peripheral-mode.patch): the PHY can select host
mode from the ID signal even when configured as a fixed peripheral. Initialize
it as a device and prevent ID-driven host-role changes at probe, in ID interrupts,
and on system resume. Resume retains ID bookkeeping, interrupt restoration,
BVALID handling and low-power exit. This does not fake VBUS presence.

Upstream: [PR #578](https://github.com/armbian/linux-rockchip/pull/578), including
the resume guard from commit `6fbfc77aa909`. The PR contains a smaller ID-based
role fix; this local patch also includes explicit device-mode initialization,
forced device ID and VBUS-detector error propagation. The PR merged into the
6.1 branch only; 6.12 still lacks it. Keep the patch until the pinned kernel
includes the upstream fix, then reassess the local additions before removing
it. The 6.12 port renames the resume bookkeeping field to `prev_utmi_id`; the
guard is otherwise unchanged. The resume guard still needs hardware validation; the
broader local patch does not qualify the exact upstream patch.

## 0002 — DWC2 gadget workarounds

[Patch](0002-usb-dwc2-ec100-workarounds.patch): combines the previous reset and
bulk OUT patches without changing kernel behavior. Both are retained to preserve
the working EC100 USB stack, with separate rationales and validation limits.
These are downstream workarounds, not two proven generic DWC2 fixes.

### Reinitialize USB after reconnect

On the EC100 debug/download connector, PHY BVALID and DWC2 BSESVLD remain low
even during successful gadget traffic. After reconnect, DWC2 can leave EP0
(the USB control endpoint) inactive because reset handling skips
reinitialization. Allow a received bus reset to reinitialize a previously
connected fixed peripheral; leave OTG behavior alone. This does not fake VBUS
presence or make unplug report a session disconnect.

Reconnect tests passed with this workaround, but boot-connected stalls remain
a separate observation, not necessarily a separate root cause.
[Closed RFC #579](https://github.com/armbian/linux-rockchip/pull/579) records the
unresolved choice of fix location (DWC2 or PHY/session signaling).

### Ask the host to wait for a receive buffer (experimental)

Start bulk OUT endpoints in NAK ("not ready; retry") until a receive request is
armed. This is a small defensive candidate for the stall associated with early
host traffic, retained as part of the working local stack.

**Not a proven fix:** the candidate passed USB SSH/ping, but that boot received
bulk traffic late and did not exercise the failing early-traffic sequence. An
unguarded late-traffic test also passed. Missing session-valid signaling does
not establish that this guard is necessary.

[Closed experimental PR #580](https://github.com/armbian/linux-rockchip/pull/580)
records the untested early-traffic hypothesis. Combining the patches does not
establish a shared root cause or prove that either change is sufficient alone.

## 0003 — Keep the cellular modem separate from USB recovery

[Patch](0003-net-cdc_ether-quectel-eg800ak-wwan.patch): matches the Quectel
EG800AK's `2c7c:6002` CDC-ECM interface before the generic CDC Ethernet entry
and selects `wwan_info`. The kernel then assigns `wwan%d` (`wwan0` for the
board's single modem), leaving `usb0` for the Type-C setup/recovery gadget.
Serial interfaces keep their existing `option` driver binding.

This is a downstream-only device-ID addition, not an upstream fix. The pinned
kernel has no matching Quectel ECM entry. Modem identity and ECM mode were
confirmed on factory firmware; naming and operation under this system still
need hardware validation.

## 0004 — Optional shared USB PHY interrupt

[Patch](0004-phy-use-optional-shared-usb-irq.patch): RK3506 uses per-port
interrupts. Request the absent shared interrupt with the optional API rather
than printing an error on a supported path. Preserve probe deferral.

## EM300 status

Nerves boots on EM300; USB SSH and modem enumeration as `wwan0` have been
observed. Resume, USB reconnect stress and modem data operation remain
unqualified. These observations predate the 6.12 kernel; the EM300 has not
booted 6.12 yet.

## Other retained boot diagnostics

Do not add fictional device-tree resources to hide these vendor diagnostics:

- CAN has no RX DMA mapping; the driver uses its interrupt/FIFO path (`use_dma=0`).
- The SD host has a default pinctrl state but no separate `normal`/`idle` states;
  it retains the default mux instead of switching runtime pinctrl states.
- Ethernet uses RMII with PHY-supplied clocks. RGMII TX/RX delays are irrelevant;
  the shared vendor driver also requests optional clocks not exposed by RK3506.
  Both ports have established 100 Mbps links; field qualification is separate.
- Fixed power rails without software-controlled supplies use dummy regulators.
- `mtdblock` warns when the raw redundant U-Boot environment is opened. This is
  not a failed write or evidence of corruption. Moving it to UBI would break
  the bootloader/storage contract; do not migrate or erase an installed device
  to suppress this diagnostic. NAND environment durability and A/B rollback
  still require qualification.
