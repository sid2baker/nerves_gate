defmodule NervesGate.Firmware.Platform.Nerves do
  @moduledoc "Generic Nerves/fwup implementation of the firmware platform contract."

  @behaviour NervesGate.Firmware.Platform

  alias Nerves.Runtime.KV
  alias NervesGate.Firmware.{Command, Release}

  @impl true
  def status(options), do: status(options, 3)

  defp status(options, attempts) do
    case read_status(options) do
      {:error, _reason} when attempts > 1 ->
        Process.sleep((4 - attempts) * 250)
        status(options, attempts - 1)

      result ->
        result
    end
  end

  defp read_status(options) do
    slots = Nerves.Runtime.firmware_slots()
    validation = Nerves.Runtime.firmware_validation_status()
    active = slots.active

    current = %{
      product: active_value("nerves_fw_product", "nerves_gate"),
      system: active_value("nerves_fw_system", Keyword.get(options, :system, "unknown")),
      platform: active_value("nerves_fw_platform", "unknown"),
      architecture: active_value("nerves_fw_architecture", "unknown"),
      version: active_value("nerves_fw_version", "unknown"),
      uuid: active_value("nerves_fw_uuid", "unknown"),
      vcs_identifier: active_value("nerves_fw_vcs_identifier", "unknown"),
      slot: active
    }

    automatic_fallback = Keyword.get(options, :automatic_fallback, false)
    keys = Keyword.get(options, :fwup_public_keys, [])
    enabled = Keyword.get(options, :enabled, false)

    {:ok,
     %{
       supported: enabled and automatic_fallback and keys != [],
       automatic_fallback: automatic_fallback,
       current: current,
       validation: validation,
       active_slot: active,
       next_slot: slots.next
     }}
  rescue
    error -> {:error, {:platform_status_failed, Exception.message(error)}}
  catch
    _kind, reason -> {:error, {:platform_status_failed, inspect(reason)}}
  end

  @impl true
  def install_verified(path, %Release{} = _release, options) do
    fwup = Keyword.get(options, :fwup_path, "fwup")
    device = Keyword.get(options, :device, "/dev/rootdisk0")
    keys = Keyword.get(options, :fwup_public_keys, [])
    runner = Keyword.get(options, :runner, &MuonTrap.cmd/3)

    args =
      ["-a", "-i", path, "-d", device, "-t", "upgrade", "-U", "--verify-writes"] ++
        Enum.flat_map(keys, &["--public-key", &1])

    command_options = [
      timeout: Keyword.get(options, :install_timeout, :timer.minutes(15)),
      stderr_to_stdout: true
    ]

    case run_installer(runner, fwup, args, command_options) do
      {:ok, {_output, 0}} -> :ok
      {:ok, {_output, :timeout}} -> {:error, :installation_timeout}
      {:ok, {output, status}} -> {:error, {:installation_failed, status, sanitize(output)}}
      {:error, :command_timeout} -> {:error, :installation_timeout}
      {:error, :command_crashed} -> {:error, :installer_unavailable}
    end
  end

  defp run_installer(runner, executable, arguments, options, attempts \\ 3) do
    case Command.run(runner, executable, arguments, options) do
      {:error, :command_crashed} when attempts > 1 ->
        Process.sleep((4 - attempts) * 500)
        run_installer(runner, executable, arguments, options, attempts - 1)

      result ->
        result
    end
  end

  @impl true
  def validate(_options), do: Nerves.Runtime.validate_firmware()

  @impl true
  def synchronize(options) do
    runner = Keyword.get(options, :runner, &MuonTrap.cmd/3)
    fwup = Keyword.get(options, :fwup_path, "fwup")
    ops = Keyword.get(options, :ops_fw_path, "/usr/share/fwup/ops.fw")
    device = Keyword.get(options, :device, "/dev/rootdisk0")

    args = ["-a", "-i", ops, "-t", "synchronize", "-d", device, "-q", "-U", "--enable-trim"]

    case Command.run(runner, fwup, args, timeout: 30_000, stderr_to_stdout: true) do
      {:ok, {_output, 0}} ->
        :ok

      {:ok, {_output, :timeout}} ->
        {:error, :slot_synchronization_timeout}

      {:ok, {output, status}} ->
        {:error, {:slot_synchronization_failed, status, sanitize(output)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def revert(_options), do: Nerves.Runtime.revert(reboot: false)

  @impl true
  def reboot(options) do
    case Keyword.get(options, :reboot_method, :nerves_runtime) do
      :kernel_sysrq -> kernel_reboot()
      :nerves_runtime -> Nerves.Runtime.reboot()
    end
  end

  defp kernel_reboot do
    case File.write("/proc/sysrq-trigger", "b") do
      {:error, reason} -> {:error, {:kernel_reboot_failed, reason}}
      :ok -> {:error, :kernel_reboot_returned}
    end
  end

  defp active_value(key, fallback), do: KV.get_active(key) || KV.get(key) || fallback

  defp sanitize(output) do
    output
    |> IO.iodata_to_binary()
    |> String.trim()
    |> String.slice(0, 500)
  end
end
