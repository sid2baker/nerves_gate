defmodule NervesGate.Plugins.Assignments do
  @moduledoc """
  Bounded current-only exclusive resource intent, persisted by the plugin manager.
  Persistence checks structure only; whether a resource exists and which plugins
  may own it comes from the current hardware inventory. Saved intent for a
  resource the board no longer declares is kept untouched and cannot be enabled.
  """
  @max_resources 64

  def read(file) do
    with {:ok, %{type: :regular, size: size}} when size <= 32_768 <- File.lstat(file),
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

  def valid?(ports) when is_map(ports) and map_size(ports) <= @max_resources do
    Enum.all?(ports, fn
      {id, %{enabled: enabled, plugin: plugin} = value} ->
        valid_id?(id) and map_size(value) == 2 and is_boolean(enabled) and
          (plugin == nil or
             (is_binary(plugin) and byte_size(plugin) <= 255 and
                NervesGateSDK.Package.valid_name?(plugin)))

      _ ->
        false
    end)
  end

  def valid?(_), do: false

  @doc "A bounded resource ID such as `ttyS3`; whether it exists is the inventory's fact."
  def valid_id?(id),
    do: is_binary(id) and byte_size(id) in 1..32 and id =~ ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/

  def validate(id, enabled, plugin, inventory, capabilities) do
    if valid?(%{id => %{enabled: enabled, plugin: plugin}}) do
      # Release is always possible, even if this board no longer declares the ID.
      if enabled == false and plugin == nil,
        do: :ok,
        else: eligible(Enum.find(inventory, &(&1.id == id)), plugin, capabilities)
    else
      {:error, :invalid_hardware_assignment}
    end
  end

  @doc "Recheck enabled saved intent against this boot's inventory before plugin activation."
  def validate_plugin(plugin, assignments, inventory, kinds) do
    Enum.reduce_while(assignments, :ok, fn
      {id, %{enabled: true, plugin: ^plugin}}, :ok ->
        case validate(id, true, plugin, inventory, %{plugin => kinds}) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _, :ok ->
        {:cont, :ok}
    end)
  end

  defp eligible(nil, _, _), do: {:error, :hardware_missing}
  defp eligible(%{present: false}, _, _), do: {:error, :hardware_missing}
  defp eligible(%{assignable: false}, _, _), do: {:error, :hardware_not_assignable}
  defp eligible(_, nil, _), do: :ok

  defp eligible(port, plugin, capabilities) do
    if port.kind in Map.get(capabilities, plugin, []),
      do: :ok,
      else: {:error, :ineligible_plugin}
  end
end
