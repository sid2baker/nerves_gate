defmodule NervesGate.Plugins.Assignments do
  @moduledoc "Bounded current-only exclusive port intent, persisted by the plugin manager."
  @ids ~w(ttyS3 ttyS4 can0 can1)
  def ids, do: @ids
  def kind(id) when id in ["ttyS3", "ttyS4"], do: :serial
  def kind(id) when id in ["can0", "can1"], do: :can
  def kind(_), do: nil

  def read(file) do
    with {:ok, %{type: :regular, size: size}} when size <= 8192 <- File.lstat(file),
         {:ok, <<131, tag, _::binary>> = bytes} when tag != 80 <- File.read(file),
         {%{schema: 1, ports: ports} = value, used} <-
           :erlang.binary_to_term(bytes, [:safe, :used]),
         true <- used == byte_size(bytes) and map_size(value) == 2 and valid?(ports) do
      {:ok, ports}
    else
      {:error, :enoent} -> {:ok, %{}}
      _ -> {:error, :invalid_hardware_assignments}
    end
  rescue
    ArgumentError -> {:error, :invalid_hardware_assignments}
  end

  def persist(file, ports) do
    if valid?(ports),
      do:
        NervesGate.Plugins.Metadata.write(
          file,
          :erlang.term_to_binary(%{schema: 1, ports: ports})
        ),
      else: {:error, :invalid_hardware_assignments}
  end

  def valid?(ports) when is_map(ports) and map_size(ports) <= 4 do
    Enum.all?(ports, fn
      {id, %{enabled: enabled, plugin: plugin} = value} ->
        id in @ids and map_size(value) == 2 and is_boolean(enabled) and
          (plugin == nil or
             (is_binary(plugin) and byte_size(plugin) <= 255 and
                NervesGateSDK.Package.valid_name?(plugin)))

      _ ->
        false
    end)
  end

  def valid?(_), do: false

  defp requires_detection?(enabled, plugin), do: enabled or plugin != nil
  defp detected?(inventory, id), do: Enum.any?(inventory, &(&1.name == id and &1.present))

  def validate(id, enabled, plugin, inventory, capabilities) do
    cond do
      id not in @ids or not is_boolean(enabled) ->
        {:error, :invalid_hardware_assignment}

      requires_detection?(enabled, plugin) and not detected?(inventory, id) ->
        {:error, :hardware_missing}

      plugin != nil and kind(id) not in Map.get(capabilities, plugin, []) ->
        {:error, :ineligible_plugin}

      true ->
        :ok
    end
  end
end
