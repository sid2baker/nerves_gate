#!/bin/sh
set -eu

FWUP_CONFIG="$NERVES_DEFCONFIG_DIR/fwup.conf"
sh "$NERVES_DEFCONFIG_DIR/bootstrap/post-image.sh"

# Build a raw FIT slot containing the kernel + DTB.
cp "$NERVES_DEFCONFIG_DIR/ec100.its" "$BINARIES_DIR/ec100.its"
(
    cd "$BINARIES_DIR"
    "$HOST_DIR/bin/mkimage" -f ec100.its ec100.itb
)

# Nerves creates rootfs.squashfs and packages the .fw according to fwup.conf.
"$BR2_EXTERNAL_NERVES_PATH/board/nerves-common/post-createfs.sh" "$TARGET_DIR" "$FWUP_CONFIG"
