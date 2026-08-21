defmodule NervesSystemNervesGate.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :nerves_system_nerves_gate,
      version: @version,
      elixir: "~> 1.17",
      compilers: Mix.compilers() ++ [:nerves_package],
      nerves_package: nerves_package(),
      deps: deps()
    ]
  end

  def application, do: []

  defp nerves_package do
    [
      type: :system,
      build_runner_opts: [make_args: ["source", "all", "legal-info"]],
      platform: Nerves.System.BR,
      platform_config: [defconfig: "nerves_defconfig"],
      env: [
        {"TARGET_ARCH", "x86_64"},
        {"TARGET_OS", "linux"},
        {"TARGET_ABI", "musl"},
        {"TARGET_GCC_FLAGS",
         "-m64 -fstack-protector-strong -march=x86-64 -fPIE -pie -Wl,-z,now -Wl,-z,relro"}
      ],
      checksum: package_files()
    ]
  end

  defp deps do
    [
      {:nerves, "~> 1.15", runtime: false},
      {:nerves_system_br, "1.34.1", runtime: false},
      {:nerves_toolchain_x86_64_nerves_linux_musl, "~> 15.3.0", runtime: false}
    ]
  end

  defp package_files do
    [
      "fwup_include",
      "rootfs_overlay",
      "Config.in",
      "VERSION",
      "fwup-ops.conf",
      "fwup.conf",
      "grub.cfg",
      "linux-6.18.defconfig",
      "mix.exs",
      "nerves_defconfig",
      "post-build.sh",
      "post-createfs.sh"
    ]
  end
end
