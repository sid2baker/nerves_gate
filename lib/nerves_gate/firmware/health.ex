defmodule NervesGate.Firmware.Health do
  @moduledoc "Pure public-state health policy plus bounded persistent-storage preflight checks."

  alias NervesGate.DeviceState.State
  alias NervesGate.Firmware.{Command, Release}
  alias NervesGate.Storage

  @headroom 32 * 1024 * 1024

  @spec preflight(State.t(), map(), Release.t(), Path.t(), keyword()) ::
          {:ok, map()} | {:error, map()}
  def preflight(%State{} = state, platform, %Release{} = release, root, options \\ []) do
    checks =
      post_boot(state)
      |> Map.put(:storage, storage_check(root, release.size, options))
      |> Map.put(:firmware, firmware_check(platform))

    result(checks)
  end

  @spec post_boot(State.t()) :: map()
  def post_boot(%State{} = state) do
    %{
      device_state: if(State.hydrated?(state), do: :ok, else: :state_starting),
      storage: if(storage_alarm?(state.alarms), do: :storage_unavailable, else: :ok),
      configuration: configuration_check(state.configuration),
      internet: online_check(state.internet, :internet_unavailable),
      tailnet: online_check(state.tailnet, :tailnet_unavailable),
      alarms: alarm_check(state.alarms)
    }
  end

  @spec healthy?(map()) :: boolean()
  def healthy?(checks), do: Enum.all?(checks, fn {_name, value} -> value == :ok end)

  defp result(checks), do: if(healthy?(checks), do: {:ok, checks}, else: {:error, checks})

  defp configuration_check(%{configured: true, pending: nil}), do: :ok

  defp configuration_check(%{pending: pending}) when not is_nil(pending),
    do: :configuration_change_in_progress

  defp configuration_check(_configuration), do: :configuration_incomplete

  defp online_check(%{online: true}, _error), do: :ok
  defp online_check(_status, error), do: error

  defp alarm_check(nil), do: :state_starting

  defp alarm_check(alarms) when is_list(alarms) do
    if Enum.any?(alarms, &(Map.get(&1, :level) == :error)),
      do: :critical_alarm,
      else: :ok
  end

  defp storage_alarm?(alarms) when is_list(alarms) do
    Enum.any?(alarms, &(Map.get(&1, :id) == "storage_failure"))
  end

  defp storage_alarm?(_alarms), do: false

  defp firmware_check(%{supported: true, validation: :validated}), do: :ok
  defp firmware_check(%{supported: false}), do: :firmware_updates_unsupported
  defp firmware_check(_platform), do: :current_firmware_unvalidated

  defp storage_check(root, artifact_size, options) do
    with :ok <- Storage.initialize(root),
         {:ok, available} <- available_space(root, options),
         true <- available >= artifact_size + @headroom do
      :ok
    else
      false -> :insufficient_storage
      {:error, _reason} -> :storage_unavailable
    end
  end

  defp available_space(root, options) do
    case Keyword.get(options, :free_space_bytes) do
      bytes when is_integer(bytes) and bytes >= 0 ->
        {:ok, bytes}

      _dynamic ->
        options
        |> Keyword.get(:free_space, &free_space/1)
        |> then(& &1.(root))
    end
  end

  defp free_space(path), do: free_space(path, 3)

  defp free_space(path, attempts) do
    case Command.run(&MuonTrap.cmd/3, "df", ["-Pk", path],
           timeout: 5_000,
           stderr_to_stdout: true
         ) do
      {:ok, {output, 0}} ->
        parse_free_space(IO.iodata_to_binary(output))

      {:ok, {_output, _status}} ->
        {:error, :df_failed}

      {:error, _reason} when attempts > 1 ->
        Process.sleep((4 - attempts) * 250)
        free_space(path, attempts - 1)

      {:error, _reason} ->
        {:error, :df_unavailable}
    end
  end

  defp parse_free_space(output) do
    output
    |> String.split("\n", trim: true)
    |> List.last()
    |> parse_free_space_line()
  end

  defp parse_free_space_line(nil), do: {:error, :invalid_df_output}

  defp parse_free_space_line(line) do
    case String.split(line, ~r/\s+/, trim: true) do
      [_filesystem, _blocks, _used, available | _rest] -> parse_available_space(available)
      _invalid -> {:error, :invalid_df_output}
    end
  end

  defp parse_available_space(value) do
    case Integer.parse(value) do
      {kilobytes, ""} -> {:ok, kilobytes * 1024}
      _invalid -> {:error, :invalid_df_output}
    end
  end
end
