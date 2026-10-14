defmodule NervesSystemEC100Qemu.MixProject do
  use Mix.Project

  @app :nerves_system_ec100_qemu
  @version String.trim(File.read!(Path.join(__DIR__, "VERSION")))

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.17",
      compilers: Mix.compilers() ++ [:nerves_package],
      nerves_package: nerves_package(),
      description: "EC100-aligned Nerves test system for x86_64/QEMU",
      deps: deps(),
      aliases: [loadconfig: [&bootstrap/1]]
    ]
  end

  def application do
    []
  end

  defp bootstrap(args) do
    Mix.target(:target)
    Application.start(:nerves_bootstrap)
    Mix.Task.run("loadconfig", args)
  end

  defp nerves_package do
    [
      type: :system,
      artifact_sites: [
        {:github_releases, "sid2baker/nerves_gate", tag: "ec100-qemu-v#{@version}"}
      ],
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
      {:nerves, "~> 2.0 or ~> 2.0.0-pre.3", runtime: false},
      {:nerves_system_br, "1.34.5", runtime: false},
      {:nerves_toolchain_x86_64_nerves_linux_musl, "15.3.1", runtime: false},
      {:nerves_system_linter, "~> 0.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package_files do
    [
      "fwup_include",
      "linux",
      "rootfs_overlay",
      "Config.in",
      "VERSION",
      "fwup-ops.conf",
      "fwup.conf",
      "grub.cfg",
      "linux-6.18.defconfig",
      "mix.exs",
      "mix.lock",
      "nerves_defconfig",
      "post-build.sh",
      "post-createfs.sh"
    ]
  end
end
