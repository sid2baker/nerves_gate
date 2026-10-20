# Boot images

The eMMC boot chain is:

```text
BootROM → DDR initializer → SPL → secure firmware → U-Boot → Linux → Nerves
```

DDR 750 MHz v1.08, SPL v1.12, standard TEE v2.50, and USB plug v1.04 come from
pinned Rockchip `rkbin` binaries. U-Boot is compiled from the Rockchip BSP.
See [../SOURCES.md](../SOURCES.md) for source revisions.

## Packaging

`post-image.sh` verifies inputs against `rkbin.sha256` and produces:

| File | Purpose | eMMC byte offset |
| --- | --- | ---: |
| `idbloader.img` | DDR initializer and SPL | `0x00008000` |
| `u-boot.itb` | U-Boot, TEE, and bootloader device tree | `0x00800000` |
| `ec100-maskrom-loader.bin` | Temporary USB flashing transport | RAM only |
| `bootloader.sha256` | Output checksums | Not flashed |

The pinned vendor DDR parameter tool applies `ddrbin-param.txt` to configure
115200-baud UART output without changing memory-training parameters. Packaging
uses a fixed version label and verifies the decoded parameters.

Factory installation writes the persistent boot images. Normal OTA updates do
not replace them. The USB transport is never installed as an eMMC boot image.

## Memory layout

| Image | Load address |
| --- | ---: |
| TEE | `0x00001000` |
| U-Boot | `0x00200000` |
| Linux kernel | `0x02080000` |
| Linux device tree | `0x06000000` |
| Kernel FIT read buffer | `0x08000000` |

Linux reserves `trust@0` at base 0, size `0x62000`. Dynamic TEE-memory tags are
optional. The TEE binary is packaged intact.

## U-Boot integration

`patches/uboot/` adapts the BSP for redundant MMC environments, env-backed
bootcount, current compilers, and Buildroot's TEE input. Missing or invalid
factory environments must not fall back to Android boot policy.

`uboot.env` defines A/B selection. Environment copies occupy 128 KiB each at
`0x00c00000` and `0x00c20000`. `fwup.conf` initializes both copies; `fwup-ops.conf`
implements validation and revert operations.

Use `$name` for U-Boot variable references in the environment template; fwup
expands `${name}` during archive application. Slot booting stops if an MMC read
fails. `altbootcmd=run bootcmd` invokes the rollback policy after the boot limit.

See [../README.md](../README.md) for installation, OTA, and storage layout.
