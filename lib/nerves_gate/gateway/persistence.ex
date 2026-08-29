defmodule NervesGate.Gateway.Persistence do
  @moduledoc "Hydrates and atomically persists firmware-tagged gateway settings."

  alias NervesGate.Gateway.Settings
  alias NervesGate.Storage

  @slots ["a", "b"]
  @legacy_files ~w(setup.json network.json cluster.json device.json settings-change.json)

  @type hydration :: %{firmware: map(), current: map(), candidate: map() | nil}

  @spec settings_path(String.t(), Path.t()) :: Path.t()
  def settings_path(slot, root) when slot in @slots do
    Storage.path("settings-#{slot}.json", root)
  end

  @spec candidate_path(Path.t()) :: Path.t()
  def candidate_path(root), do: Storage.path("settings-candidate.json", root)

  @spec hydrate(Path.t(), map()) :: {:ok, hydration()} | {:error, term()}
  def hydrate(root, firmware) do
    with :ok <- Storage.initialize(root),
         :ok <- clear_legacy_settings(root),
         {:ok, firmware} <- normalize_firmware(firmware),
         :ok <- ensure_slot_files(root, firmware),
         {:ok, current} <- load_current(root, firmware),
         {:ok, candidate} <- read_candidate_or_nil(root) do
      {:ok, %{firmware: firmware, current: current, candidate: candidate}}
    end
  end

  @spec write_slot(map(), String.t(), Path.t()) :: :ok | {:error, term()}
  def write_slot(settings, slot, root) do
    with {:ok, settings} <- Settings.validate(settings) do
      Storage.write_json(settings_path(slot, root), settings) |> storage_result()
    end
  end

  @spec write_candidate(map(), Path.t()) :: :ok | {:error, term()}
  def write_candidate(settings, root) do
    with {:ok, settings} <- Settings.validate(settings) do
      Storage.write_json(candidate_path(root), settings) |> storage_result()
    end
  end

  @spec clear_candidate(Path.t()) :: :ok | {:error, term()}
  def clear_candidate(root) do
    case File.rm(candidate_path(root)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> storage_result({:error, reason})
    end
  end

  @spec promote_candidate(String.t(), Path.t()) :: :ok | {:error, term()}
  def promote_candidate(slot, root) when slot in @slots do
    Storage.replace(candidate_path(root), settings_path(slot, root)) |> storage_result()
  end

  defp ensure_slot_files(root, firmware) do
    Enum.reduce_while(@slots, :ok, &ensure_slot(&1, &2, root, firmware))
  end

  defp ensure_slot(slot, :ok, root, firmware) do
    case read_slot(slot, root) do
      {:ok, nil} ->
        continue_or_halt(write_slot(Settings.default(firmware.slots[slot]), slot, root))

      {:ok, _settings} ->
        {:cont, :ok}

      {:error, _reason} ->
        NervesGate.Alarms.storage_failure(true)
        continue_or_halt(write_slot(Settings.default(firmware.slots[slot]), slot, root))
    end
  end

  defp continue_or_halt(:ok), do: {:cont, :ok}
  defp continue_or_halt({:error, reason}), do: {:halt, {:error, reason}}

  defp load_current(root, firmware) do
    slot = firmware.active
    other_slot = opposite(slot)

    with {:ok, current} when not is_nil(current) <- read_slot(slot, root),
         {:ok, other} when not is_nil(other) <- read_slot(other_slot, root) do
      current_tagged? = current["firmware"] == firmware.slots[slot]

      cond do
        current_tagged? and current["configured"] -> {:ok, current}
        other["configured"] -> migrate_current(root, firmware, other)
        current_tagged? -> {:ok, current}
        true -> migrate_current(root, firmware, current)
      end
    end
  end

  defp migrate_current(root, firmware, source) do
    migrated = Map.put(source, "firmware", firmware.slots[firmware.active])

    with :ok <- write_slot(migrated, firmware.active, root) do
      {:ok, migrated}
    end
  end

  defp read_slot(slot, root) do
    read_settings(settings_path(slot, root))
  end

  defp read_candidate_or_nil(root) do
    case read_settings(candidate_path(root)) do
      {:ok, candidate} ->
        {:ok, candidate}

      {:error, _reason} ->
        NervesGate.Alarms.storage_failure(true)
        {:ok, nil}
    end
  end

  defp read_settings(path) do
    case Storage.read_json(path, &Settings.validate/1, nil) do
      {:error, {:invalid, reason}} ->
        NervesGate.Alarms.storage_failure(true)

        case Storage.quarantine(path) do
          :ok -> {:error, {:corrupt, Path.basename(path), reason}}
          {:error, quarantine_reason} -> {:error, {:quarantine_failed, quarantine_reason}}
        end

      result ->
        result
    end
  end

  defp clear_legacy_settings(root) do
    Enum.reduce_while(@legacy_files, :ok, fn name, :ok ->
      case File.rm(Storage.path(name, root)) do
        :ok -> {:cont, :ok}
        {:error, :enoent} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {name, reason}}}
      end
    end)
  end

  defp storage_result(:ok), do: :ok

  defp storage_result({:error, _reason} = error) do
    NervesGate.Alarms.storage_failure(true)
    error
  end

  defp normalize_firmware(%{active: active, slots: slots}) when active in @slots do
    normalized = Map.new(@slots, fn slot -> {slot, normalize_tag(slot, slots[slot])} end)
    {:ok, %{active: active, slots: normalized}}
  end

  defp normalize_firmware(_firmware), do: {:error, :invalid_firmware_metadata}

  defp normalize_tag(slot, tag) do
    tag = Map.new(tag || %{}, fn {key, value} -> {to_string(key), value} end)

    %{
      "slot" => slot,
      "uuid" => to_string(tag["uuid"] || "unknown"),
      "version" => to_string(tag["version"] || "unknown")
    }
  end

  defp opposite("a"), do: "b"
  defp opposite("b"), do: "a"
end
