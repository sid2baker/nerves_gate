defmodule Dev.FactoryProvisioning do
  @moduledoc "Reviewed MASKROM provisioning. Shares ec100.flash's staging, backup and verified-write engine."
  @ttl 600_000
  @boot_files ~w(ec100-maskrom-loader.bin idbloader.img u-boot.itb)

  def review!(params, report \\ fn _ -> :ok end) do
    original = params["firmware"]

    unless Enum.any?(Dev.Builds.images(), &(&1.path == original)),
      do: raise(ArgumentError, "Select an available EC100 firmware image; build or refresh first")

    unless params["sudo"] in [nil, "true", "false"],
      do: raise(ArgumentError, "Choose direct USB access or noninteractive sudo")

    sudo = params["sudo"] == "true"
    executable!("rkdeveloptool")
    if sudo, do: executable!("sudo")
    executable!("fwup")
    dir = Path.join(Dev.root(), "_build/factory-reviews/#{random()}")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)

    try do
      snapshot = Path.join(dir, "image.fw")
      if File.stat!(original).size > 512 * 1024 * 1024, do: raise("Firmware exceeds 512 MiB")
      File.cp!(original, snapshot)
      image = Dev.FirmwareUpdate.image!(snapshot)
      compatible!(image)
      report.("Resolving the selected build's EC100 boot artifacts")
      images = system_images!(original)
      copy_boot_files!(images, dir)
      files = ["image.fw" | @boot_files]
      hashes = Map.new(files, &{&1, Dev.FirmwareUpdate.hash!(Path.join(dir, &1))})
      for name <- files, do: File.chmod!(Path.join(dir, name), 0o400)

      output = Path.join(Dev.root(), "ec100-backups/#{random()}")
      File.mkdir_p!(Path.dirname(output))
      File.chmod!(Path.dirname(output), 0o700)
      # Reject clearly insufficient space before touching USB at all. Once the
      # RAM loader reports capacity, enforce the full device-specific budget.
      space!(
        free_space!(Path.dirname(output)),
        required_space(2_261_026, File.stat!(snapshot).size)
      )

      run = runner(sudo, report)
      location = device!(run.(["ld"]), "Maskrom")
      report.("Loading temporary USB transport into RAM only; no eMMC writes")
      run.(["db", Path.join(dir, "ec100-maskrom-loader.bin")])
      sectors = probe!(run, 10)
      device!(run.(["ld"]), "Loader", location)
      required = required_space(sectors, File.stat!(snapshot).size)
      available = free_space!(Path.dirname(output))
      space!(available, required)

      %{
        public: %{
          kind: :factory,
          token: random(),
          location: location,
          confirmation: "ERASE EC100 #{location}",
          firmware: original,
          version: image["meta-version"],
          sha256: hashes["image.fw"],
          capacity: sectors * 512,
          required_space: required,
          available_space: available,
          backup: output,
          sudo: sudo
        },
        dir: dir,
        snapshot: snapshot,
        hashes: hashes,
        sectors: sectors,
        expires: System.monotonic_time(:millisecond) + @ttl
      }
    catch
      kind, reason ->
        File.rm_rf!(dir)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  def confirmation!(plan, token, text, identified) do
    cond do
      plan.public.kind != :factory or not is_binary(token) or token != plan.public.token ->
        raise ArgumentError, "Review factory provisioning first"

      System.monotonic_time(:millisecond) >= plan.expires ->
        raise ArgumentError, "Factory review expired; re-enter MASKROM and review again"

      identified != "true" ->
        raise ArgumentError, "Physically verify the attached board is an EC100"

      text != plan.public.confirmation ->
        raise ArgumentError, "Type the exact erase confirmation"

      true ->
        :ok
    end
  end

  def provision!(plan, report \\ fn _ -> :ok end) do
    try do
      confirmation!(plan, plan.public.token, plan.public.confirmation, "true")

      for {name, hash} <- plan.hashes do
        unless Dev.FirmwareUpdate.hash!(Path.join(plan.dir, name)) == hash,
          do: raise("Reviewed artifacts changed; re-enter MASKROM and review again")
      end

      space!(free_space!(Path.dirname(plan.public.backup)), plan.public.required_space)
      run = runner(plan.public.sudo, report)
      device!(run.(["ld"]), "Loader", plan.public.location)

      unless capacity!(run.(["rfi"])) == plan.sectors,
        do: raise("Device capacity changed; review again")

      flash = engine!()
      report.("Preparing the factory image; no device writes yet")
      files = apply(flash, :prepare!, [plan.snapshot, plan.dir, plan.sectors, plan.public.backup])
      File.chmod!(plan.public.backup, 0o700)
      # The shared engine completes and hashes the full backup before its first
      # write, then reads back every written region. Never offer --no-backup.
      report.("Backing up the entire eMMC user area before any writes")

      guarded_run = fn args ->
        if hd(args) in ["wl", "rd"], do: device!(run.(["ld"]), "Loader", plan.public.location)
        run.(args)
      end

      device!(run.(["ld"]), "Loader", plan.public.location)

      unless capacity!(run.(["rfi"])) == plan.sectors,
        do: raise("Device capacity changed; no writes performed")

      space!(free_space!(Path.dirname(plan.public.backup)), plan.public.required_space)

      apply(flash, :install!, [
        guarded_run,
        files,
        plan.sectors,
        plan.public.backup,
        [backup: true]
      ])

      report.("Every written region verified. Resetting the EC100")
      guarded_run.(["rd"])
      "Factory provisioning verified; device reset. Backup/readbacks: #{plan.public.backup}"
    rescue
      error ->
        raise "#{Exception.message(error)}. Inspect the device before retrying; keep #{plan.public.backup}"
    after
      cleanup(plan)
    end
  end

  def cleanup(nil), do: :ok
  def cleanup(plan), do: File.rm_rf!(plan.dir)

  @doc false
  def compatible!(image) do
    unless image["meta-platform"] == "ec100" and image["meta-architecture"] == "arm" and
             image["meta-product"] == "nerves_gate" and is_binary(image["meta-version"]),
           do: raise(ArgumentError, "Choose Nerves Gate firmware for the physical EC100")

    :ok
  end

  @doc false
  def device!(listing, mode, expected_location \\ nil) do
    rows = String.split(listing, "\n") |> Enum.filter(&String.contains?(&1, "DevNo="))

    location =
      case rows do
        [row] ->
          case Regex.run(
                 ~r/Vid=0x2207,Pid=0x350f.*LocationID=([0-9a-f]+)\s+(Maskrom|Loader)\b/i,
                 row
               ) do
            [_, location, ^mode] -> location
            _ -> nil
          end

        _ ->
          nil
      end

    unless location && (is_nil(expected_location) or location == expected_location),
      do:
        raise(
          ArgumentError,
          "Connect exactly one RK3506 EC100 in #{mode} mode at the reviewed USB location"
        )

    location
  end

  @doc false
  def capacity!(text) do
    case Regex.run(~r/Flash Size:\s*(\d+)\s+Sectors/i, text) do
      [_, n] ->
        sectors = String.to_integer(n)
        if sectors < 2_261_026 or sectors > 0xFFFFFFFF, do: raise("Unsupported eMMC capacity")
        sectors

      _ ->
        raise "Could not read eMMC capacity"
    end
  end

  @doc false
  def required_space(sectors, firmware_bytes),
    do: sectors * 512 * 3 + firmware_bytes + 256 * 1024 * 1024

  @doc false
  def space!(available, required) do
    if available < required,
      do:
        raise(
          ArgumentError,
          "Insufficient backup disk space: require #{required} bytes, available #{available} bytes"
        )

    :ok
  end

  defp probe!(run, attempts) do
    capacity!(run.(["rfi"]))
  rescue
    error ->
      if attempts <= 1, do: reraise(error, __STACKTRACE__)
      Process.sleep(1_000)
      probe!(run, attempts - 1)
  end

  defp copy_boot_files!(images, dir) do
    hashes = File.read!(Path.join(images, "bootloader.sha256"))

    for name <- @boot_files do
      source = Path.join(images, name)
      expected = Dev.FirmwareUpdate.hash!(source) <> "  " <> name

      unless expected in String.split(hashes, "\n"),
        do: raise("Boot artifact checksum mismatch: #{name}")

      File.cp!(source, Path.join(dir, name))
    end

    File.cp!(Path.join(images, "bootloader.sha256"), Path.join(dir, "bootloader.sha256"))
  end

  defp system_images!(firmware) do
    ["firmware", "_build", build, "nerves", "images", _] =
      Path.split(Path.relative_to(firmware, Dev.root()))

    [_, env] = Regex.run(~r/\Aec100_([a-z][a-z0-9_]*)\z/, build)

    script = Path.join(Dev.root(), "priv/dev/factory_images.exs")

    {out, status} =
      MuonTrap.cmd("elixir", ["-r", script, "-S", "mix", "dev.factory_images"],
        cd: Path.join(Dev.root(), "firmware"),
        timeout: 60_000,
        stderr_to_stdout: true,
        env: [
          {"MIX_TARGET", "ec100"},
          {"MIX_ENV", env},
          {"NERVES_GATE_LOCAL_DEPS", "1"},
          {"NERVES_SYSTEM", nil},
          {"NERVES_GATE_DEVICE_NODE", nil}
        ]
      )

    encoded =
      out
      |> String.split("\n")
      |> Enum.find_value(fn line ->
        if String.starts_with?(line, "FACTORY_IMAGES="),
          do: String.replace_prefix(line, "FACTORY_IMAGES=", "")
      end)

    unless status == 0 and encoded,
      do: raise("Build EC100 firmware first; cannot resolve boot artifacts")

    Base.decode64!(encoded)
  end

  defp engine! do
    # Use the existing CLI's public staging/write functions, never run its
    # interactive Mix task or duplicate its boot-layout/backup/readback logic.
    module = Mix.Tasks.Ec100.Flash

    unless Code.ensure_loaded?(module),
      do:
        Code.require_file(
          Path.join(Dev.root(), "systems/nerves_system_ec100/lib/mix/tasks/ec100.flash.ex")
        )

    module
  end

  defp runner(sudo, report) do
    rk = executable!("rkdeveloptool")

    fn args ->
      report.("rkdeveloptool " <> Enum.join(args, " "))
      {command, argv} = if sudo, do: {executable!("sudo"), ["-n", rk | args]}, else: {rk, args}
      timeout = if hd(args) in ["rl", "wl"], do: 1_800_000, else: 30_000

      case MuonTrap.cmd(command, argv, timeout: timeout, stderr_to_stdout: true) do
        {out, 0} ->
          out

        {out, code} ->
          raise "USB command failed (#{code}): #{String.slice(out, 0, 500)}. No automatic retry; check USB permissions (or sudo -v in a terminal) and inspect the device"
      end
    end
  end

  defp free_space!(path) do
    {out, 0} = System.cmd("df", ["-Pk", path], stderr_to_stdout: true)
    [_, _, _, free | _] = out |> String.split("\n", trim: true) |> List.last() |> String.split()
    String.to_integer(free) * 1024
  end

  defp executable!(name),
    do: System.find_executable(name) || raise("Install #{name} on the workbench host first")

  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
end
