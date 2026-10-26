defmodule Workbench.FactoryProvisioning do
  @moduledoc "Reviewed MASKROM provisioning. Shares ec100.flash's staging, backup and verified-write engine."
  @ttl 600_000
  @boot_files ~w(ec100-maskrom-loader.bin idbloader.img u-boot.itb)

  def review!(params, report \\ fn _ -> :ok end) do
    original = params["firmware"]

    unless Enum.any?(Workbench.Builds.images(), &(&1.path == original)),
      do: raise(ArgumentError, "Select an available EC100 firmware image; build or refresh first")

    unless params["sudo"] in [nil, "true", "false"],
      do: raise(ArgumentError, "Choose direct USB access or noninteractive sudo")

    sudo = params["sudo"] == "true"
    backup? = backup_enabled!(params["backup"])
    executable!("rkdeveloptool")
    if sudo, do: executable!("sudo")
    executable!("fwup")
    dir = Path.join(Workbench.root(), "_build/factory-reviews/#{random()}")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)

    try do
      snapshot = Path.join(dir, "image.fw")
      if File.stat!(original).size > 512 * 1024 * 1024, do: raise("Firmware exceeds 512 MiB")
      File.cp!(original, snapshot)
      image = Workbench.FirmwareUpdate.image!(snapshot)
      compatible!(image)
      report.("Resolving the selected build's EC100 boot artifacts")
      images = system_images!(original)
      copy_boot_files!(images, dir)
      files = ["image.fw" | @boot_files]
      hashes = Map.new(files, &{&1, Workbench.FirmwareUpdate.hash!(Path.join(dir, &1))})
      for name <- files, do: File.chmod!(Path.join(dir, name), 0o400)

      output = Path.join(backup_directory(), random())
      File.mkdir_p!(Path.dirname(output))
      File.chmod!(Path.dirname(output), 0o700)
      # Reject clearly insufficient space before touching USB at all. Once the
      # RAM loader reports capacity, enforce the full device-specific budget.
      space!(
        free_space!(Path.dirname(output)),
        required_space(2_261_026, File.stat!(snapshot).size, backup?)
      )

      run = runner(sudo, report)
      location = device!(run.(["ld"]), "Maskrom")
      usb_path = Workbench.FactoryConnection.usb_path(location)
      report.("Loading temporary USB transport into RAM only; no eMMC writes")
      run.(["db", loader!(dir, hashes["ec100-maskrom-loader.bin"])])
      sectors = probe!(run, location, 10)
      required = required_space(sectors, File.stat!(snapshot).size, backup?)
      available = free_space!(Path.dirname(output))
      space!(available, required)

      %{
        owner: __MODULE__,
        public: %{
          kind: :factory,
          token: random(),
          location: location,
          confirmation: erase_confirmation(location, backup?),
          firmware: original,
          version: image["meta-version"],
          sha256: hashes["image.fw"],
          capacity: sectors * 512,
          required_space: required,
          available_space: available,
          backup: output,
          backup_enabled: backup?,
          usb_tracking: not is_nil(usb_path),
          sudo: sudo
        },
        dir: dir,
        snapshot: snapshot,
        usb_path: usb_path,
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

  def backup_directory do
    Application.get_env(:nerves_gate_workbench, :backup_directory) ||
      Path.join(to_string(:filename.basedir(:user_data, ~c"nerves_gate")), "ec100-backups")
  end

  def review_message,
    do: "Factory review complete. Transport loaded into RAM only; no eMMC writes."

  def expiry_message, do: "Factory review expired; re-enter MASKROM before reviewing again"

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
        unless Workbench.FirmwareUpdate.hash!(Path.join(plan.dir, name)) == hash,
          do: raise("Reviewed artifacts changed; re-enter MASKROM and review again")
      end

      space!(free_space!(Path.dirname(plan.public.backup)), plan.public.required_space)
      run = runner(plan.public.sudo, report)
      transport!(run, plan.public.location, plan.sectors)

      flash = engine!()
      report.("Preparing the factory image; no device writes yet")
      files = apply(flash, :prepare!, [plan.snapshot, plan.dir, plan.sectors, plan.public.backup])
      File.chmod!(plan.public.backup, 0o700)
      backup? = Map.get(plan.public, :backup_enabled, true)

      report.(
        if backup?,
          do: "Backing up the entire eMMC user area before any writes",
          else: "Full backup explicitly skipped; every write will still be read back and verified"
      )

      guarded_run = fn args ->
        if hd(args) in ["wl", "rd"],
          do: transport!(run, plan.public.location, plan.sectors)

        run.(args)
      end

      transport!(run, plan.public.location, plan.sectors)

      space!(free_space!(Path.dirname(plan.public.backup)), plan.public.required_space)

      apply(flash, :install!, [
        guarded_run,
        files,
        plan.sectors,
        plan.public.backup,
        [backup: backup?]
      ])

      report.("Every written region verified. Resetting the EC100")
      guarded_run.(["rd"])
      backup_notice = if backup?, do: "Full backup saved.", else: "Full backup skipped."

      "Factory provisioning verified; device reset. #{backup_notice} Artifacts/readbacks: #{plan.public.backup}"
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
  def loader!(dir, expected_hash) do
    path = Path.join(dir, "ec100-maskrom-loader.bin")

    with {:ok, %{type: :regular, size: size}} when size > 0 <- File.stat(path),
         {:ok, bytes} <- File.read(path),
         true <- Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == expected_hash do
      path
    else
      _ ->
        raise "Reviewed RAM loader is missing, unreadable or changed. No USB download was attempted. Start a new factory review."
    end
  end

  @doc false
  def command_label(["db", _]),
    do: "Loading the verified review's RAM transport (no eMMC writes)"

  def command_label(args), do: "rkdeveloptool " <> Enum.join(args, " ")

  @doc false
  def command_error(args, output, code, sudo) do
    output = output |> String.replace(~r/\e\[[0-9;]*[A-Za-z]/, "") |> String.trim()

    detail =
      cond do
        hd(args) == "db" and String.contains?(output, "Creating Comm Object failed") ->
          "The RAM loader opened, but rkdeveloptool could not open or claim the EC100 USB connection. " <>
            usb_access_help(sudo) <> " Listing a device with ld does not prove download access."

        hd(args) == "db" and String.contains?(output, "Opening loader failed") ->
          "rkdeveloptool could not read or parse the reviewed RAM loader. Check the selected EC100 boot artifacts and rkdeveloptool installation."

        true ->
          "USB command failed (#{code}): #{String.slice(output, 0, 500)}. " <>
            usb_access_help(sudo)
      end

    detail <>
      " No automatic retry. Inspect the device before starting a new review; do not replay temporary review paths."
  end

  defp usb_access_help(false),
    do:
      "Direct USB access requires read/write USB permissions. Configure udev access, or explicitly select Noninteractive sudo (-n) in the factory form. Another flasher may also be holding the USB interface."

  defp usb_access_help(true),
    do:
      "Check that sudo -n is authorized for rkdeveloptool from the workbench process and that no other flasher holds the USB interface. The UI cannot prompt for a password."

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
            [_, location, actual] when mode == :transport or actual == mode -> location
            _ -> nil
          end

        _ ->
          nil
      end

    unless location && (is_nil(expected_location) or location == expected_location),
      do:
        raise(
          ArgumentError,
          "Connect exactly one RK3506 EC100#{if mode == :transport, do: "", else: " in #{mode} mode"} at the reviewed USB location"
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
  def backup_enabled!(value) when value in [nil, "true"], do: true
  def backup_enabled!("false"), do: false
  def backup_enabled!(_), do: raise(ArgumentError, "Choose whether to create a full eMMC backup")

  @doc false
  def erase_confirmation(location, true), do: "ERASE EC100 #{location}"
  def erase_confirmation(location, false), do: "ERASE EC100 #{location} WITHOUT BACKUP"

  @doc false
  def required_space(sectors, firmware_bytes, backup? \\ true),
    do: sectors * 512 * if(backup?, do: 3, else: 2) + firmware_bytes + 256 * 1024 * 1024

  @doc false
  def space!(available, required) do
    if available < required,
      do:
        raise(
          ArgumentError,
          "Insufficient factory disk space: require #{required} bytes, available #{available} bytes"
        )

    :ok
  end

  # Some RK3506 RAM transports retain the Maskrom descriptor in ld. The
  # read-only flash-info command, not that label, proves transport readiness.
  # Bracket it with identity checks and pin capacity before every write/reset.
  @doc false
  def transport!(run, location, expected_sectors \\ nil) do
    device!(run.(["ld"]), :transport, location)
    sectors = capacity!(run.(["rfi"]))
    device!(run.(["ld"]), :transport, location)

    if expected_sectors != nil and sectors != expected_sectors,
      do:
        raise(
          ArgumentError,
          "Device capacity changed; no write or reset authorized. Review again"
        )

    sectors
  end

  defp probe!(run, location, attempts) do
    transport!(run, location)
  rescue
    # Only read-only readiness failures are retried. Identity/USB-location or
    # capacity mismatch (ArgumentError) abort immediately.
    error in RuntimeError ->
      if attempts <= 1, do: reraise(error, __STACKTRACE__)
      Process.sleep(1_000)
      probe!(run, location, attempts - 1)
  end

  defp copy_boot_files!(images, dir) do
    hashes = File.read!(Path.join(images, "bootloader.sha256"))

    for name <- @boot_files do
      destination = Path.join(dir, name)
      File.cp!(Path.join(images, name), destination)
      expected = Workbench.FirmwareUpdate.hash!(destination) <> "  " <> name

      unless expected in String.split(hashes, "\n"),
        do: raise("Boot artifact checksum mismatch: #{name}")
    end

    File.cp!(Path.join(images, "bootloader.sha256"), Path.join(dir, "bootloader.sha256"))
  end

  defp system_images!(firmware) do
    ["firmware", "_build", build, "nerves", "images", _] =
      Path.split(Path.relative_to(firmware, Workbench.root()))

    [_, env] = Regex.run(~r/\Aec100_([a-z][a-z0-9_]*)\z/, build)

    script = Path.join(Workbench.root(), "priv/workbench/factory_images.exs")

    {out, status} =
      Workbench.FirmwareCommand.run("elixir", ["-r", script, "-S", "mix", "dev.factory_images"],
        cd: Path.join(Workbench.root(), "firmware"),
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
          Path.join(Workbench.root(), "systems/nerves_system_ec100/lib/mix/tasks/ec100.flash.ex")
        )

    module
  end

  defp runner(sudo, report) do
    rk = executable!("rkdeveloptool")

    fn args ->
      report.(command_label(args))
      {command, argv} = if sudo, do: {executable!("sudo"), ["-n", rk | args]}, else: {rk, args}
      timeout = if hd(args) in ["rl", "wl"], do: 1_800_000, else: 30_000

      case Workbench.FirmwareCommand.run(command, argv, timeout: timeout, stderr_to_stdout: true) do
        {out, 0} ->
          out

        {out, code} ->
          raise command_error(args, out, code, sudo)
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
