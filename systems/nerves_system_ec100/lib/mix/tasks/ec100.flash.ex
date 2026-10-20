defmodule Mix.Tasks.Ec100.Flash do
  use Mix.Task

  @shortdoc "Build and factory-flash the connected EC100 (asks before erasing)"
  @moduledoc """
  Run `mix ec100.flash` in the EC100 application project. Builds its firmware,
  detects exactly one EC100 in MASKROM, loads the temporary USB transport, reads
  capacity, and asks before replacing the existing partition layout and boot chain.

  A full eMMC user-area backup and all readbacks are saved under `ec100-backups/`.
  Reset occurs only after successful verification. No boot0/boot1 writes or secure
  erase. This is factory installation, NOT an OTA update.

  Optional: `--yes` skips confirmation, `--no-reset` leaves the USB loader running,
  `--no-sudo` uses direct USB permissions, `--no-backup` skips the full eMMC backup.
  Readback verification is always performed. Default sudo is noninteractive (`-n`).
  """

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [yes: :boolean, reset: :boolean, sudo: :boolean, backup: :boolean]
      )

    if rest != [] or invalid != [], do: Mix.raise("Unknown options: #{inspect(rest ++ invalid)}")

    if Mix.Project.config()[:app] == :nerves_system_ec100 or Mix.target() != :ec100,
      do: Mix.raise("Run mix ec100.flash from your EC100 application (MIX_TARGET=ec100).")

    Mix.Task.run("firmware")
    build_plan = Nerves.build_plan()
    firmware = build_plan.config[:firmware_path]

    images =
      Path.join(Nerves.BuildPlan.fetch_interpolated_env!(build_plan, "NERVES_SYSTEM"), "images")

    loader = Path.join(images, "ec100-maskrom-loader.bin")

    unless String.contains?(
             File.read!(Path.join(images, "bootloader.sha256")),
             sha256!(loader) <> "  ec100-maskrom-loader.bin\n"
           ),
           do: Mix.raise("Unexpected MASKROM transport loader")

    rk = executable!("rkdeveloptool")

    run = fn args ->
      if Keyword.get(opts, :sudo, true),
        do: cmd!(executable!("sudo"), ["-n", rk | args]),
        else: cmd!(rk, args)
    end

    device = device!(run.(["ld"]))
    Mix.shell().info("Detected #{device}")
    run.(["db", loader])
    sectors = probe!(run, 10)

    output =
      Path.expand(
        "ec100-backups/#{System.os_time(:second)}-#{System.unique_integer([:positive])}"
      )

    files = prepare!(firmware, images, sectors, output)
    header = Path.join(output, "mbr-before.bin")
    run.(["rl", "0", "1", header])

    Mix.shell().info(
      "#{div(sectors, 2048)} MiB eMMC. Current layout: #{partition_summary!(File.read!(header))}"
    )

    backup? = Keyword.get(opts, :backup, true)

    backup_notice =
      if backup?,
        do: "A full backup will be saved to #{output}/emmc-before.img",
        else:
          "WARNING: full backup disabled; current firmware/data cannot be restored from this run."

    Mix.shell().info(backup_notice)

    if opts[:yes] ||
         Mix.shell().yes?(
           "Replace ALL existing EC100 boot firmware, partitions and application data?"
         ) do
      install!(run, files, sectors, output, backup: backup?)
      if Keyword.get(opts, :reset, true), do: run.(["rd"])
      Mix.shell().info("EC100 flashed and readback verified. Artifacts: #{output}")
    else
      Mix.shell().info("Cancelled. Nothing written to eMMC; temporary USB loader remains in RAM.")
    end
  end

  @doc false
  def device!(listing) do
    rows = String.split(listing, "\n") |> Enum.filter(&String.contains?(&1, "DevNo="))

    unless length(rows) == 1 and Regex.match?(~r/Vid=0x2207,Pid=0x350f.*Maskrom/i, hd(rows)),
      do: Mix.raise("Connect exactly one EC100 in MASKROM mode. Found:\n#{listing}")

    hd(rows)
  end

  defp probe!(run, attempts) do
    try do
      case Regex.run(~r/Flash Size:\s*(\d+)\s+Sectors/i, run.(["rfi"])) do
        [_, count] -> String.to_integer(count)
        _ -> Mix.raise("Could not read eMMC capacity")
      end
    rescue
      error in Mix.Error ->
        if attempts <= 1, do: reraise(error, __STACKTRACE__)
        Process.sleep(1000)
        probe!(run, attempts - 1)
    end
  end

  @doc false
  def partition_summary!(<<_::binary-size(446), entries::binary-size(64), 0x55, 0xAA>>) do
    parts =
      for <<_::32, type, _::24, start::little-32, count::little-32 <- entries>>, type != 0,
        do: {type, start, count}

    if Enum.any?(parts, fn {type, _, _} -> type == 0xEE end),
      do: "GPT protective MBR",
      else: "MBR entries #{inspect(parts)} (type, start sector, length)"
  end

  def partition_summary!(_), do: "no valid MBR signature"

  # Offline preparation is separated only so the exact write plan can be tested
  # without a USB device. fwup remains authoritative for OS/env/partition data.
  @doc false
  def prepare!(firmware, images, sectors, output) do
    if sectors < 2_261_026 or sectors > 0xFFFFFFFF, do: Mix.raise("Unsupported eMMC capacity")
    if File.exists?(output), do: Mix.raise("Output already exists: #{output}")
    fwup = executable!("fwup")
    cmd!(fwup, ["-V", "-i", firmware])

    for {key, expected} <- [{"meta-platform", "ec100"}, {"meta-architecture", "arm"}] do
      unless String.trim(cmd!(fwup, ["-m", "-i", firmware, "--metadata-key", key])) == expected,
        do: Mix.raise("Firmware #{key} mismatch")
    end

    hashes = File.read!(Path.join(images, "bootloader.sha256"))

    [idb, uboot] =
      for name <- ["idbloader.img", "u-boot.itb"] do
        path = Path.join(images, name)

        unless String.contains?(hashes, sha256!(path) <> "  " <> name <> "\n"),
          do: Mix.raise("Bootloader checksum mismatch: #{name}")

        File.read!(path)
      end

    boot = boot_area!(idb, uboot)
    File.mkdir_p!(Path.dirname(output))
    File.mkdir!(output)
    image = Path.join(output, "factory.img")

    cmd!(fwup, [
      "-a",
      "-U",
      "-i",
      firmware,
      "-d",
      image,
      "-t",
      "complete",
      "--max-size",
      to_string(sectors)
    ])

    validate_gpt!(
      read_at!(image, 0, 34 * 512),
      read_at!(image, (sectors - 33) * 512, 33 * 512),
      sectors
    )

    {:ok, entries} = :zip.list_dir(String.to_charlist(firmware))

    sizes =
      for {:zip_file, name, info, _, _, _} <- entries,
          into: %{},
          do: {List.to_string(name), elem(info, 1)}

    files =
      for {name, sector, count} <- regions!(sizes, sectors) do
        file!(output, name, sector, read_at!(image, sector * 512, count * 512))
      end

    files = files ++ [file!(output, "boot-area", 64, boot)]

    manifest =
      Enum.map_join(files, "\n", fn {name, sector, count, path} ->
        "#{name} sector=#{sector} count=#{count} sha256=#{sha256!(path)}"
      end)

    File.write!(
      Path.join(output, "manifest.txt"),
      "firmware_sha256=#{sha256!(firmware)}\nsectors=#{sectors}\n#{manifest}\n"
    )

    files
  end

  @doc false
  def install!(run, files, sectors, output, opts \\ []) do
    if Keyword.get(opts, :backup, true) do
      backup = Path.join(output, "emmc-before.img")
      run.(["rl", "0", to_string(sectors), backup])

      if File.stat!(backup).size != sectors * 512,
        do: Mix.raise("Incomplete backup; refusing writes")

      File.write!(backup <> ".sha256", sha256!(backup) <> "  emmc-before.img\n")
    end

    # Payloads first, then boot chain, backup GPT, and primary GPT last.
    # Factory flashing is not atomic.
    Enum.sort_by(files, fn {name, _, _, _} ->
      cond do
        name == "gpt-primary" -> 4
        name == "gpt-backup" -> 3
        name == "boot-area" -> 2
        String.starts_with?(name, "env") -> 1
        true -> 0
      end
    end)
    |> Enum.each(fn {name, sector, count, path} ->
      run.(["wl", to_string(sector), path])
      readback = Path.join(output, name <> "-readback.bin")
      run.(["rl", to_string(sector), to_string(count), readback])

      if File.stat!(readback).size != count * 512 or sha256!(readback) != sha256!(path),
        do: Mix.raise("Readback mismatch: #{name}; stopped without reset. Keep #{output}")
    end)
  end

  @doc false
  def boot_area!(idb, uboot) do
    idb_limit = (16384 - 64) * 512
    uboot_limit = (24576 - 16384) * 512

    unless byte_size(idb) > 0 and byte_size(idb) <= idb_limit and byte_size(uboot) > 0 and
             byte_size(uboot) <= uboot_limit,
           do: Mix.raise("Boot artifact missing or overlaps reserved environment")

    idb <>
      :binary.copy(<<0>>, idb_limit - byte_size(idb)) <>
      uboot <> :binary.copy(<<0>>, uboot_limit - byte_size(uboot))
  end

  @doc false
  def regions!(sizes, sectors) do
    fit = payload_sectors!(sizes, "data/ec100.itb", 65536)
    root = payload_sectors!(sizes, "data/rootfs.img", 524_288)

    [
      {"gpt-primary", 0, 34},
      {"gpt-backup", sectors - 33, 33},
      {"env-a", 24576, 256},
      {"env-b", 24832, 256},
      {"fit-a", 32768, fit},
      {"rootfs-a", 163_840, root},
      {"invalidate-fit-b", 98304, 256},
      {"invalidate-rootfs-b", 688_128, 256},
      {"initialize-data", 1_212_416, 256}
    ]
  end

  defp payload_sectors!(sizes, name, limit) do
    bytes = Map.get(sizes, name, 0)
    if bytes <= 0 or bytes > limit * 512, do: Mix.raise("Missing/oversized resource #{name}")
    div(bytes + 511, 512)
  end

  @doc false
  def validate_gpt!(primary, backup, sectors) do
    unless byte_size(primary) == 34 * 512 and byte_size(backup) == 33 * 512 do
      Mix.raise("Invalid staged GPT size")
    end

    <<mbr::binary-size(512), header::binary-size(512), entries::binary>> = primary
    <<backup_entries::binary-size(16384), backup_header::binary>> = backup

    unless binary_part(mbr, 450, 1) == <<0xEE>> and
             binary_part(mbr, 454, 56) == <<1::little-32, sectors - 1::little-32, 0::384>> and
             binary_part(mbr, 510, 2) == <<0x55, 0xAA>> do
      Mix.raise("Invalid GPT protective MBR")
    end

    guid = validate_gpt_header!(header, entries, 1, sectors - 1, 2, sectors)

    backup_guid =
      validate_gpt_header!(backup_header, backup_entries, sectors - 1, 1, sectors - 33, sectors)

    unless entries == backup_entries and guid == backup_guid do
      Mix.raise("GPT copies do not match")
    end

    # fwup's expand option leaves one unused sector before the backup GPT.
    Enum.with_index([{163_840, 688_127}, {688_128, 1_212_415}, {1_212_416, sectors - 35}])
    |> Enum.each(fn {{start, last}, i} ->
      <<type::binary-size(16), _guid::binary-size(16), actual_start::little-64,
        actual_last::little-64, _::binary>> = binary_part(entries, i * 128, 128)

      unless Base.encode16(type) == "AF3DC60F838472478E793D69D8477DE4" and actual_start == start and
               actual_last == last do
        Mix.raise("Staged partition #{i + 1} does not match EC100 layout")
      end
    end)

    unless binary_part(entries, 384, 16000) == :binary.copy(<<0>>, 16000) do
      Mix.raise("Unexpected GPT partitions")
    end

    :ok
  end

  defp validate_gpt_header!(header, entries, current, backup, table, sectors) do
    case header do
      <<"EFI PART", 0x00010000::little-32, 92::little-32, crc::little-32, 0::32,
        ^current::little-64, ^backup::little-64, 34::little-64, last::little-64,
        guid::binary-size(16), ^table::little-64, 128::little-32, 128::little-32,
        entries_crc::little-32, 0::3360>>
      when last == sectors - 34 ->
        <<prefix::binary-size(16), _::32, suffix::binary-size(72), _::binary>> = header

        unless :erlang.crc32([prefix, <<0::32>>, suffix]) == crc and
                 :erlang.crc32(entries) == entries_crc do
          Mix.raise("Invalid GPT checksum")
        end

        guid

      _ ->
        Mix.raise("Invalid staged GPT header")
    end
  end

  defp file!(output, name, sector, data) do
    path = Path.join(output, name <> ".bin")
    File.write!(path, data)
    {name, sector, div(byte_size(data), 512), path}
  end

  defp read_at!(path, offset, count) do
    File.open!(path, [:read, :binary], fn io ->
      case :file.pread(io, offset, count) do
        {:ok, data} when byte_size(data) == count -> data
        _ -> Mix.raise("Short read: #{path}")
      end
    end)
  end

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
