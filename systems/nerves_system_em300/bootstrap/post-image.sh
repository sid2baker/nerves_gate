#!/bin/sh
# Package only factory boot artifacts. Normal .fw upgrade tasks never reference them.
set -eu
UBOOT="$BUILD_DIR/uboot-custom"
RKBIN="$BUILD_DIR/rockchip-rkbin-3e288fe814e059dd06833495f845cab04ac20a5c"
DDR="$BINARIES_DIR/rk3506_ddr_750MHz_v1.08_115200.bin"
DDR_SOURCE="$RKBIN/bin/rk35/rk3506_ddr_750MHz_v1.08.bin"
TEE_SOURCE="$RKBIN/bin/rk35/rk3506_tee_v2.50.bin"
DDR_TOOL="$RKBIN/tools/ddrbin_tool.py"
DDR_PARAMS="$(dirname "$0")/ddrbin-param.txt"
PARAMETER="$(dirname "$0")/parameter.txt"
INI="$RKBIN/RKBOOT/RK3506MINIALL.ini"
for file in "$UBOOT/scripts/spl.sh" "$INI" "$DDR_SOURCE" "$DDR_TOOL" "$DDR_PARAMS" "$TEE_SOURCE" "$PARAMETER"; do
    test -f "$file" || { echo "Missing factory input: $file" >&2; exit 1; }
done
CHECKSUMS="$(cd "$(dirname "$0")" && pwd)/rkbin.sha256"
(cd "$RKBIN" && sha256sum -c "$CHECKSUMS")
# Only change UART speed, preserving DDR training and wiring parameters. The fixed
# version label avoids the vendor tool's default wall-clock timestamp in artifacts.
cp "$DDR_SOURCE" "$DDR"
"$HOST_DIR/bin/python3" "$DDR_TOOL" rk3506 "$DDR_PARAMS" "$DDR" --ver_edit=em300-115200
rm -f "$BINARIES_DIR/ddrbin-params.txt"
"$HOST_DIR/bin/python3" "$DDR_TOOL" rk3506 -g "$BINARIES_DIR/ddrbin-params.txt" "$DDR"
# The vendor tool can exit zero on error; independently check the result.
grep -qx 'uart baudrate=115200' "$BINARIES_DIR/ddrbin-params.txt"
(
    cd "$RKBIN"
    # Override DDR UART metadata only; official INI retains official SPL/USB.
    "$UBOOT/scripts/spl.sh" --ini "$INI" --tpl "$DDR"
)
# USB transport and persistent NAND IDB are distinct artifacts. `ul` places the
# IDB at 32 KiB, inside the erase block used by GPT; never use it on this board.
LOADER=$(awk -F= '/^PATH=/{gsub(/\r/, "", $2); print $2}' "$INI")
test -n "$LOADER"
cp "$RKBIN/$LOADER" "$BINARIES_DIR/em300-loader.bin"
IDBLOCK=$(awk -F= '/^IDB_PATH=/{gsub(/\r/, "", $2); print $2}' "$INI")
test -n "$IDBLOCK"
cp "$RKBIN/$IDBLOCK" "$BINARIES_DIR/em300-idblock.img"
test "$(wc -c < "$BINARIES_DIR/em300-idblock.img")" -le 262144

# Official RKTRUST/RK3506TOS.ini specifies the secure firmware load address.
# Keep the vendor binary intact; do not strip headers or use source tee-raw.bin.
grep -qx 'ADDR=0x1000' "$RKBIN/RKTRUST/RK3506TOS.ini"
cp "$TEE_SOURCE" "$UBOOT/tee.bin"
(
    cd "$UBOOT"
    ./arch/arm/mach-rockchip/make_fit_optee.sh -t 0x1000 > u-boot-em300.its
    # BSP SPL rounds relative data-offset bases to 512 bytes, unlike modern
    # mkimage's 4-byte header alignment. Match BSP fit-core.sh: absolute positions.
    "$HOST_DIR/bin/mkimage" -f u-boot-em300.its -E -p 0x1400 u-boot.itb
    for node in uboot optee fdt; do
        "$HOST_DIR/bin/fdtget" u-boot.itb "/images/$node" data-position >/dev/null
    done
)
cp "$UBOOT/u-boot.itb" "$BINARIES_DIR/u-boot.itb"
# The uboot NAND partition is 4 MiB; leave room for bad-block skipping.
test "$(wc -c < "$BINARIES_DIR/u-boot.itb")" -le 3145728
cp "$PARAMETER" "$BINARIES_DIR/em300-parameter.txt"
(
    cd "$BINARIES_DIR"
    sha256sum em300-loader.bin em300-idblock.img u-boot.itb em300-parameter.txt > bootloader.sha256
)
