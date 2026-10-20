defmodule NervesSystemEC100.MixProject do
  use Mix.Project

  @app :nerves_system_ec100
  @version Path.join(__DIR__, "VERSION") |> File.read!() |> String.trim()

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.17",
      compilers: Mix.compilers() ++ [:nerves_package],
      nerves_package: nerves_package(),
      description: "Minimal Nerves system for the IOTRouter EC100 (Rockchip RK3506J)",
      deps: deps(),
      aliases: [loadconfig: [&bootstrap/1]]
    ]
  end

  def application, do: []

  defp bootstrap(args) do
    set_target()
    Application.start(:nerves_bootstrap)
    Mix.Task.run("loadconfig", args)
  end

  defp nerves_package do
    [
      type: :system,
      artifact_sites: [
        {:github_releases, "sid2baker/nerves_system_ec100"}
      ],
      platform: Nerves.System.BR,
      platform_config: [defconfig: "nerves_defconfig"],
      env: [
        {"TARGET_ARCH", "arm"},
        {"TARGET_CPU", "cortex_a7"},
        {"TARGET_OS", "linux"},
        {"TARGET_ABI", "gnueabihf"},
        {"TARGET_GCC_FLAGS",
         "-mabi=aapcs-linux -mfpu=neon-vfpv4 -marm -fstack-protector-strong " <>
           "-mfloat-abi=hard -mcpu=cortex-a7 -fPIE -pie -Wl,-z,now -Wl,-z,relro"}
      ],
      checksum: package_files()
    ]
  end

  defp deps do
    [
      {:nerves, "~> 2.0 or ~> 2.0.0-pre.3", runtime: false},
      {:nerves_system_br, "1.34.5", runtime: false},
      {:nerves_toolchain_armv7_nerves_linux_gnueabihf, "~> 15.3.0", runtime: false},
      {:nerves_system_linter, "~> 0.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package_files do
    [
      "bootstrap",
      "dts",
      "ec100.its",
      "lib/mix/tasks/ec100.release.ex",
      "linux",
      "patches",
      "release",
      "rootfs_overlay",
      "LICENSE",
      "README.md",
      "SOURCES.md",
      "VERSION",
      "fwup-ops.conf",
      "fwup.conf",
      "mix.exs",
      "nerves_defconfig",
      "post-build.sh",
      "post-createfs.sh"
    ]
  end

  defp set_target do
    if function_exported?(Mix, :target, 1) do
      apply(Mix, :target, [:target])
    else
      System.put_env("MIX_TARGET", "target")
    end
  end
end
