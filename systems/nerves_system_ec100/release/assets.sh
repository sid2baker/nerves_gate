#!/usr/bin/env bash
# Run by mix ec100.release inside the existing Nerves build container, after a build.
set -euo pipefail

cd /workspace/build
system=/workspace/nerves_system_ec100
toolchain=host/opt/ext-toolchain
name="nerves_system_ec100-portable-${NERVES_ARTIFACT_VERSION}-${NERVES_ARTIFACT_SOURCE_FINGERPRINT}"
sources="nerves_system_ec100-sources-${NERVES_ARTIFACT_VERSION}-${NERVES_ARTIFACT_SOURCE_FINGERPRINT}"

# The supplemental source list is specific to the external toolchain in this system.
test "$(< "$toolchain/nerves-toolchain.tag")" = 15.3.0
make legal-info

supplement=legal-info/host-sources/toolchain-external-custom
mkdir -p "$supplement" legal-info/licenses/toolchain-external-custom legal-info/licenses/nerves_system_ec100
cp -a "$toolchain/share/licenses/." legal-info/licenses/toolchain-external-custom/
cp "$toolchain/ct-ng.config" "$toolchain/ct-ng.defconfig" "$supplement/"
cp "$system/LICENSE" legal-info/licenses/nerves_system_ec100/
cp "$system/SOURCES.md" legal-info/EC100-SOURCES.md
cp "$system/release/toolchain-sources.sha512" "$supplement/"

# Keep verified downloads across retries; never accept a partial or changed archive.
cache=/workspace/dl/ec100-toolchain-sources
mkdir -p "$cache"
while read -r checksum url; do
    [[ -z "$checksum" || "$checksum" == \#* ]] && continue
    filename=${url##*/}
    if [[ ! -f "$cache/$filename" ]]; then
        curl --fail --location --retry 3 --silent --show-error "$url" -o "$cache/$filename.part"
        printf '%s  %s\n' "$checksum" "$cache/$filename.part" | sha512sum --check -
        mv "$cache/$filename.part" "$cache/$filename"
    fi
    printf '%s  %s\n' "$checksum" "$cache/$filename" | sha512sum --check -
    cp "$cache/$filename" "$supplement/"
done < "$system/release/toolchain-sources.sha512"

# Nerves includes notices but omits legal-info/{sources,host-sources} in the binary.
make system NERVES_ARTIFACT_NAME="$name"
mkdir -p "$NERVES_ARTIFACT_DIR"
cp "$name.tar.gz" "$NERVES_ARTIFACT_DIR/"

# Include Buildroot itself and the exact system recipes alongside collected sources.
# Exclude only Buildroot's absolute convenience symlink, not its expanded sources.
tar -czf "$NERVES_ARTIFACT_DIR/$sources.tar.gz.part" \
    --exclude=nerves_system_br/buildroot \
    -C /workspace build/legal-info nerves_system_ec100 nerves_system_br
mv "$NERVES_ARTIFACT_DIR/$sources.tar.gz.part" "$NERVES_ARTIFACT_DIR/$sources.tar.gz"
