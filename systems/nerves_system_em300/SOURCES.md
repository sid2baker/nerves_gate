# Sources

| Component | Source | Revision |
| --- | --- | --- |
| Linux | [armbian/linux-rockchip](https://github.com/armbian/linux-rockchip) | `428ab2713a61e9bc438eb1e065469797f97953b4` |
| U-Boot | [rockchip-linux/u-boot](https://github.com/rockchip-linux/u-boot) | `1c535d65b8509f388d09e49fb6961f49fda35a1d` |
| DDR, SPL, TEE, USB loader and packaging tools | [rockchip-linux/rkbin](https://github.com/rockchip-linux/rkbin) | `3e288fe814e059dd06833495f845cab04ac20a5c` |

Selected rkbin components: DDR 750 MHz v1.08, SPL v1.12, standard TEE v2.50,
and USB plug v1.04. Archive and license hashes are in `patches/buildroot/`;
binary hashes are in `bootstrap/rkbin.sha256`.

Nerves Buildroot and the application cross-toolchain dependencies are declared in
`mix.exs` and locked in `mix.lock`. Buildroot's external ARMv7 toolchain is pinned
to `15.3.0` in `nerves_defconfig`, independently of the `15.3.1` Mix package.

## Buildroot source and license collection

The EM300 is not yet published. When added, the shared
[system workflow](../../.github/workflows/system-artifact.yml) uses:

1. Buildroot `make source` before compilation, using its checksum validation,
   configured download sites and the shared Nerves download cache.
2. Nerves 2 `mix nerves.artifact.build nerves_system_em300`.
3. Buildroot `make legal-info` and `make system` to include notices in the system
   artifact. Installed external-toolchain licenses and its exact `ct-ng.config`
   and `ct-ng.defconfig` are retained alongside those reports.

The source asset `nerves_system_em300-sources-<version>-<fingerprint>.tar.gz`
contains `build/legal-info/`, this system's recipes and Nerves Buildroot's
expanded sources. The binary artifact excludes the large source archives.
`SHA256SUMS` covers both assets.

Buildroot's legal-info report is **not a guarantee of complete corresponding
source**. In particular, Buildroot does not collect source archives for its
prebuilt external toolchain. Review the report's warnings, licenses and manifests
before distribution, and arrange any required corresponding-source distribution
or source offer. The external toolchain's upstream build recipes are in
[nerves-project/toolchains at v15.3.0](https://github.com/nerves-project/toolchains/tree/v15.3.0).
The Rockchip DDR/SPL/TEE/USB loader blobs remain proprietary, not source-built.

To collect the assets locally after preparing a stable version and dated notes,
run from `firmware/` on Linux with Docker or Podman:

```sh
MIX_TARGET=em300 NERVES_GATE_LOCAL_DEPS=1 elixir -r ../lib/dev/artifact_release.ex -S mix nerves.artifact.release source
MIX_TARGET=em300 NERVES_GATE_LOCAL_DEPS=1 mix nerves.artifact.build nerves_system_em300
MIX_TARGET=em300 NERVES_GATE_LOCAL_DEPS=1 elixir -r ../lib/dev/artifact_release.ex -S mix nerves.artifact.release collect
(cd dist && sha256sum --check SHA256SUMS)
```

Collection requires an empty `dist/`. Nerves `2.0.0-pre.4` still ignores the
legacy `build_runner_opts`; the shared release task invokes the standard
Buildroot targets in Nerves' own container workspace. It has no separate package
downloader or compiler-source manifest. Download caches are saved after failed
CI builds too. Source collection does not publish or flash anything.

## References

- [Nerves 2 migration guide](https://github.com/nerves-project/nerves/blob/v2/guides/advanced/updating-projects.md#nerves-system-maintainers)
- [nerves_system_trellis](https://github.com/nerves-project/nerves_system_trellis): A/B raw-FIT updates
- [nerves_system_rpi2](https://github.com/nerves-project/nerves_system_rpi2): Cortex-A7 toolchain and package structure
- [Rockchip kernel](https://github.com/rockchip-linux/kernel): RK3506 SoC device-tree definitions
- Rockchip RK3506 Technical Reference Manual, revision 1.2

Component licenses remain governed by their respective upstream projects.
