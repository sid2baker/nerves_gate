# Sources

| Component | Source | Revision |
| --- | --- | --- |
| Linux | [armbian/linux-rockchip](https://github.com/armbian/linux-rockchip) | `428ab2713a61e9bc438eb1e065469797f97953b4` |
| U-Boot | [rockchip-linux/u-boot](https://github.com/rockchip-linux/u-boot) | `1c535d65b8509f388d09e49fb6961f49fda35a1d` |
| DDR, SPL, TEE, USB loader and packaging tools | [rockchip-linux/rkbin](https://github.com/rockchip-linux/rkbin) | `3e288fe814e059dd06833495f845cab04ac20a5c` |

Selected rkbin components: DDR 750 MHz v1.08, SPL v1.12, standard TEE v2.50,
and USB plug v1.04. Archive and license hashes are in `patches/buildroot/`;
binary hashes are in `bootstrap/rkbin.sha256`.

Nerves Buildroot and ARMv7 toolchain dependencies are declared in `mix.exs` and
locked in `mix.lock`. Component configuration is in `nerves_defconfig`.

## Release source archive

Each release includes a `nerves_system_ec100-sources-<version>-<fingerprint>.tar.gz`
asset alongside the system tarball and `SHA256SUMS`. Its layout is:

- `build/legal-info/`: Buildroot's manifests, configuration, original package
  sources, applied patches, and license notices, including Rockchip's full `rkbin`
  license. The DDR/SPL/TEE/USB loader blobs are proprietary, not source-built.
- `build/legal-info/host-sources/toolchain-external-custom/`: the external
  toolchain's source archives, exact `ct-ng.config` and `ct-ng.defconfig`, the
  `15.3.0` Hex source package (extract its `contents.tar.gz` for build scripts and
  patches), and the pinned crosstool-ng source archive with its bundled patches.
  Downloads are verified against `release/toolchain-sources.sha512`.
- `nerves_system_br/`: Nerves Buildroot `1.34.5`, including the expanded, patched
  Buildroot `2026.05.3` sources and build scripts.
- `nerves_system_ec100/`: this system's matching source, configuration, patches,
  and build/release scripts. Follow its README to rebuild; Mix dependencies are
  pinned in `mix.lock`.

Buildroot uses the external ARMv7 toolchain `15.3.0` from `nerves_defconfig`,
independently of the `15.3.1` Mix package. Its installed license texts are copied
into `legal-info/licenses/toolchain-external-custom/`. These and the other
collected notices are also included in the binary system archive. Large source
archives are only in the separate source asset.

To regenerate the assets from a clean checkout on Linux with Docker:

```sh
mix deps.get
NERVES_CONTAINER_TOOL=docker mix nerves.artifact.build
NERVES_CONTAINER_TOOL=docker mix ec100.release
(cd dist && sha256sum --check SHA256SUMS)
```

The collector requires an empty `dist/` directory. Nerves `2.0.0-pre.3` does not
run the legacy `build_runner_opts` legal-info target, so the collector invokes it
explicitly in the existing build container and repackages the system with notices.

Buildroot's generated README still warns that it cannot save its own sources or
the external toolchain's licenses; the additions above cover those omissions.
The custom kernel also produces missing license-file hash warnings; its notices
are collected from the pinned kernel source. Review these warnings and both
manifests again when changing components; collection alone is not a compliance
guarantee.

## References

- [nerves_system_trellis](https://github.com/nerves-project/nerves_system_trellis): A/B raw-FIT updates
- [nerves_system_rpi2](https://github.com/nerves-project/nerves_system_rpi2): Cortex-A7 toolchain and package structure
- [Rockchip kernel](https://github.com/rockchip-linux/kernel): RK3506 SoC device-tree definitions
- Rockchip RK3506 Technical Reference Manual, revision 1.2

Component licenses remain governed by their respective upstream projects.
