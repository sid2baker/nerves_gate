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
INI="$RKBIN/RKBOOT/RK3506MINIALL.ini"
for file in "$UBOOT/scripts/spl.sh" "$INI" "$DDR_SOURCE" "$DDR_TOOL" "$DDR_PARAMS" "$TEE_SOURCE"; do
    test -f "$file" || { echo "Missing factory input: $file" >&2; exit 1; }
done
CHECKSUMS="$(cd "$(dirname "$0")" && pwd)/rkbin.sha256"
(cd "$RKBIN" && sha256sum -c "$CHECKSUMS")
# Only change UART speed, preserving DDR training and wiring parameters. The fixed
# version label avoids the vendor tool's default wall-clock timestamp in artifacts.
cp "$DDR_SOURCE" "$DDR"
"$HOST_DIR/bin/python3" "$DDR_TOOL" rk3506 "$DDR_PARAMS" "$DDR" --ver_edit=ec100-115200
rm -f "$BINARIES_DIR/ddrbin-params.txt"
"$HOST_DIR/bin/python3" "$DDR_TOOL" rk3506 -g "$BINARIES_DIR/ddrbin-params.txt" "$DDR"
# The vendor tool can exit zero on error; independently check the result.
grep -qx 'uart baudrate=115200' "$BINARIES_DIR/ddrbin-params.txt"
(
    cd "$RKBIN"
    # Override DDR UART metadata only; official INI retains official SPL/USB.
    "$UBOOT/scripts/spl.sh" --ini "$INI" --tpl "$DDR"
)
IDB=$(awk -F= '/^IDB_PATH=/{gsub(/\r/, "", $2); print $2}' "$INI")
LOADER=$(awk -F= '/^PATH=/{gsub(/\r/, "", $2); print $2}' "$INI")
test -n "$IDB" && test -n "$LOADER"
cp "$RKBIN/$IDB" "$BINARIES_DIR/idbloader.img"
cp "$RKBIN/$LOADER" "$BINARIES_DIR/ec100-maskrom-loader.bin"

# Official RKTRUST/RK3506TOS.ini specifies the secure firmware load address.
# Keep the vendor binary intact; do not strip headers or use source tee-raw.bin.
grep -qx 'ADDR=0x1000' "$RKBIN/RKTRUST/RK3506TOS.ini"
cp "$TEE_SOURCE" "$UBOOT/tee.bin"
(
    cd "$UBOOT"
    ./arch/arm/mach-rockchip/make_fit_optee.sh -t 0x1000 > u-boot-ec100.its
    # BSP SPL rounds relative data-offset bases to 512 bytes, unlike modern
    # mkimage's 4-byte header alignment. Match BSP fit-core.sh: absolute positions.
    "$HOST_DIR/bin/mkimage" -f u-boot-ec100.its -E -p 0x1400 u-boot.itb
    for node in uboot optee fdt; do
        "$HOST_DIR/bin/fdtget" u-boot.itb "/images/$node" data-position >/dev/null
    done
)
cp "$UBOOT/u-boot.itb" "$BINARIES_DIR/u-boot.itb"
# IDB starts at LBA64; U-Boot at 8 MiB; redundant env starts at 12 MiB.
test "$(wc -c < "$BINARIES_DIR/idbloader.img")" -le 8355840
test "$(wc -c < "$BINARIES_DIR/u-boot.itb")" -le 4194304
(
    cd "$BINARIES_DIR"
    sha256sum idbloader.img u-boot.itb ec100-maskrom-loader.bin > bootloader.sha256
)
