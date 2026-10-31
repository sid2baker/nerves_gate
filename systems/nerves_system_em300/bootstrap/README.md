# Boot images

The SPI NAND boot chain is:

```text
BootROM → DDR initializer → SPL → secure firmware → U-Boot → Linux → Nerves
```

DDR 750 MHz v1.08, SPL v1.12, standard TEE v2.50, and USB plug v1.04 come from
pinned Rockchip `rkbin` binaries. U-Boot is compiled from the Rockchip BSP with
SPI NAND support. See [../SOURCES.md](../SOURCES.md) for source revisions.

## Packaging

`post-image.sh` verifies inputs against `rkbin.sha256` and produces:

| File | Purpose | NAND location |
| --- | --- | --- |
| `em300-loader.bin` | Temporary MaskROM USB transport | RAM only |
| `em300-idblock.img` | DDR/SPL IDB, padded to two erase blocks per copy | Copies at 128 KiB and 384 KiB |
| `u-boot.itb` | U-Boot, TEE, and bootloader device tree | `uboot` (4 MiB) |
| `em300-parameter.txt` | Rockchip GPT definition, written by `rkdeveloptool gpt` | sector 0 / tail |
| `bootloader.sha256` | Output checksums | Not flashed |

The pinned vendor DDR parameter tool applies `ddrbin-param.txt` to configure
115200-baud UART output without changing memory-training parameters.

Factory installation writes GPT first, then two IDB copies with `wl` starting at
sector 256. Each copy occupies two 128 KiB erase blocks. The first erase block
belongs exclusively to GPT. Never use `ul`: it places the IDB at 32 KiB, where a
GPT write erases its header. Both copies are read back and checked before later
partition writes or reset. Normal OTA updates do not replace boot images.

## Memory layout

| Image | Load address |
| --- | ---: |
| TEE | `0x00001000` |
| U-Boot | `0x00200000` |
| Linux kernel | `0x02080000` |
| Linux device tree | `0x06000000` |
| Kernel FIT read buffer | `0x08000000` |

## U-Boot integration

The official SPL finds U-Boot through the GPT `uboot` partition. U-Boot reads
its environment through Rockchip's MTD block layer and the slot's kernel FIT
from a UBI volume (`ubi part ubi; ubi read`), the same `ubi0` Linux uses.

`patches/uboot/` adapts the BSP for a redundant block-device environment,
env-backed bootcount, current compilers, and Buildroot's TEE input. Missing or
invalid factory environments must not fall back to Android boot policy.

Environment copies occupy 128 KiB each at NAND offsets `0x00800000` and
`0x00820000` (the start of the `env` partition and the next erase block).
`fwup.conf` creates them (`factory-env`) and updates them through
`/dev/mtdblock2`; `fwup-ops.conf` implements validation and revert.

Use `$name` for U-Boot variable references in the environment template; fwup
expands `${name}` during archive application. `altbootcmd=run bootcmd` invokes
the rollback policy after the boot limit.
