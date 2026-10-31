defmodule Mix.Tasks.Em300.Flash do
  use Mix.Task

  @shortdoc "Build and factory-flash the connected EM300 SPI NAND (asks before erasing)"
  @moduledoc """
  Run `mix em300.flash` in the EM300 application project (`MIX_TARGET=em300`).

  Builds the firmware, stages the factory images offline, detects exactly one
  EM300 in MaskROM, loads the temporary USB loader, and asks before erasing the
  whole SPI NAND. It then writes the GPT from `em300-parameter.txt`,
  redundant IDB loader copies outside GPT's erase block, U-Boot, the redundant environment, kernel slot A and
  the UBI image (rootfs_a, empty rootfs_b, empty data), reading back every
  region. Reset happens only after successful verification.

  A full NAND backup is read before erasing and saved with all staged images
  under `em300-backups/`. This is factory installation, NOT an OTA update.

  Requirements: `rkdeveloptool`, `fwup` and `ubinize` (mtd-utils).

  Options: `--yes` skips confirmation, `--no-reset` leaves the USB loader running,
  `--no-sudo` uses direct USB permissions, `--no-backup` skips the NAND backup.
  Default sudo is noninteractive (`-n`).
  """

  # The NAND layout's single source is the Rockchip GPT definition. Device tree,
  # fwup and fw_env.config are checked against it by the system tests.
  @parameter Path.expand("../../../bootstrap/parameter.txt", __DIR__)
  @external_resource @parameter
  @layout (for [_, count, start, name] <-
                 Regex.scan(
                   ~r/0x([0-9a-f]+)@0x([0-9a-f]+)\((\w+)\)/,
                   File.read!(@parameter)
                 ) do
             {name, String.to_integer(start, 16), String.to_integer(count, 16)}
           end)
  @nand_sectors 0x100000
  @peb 128 * 1024
  @page 2048

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [yes: :boolean, reset: :boolean, sudo: :boolean, backup: :boolean]
      )

    if rest != [] or invalid != [], do: Mix.raise("Unknown options: #{inspect(rest ++ invalid)}")

    if Mix.Project.config()[:app] == :nerves_system_em300 or Mix.target() != :em300,
      do: Mix.raise("Run mix em300.flash from your EM300 application (MIX_TARGET=em300).")

    Mix.Task.run("firmware")
    build_plan = Nerves.build_plan()
    firmware = build_plan.config[:firmware_path]

    images =
      Path.join(Nerves.BuildPlan.fetch_interpolated_env!(build_plan, "NERVES_SYSTEM"), "images")

    output =
      Path.expand(
        "em300-backups/#{System.os_time(:second)}-#{System.unique_integer([:positive])}"
      )

    loader = Path.join(images, "em300-loader.bin")

    unless String.contains?(
             File.read!(Path.join(images, "bootloader.sha256")),
             sha256!(loader) <> "  em300-loader.bin\n"
           ),
           do: Mix.raise("Unexpected MaskROM USB loader")

    rk = executable!("rkdeveloptool")

    run = fn args ->
      if Keyword.get(opts, :sudo, true),
        do: cmd!(executable!("sudo"), ["-n", rk | args]),
        else: cmd!(rk, args)
    end

    Mix.shell().info("Detected #{device!(run.(["ld"]))}")
    run.(["db", loader])
    sectors = probe!(run, 10)
    staged = prepare!(firmware, images, sectors, output)
    backup? = Keyword.get(opts, :backup, true)

    Mix.shell().info(
      if backup?,
        do: "A full NAND backup will be saved to #{output}/nand-before.img",
        else:
          "WARNING: NAND backup disabled; the current contents cannot be restored from this run."
    )

    if opts[:yes] ||
         Mix.shell().yes?("Erase the ENTIRE EM300 SPI NAND and install Nerves?") do
      install!(run, staged, sectors, output, backup: backup?)
      if Keyword.get(opts, :reset, true), do: run.(["rd"])
      Mix.shell().info("EM300 flashed and readback verified. Artifacts: #{output}")
    else
      Mix.shell().info("Cancelled. Nothing written to NAND; temporary USB loader remains in RAM.")
    end
  end

  @doc false
  def device!(listing) do
    rows = String.split(listing, "\n") |> Enum.filter(&String.contains?(&1, "DevNo="))

    unless length(rows) == 1 and Regex.match?(~r/Vid=0x2207,Pid=0x350f.*Maskrom/i, hd(rows)),
      do: Mix.raise("Connect exactly one EM300 in MaskROM mode. Found:\n#{listing}")

    hd(rows)
  end

  defp probe!(run, attempts) do
    output = run.(["rfi"])

    case Regex.run(~r/Flash Size:\s*(\d+)\s+Sectors/i, output) do
      [_, count] -> check_capacity!(String.to_integer(count))
      _ -> Mix.raise("Could not read NAND capacity:\n#{output}")
    end
  rescue
    error in Mix.Error ->
      if attempts <= 1, do: reraise(error, __STACKTRACE__)
      Process.sleep(1000)
      probe!(run, attempts - 1)
  end

  @doc "Board facts for Workbench provisioning; the layout comes from parameter.txt."
  def board do
    {_, start, count} = List.last(@layout)

    %{
      name: "EM300",
      storage: "SPI NAND",
      loader: "em300-loader.bin",
      boot_files: ~w(em300-loader.bin em300-idblock.img u-boot.itb em300-parameter.txt),
      sectors: (start + count)..@nand_sectors
    }
  end

  @doc false
  def layout, do: @layout

  @doc false
  def check_capacity!(sectors) do
    unless sectors in board().sectors,
      do: Mix.raise("Unsupported NAND capacity: #{sectors} sectors (expected 512 MiB SPI NAND)")

    sectors
  end

  # Offline staging is separate so the plan can be tested without a USB device.
  # fwup remains authoritative for the environment and archive verification.
  # Workbench provisioning calls prepare!/4 and install!/5 directly.
  @doc false
  def prepare!(firmware, images, sectors, output) do
    check_capacity!(sectors)
    if File.exists?(output), do: Mix.raise("Output already exists: #{output}")
    fwup = executable!("fwup")
    ubinize = executable!("ubinize")
    cmd!(fwup, ["-V", "-i", firmware])

    for {key, expected} <- [{"meta-platform", "em300"}, {"meta-architecture", "arm"}] do
      unless String.trim(cmd!(fwup, ["-m", "-i", firmware, "--metadata-key", key])) == expected,
        do: Mix.raise("Firmware #{key} mismatch")
    end

    hashes = File.read!(Path.join(images, "bootloader.sha256"))

    [_loader, idblock, uboot, parameter] =
      for name <- board().boot_files do
        path = Path.join(images, name)

        unless String.contains?(hashes, sha256!(path) <> "  " <> name <> "\n"),
          do: Mix.raise("Bootloader checksum mismatch: #{name}")

        path
      end

    check_parameter!(File.read!(parameter))
    idblock_data = File.read!(idblock)

    unless match?(<<"RKNS", _::binary>>, idblock_data) and byte_size(idblock_data) <= 2 * @peb,
      do:
        Mix.raise(
          "Unsupported EM300 IDB image; expected RKNS header and at most two erase blocks"
        )

    File.mkdir_p!(output)
    idblock_copies = Path.join(output, "idblock-copies.img")
    copy = idblock_data <> :binary.copy(<<0xFF>>, 2 * @peb - byte_size(idblock_data))
    File.write!(idblock_copies, copy <> copy)

    {:ok, extracted} =
      :zip.unzip(String.to_charlist(firmware), [
        {:file_list, [~c"data/em300.itb", ~c"data/rootfs.img"]},
        {:cwd, String.to_charlist(output)}
      ])

    unless length(extracted) == 2, do: Mix.raise("Firmware lacks data/em300.itb or rootfs.img")
    kernel = Path.join(output, "data/em300.itb")
    rootfs = Path.join(output, "data/rootfs.img")

    env = Path.join(output, "env.img")
    File.write!(env, :binary.copy(<<0xFF>>, sectors!("env") * 512))
    cmd!(fwup, ["-a", "-q", "-i", firmware, "-t", "factory-env", "-d", env])

    ubi = Path.join(output, "ubi.img")
    config = Path.join(output, "ubinize.cfg")
    File.write!(config, ubinize_config(rootfs))
    cmd!(ubinize, ["-o", ubi, "-p", to_string(@peb), "-m", to_string(@page), config])

    staged = %{
      parameter: parameter,
      writes: [
        {"idblock", idblock_copies},
        {"uboot", uboot},
        {"kernel_a", kernel},
        {"ubi", ubi},
        # The environment makes slot A bootable, so it is written last.
        {"env", env}
      ]
    }

    for {name, path} <- staged.writes do
      if File.stat!(path).size > sectors!(name) * 512,
        do: Mix.raise("#{name} image does not fit its partition")
    end

    manifest =
      Enum.map_join(staged.writes, "\n", fn {name, path} ->
        "#{name} sector=#{start!(name)} bytes=#{File.stat!(path).size} sha256=#{sha256!(path)}"
      end)

    File.write!(
      Path.join(output, "manifest.txt"),
      "firmware_sha256=#{sha256!(firmware)}\n#{manifest}\n"
    )

    staged
  end

  @doc false
  def check_parameter!(text) do
    unless text == File.read!(@parameter),
      do: Mix.raise("em300-parameter.txt does not match this system's bootstrap/parameter.txt")

    :ok
  end

  @doc false
  def ubinize_config(rootfs) do
    """
    [rootfs_a]
    mode=ubi
    vol_id=0
    vol_type=dynamic
    vol_name=rootfs_a
    vol_size=128MiB
    image=#{rootfs}

    [rootfs_b]
    mode=ubi
    vol_id=1
    vol_type=dynamic
    vol_name=rootfs_b
    vol_size=128MiB

    [data]
    mode=ubi
    vol_id=2
    vol_type=dynamic
    vol_name=data
    vol_size=1MiB
    vol_flags=autoresize
    """
  end

  @doc false
  def install!(run, staged, sectors, output, opts \\ []) do
    if Keyword.get(opts, :backup, true) do
      backup = Path.join(output, "nand-before.img")
      run.(["rl", "0", to_string(sectors), backup])

      if File.stat!(backup).size != sectors * 512,
        do: Mix.raise("Incomplete backup; refusing writes")

      File.write!(backup <> ".sha256", sha256!(backup) <> "  nand-before.img\n")
    end

    # Old UBI headers would make the new UBI image unattachable, so erase all.
    # Factory flashing is not atomic. Inspect uncertain outcomes before recovery.
    run.(["ef"])
    run.(["gpt", staged.parameter])

    Enum.each(staged.writes, fn {name, path} ->
      if name == "idblock",
        do: run.(["wl", to_string(start!(name)), path]),
        else: run.(["wlx", name, path])

      size = File.stat!(path).size
      count = div(size + 511, 512)
      readback = Path.join(output, name <> "-readback.bin")
      run.(["rl", to_string(start!(name)), to_string(count), readback])

      unless File.stat!(readback).size == count * 512 and
               :crypto.hash(:sha256, binary_part(File.read!(readback), 0, size)) ==
                 :crypto.hash(:sha256, File.read!(path)),
             do: Mix.raise("Readback mismatch: #{name}; stopped without reset. Keep #{output}")
    end)
  end

  # Stock NAND has IDB copies at 128 and 384 KiB: two erase blocks per copy.
  # Keep the first erase block exclusively for GPT.
  defp start!("idblock"), do: div(@peb, 512)
  defp start!(name), do: elem(List.keyfind!(@layout, name, 0), 1)
  defp sectors!("idblock"), do: div(4 * @peb, 512)
  defp sectors!(name), do: elem(List.keyfind!(@layout, name, 0), 2)

  defp sha256!(path) do
    path
    |> File.stream!(64 * 1024)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp executable!(name),
    do: System.find_executable(name) || Mix.raise("Executable not found: #{name}")

  defp cmd!(command, args) do
    Mix.shell().info("+ #{Path.basename(command)} #{Enum.map_join(args, " ", &inspect/1)}")

    case System.cmd(command, args, stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> Mix.raise("Command failed (#{status}): #{command}\n#{output}")
    end
  end
end
