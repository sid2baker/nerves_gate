defmodule ModbusPlugin.Store do
  @moduledoc """
  Saved connection definitions: a map of ID to validated config, persisted as
  this plugin version's `NervesGateSDK.Storage` configuration term. Restoring
  never starts a connection. Missing configuration is empty; unavailable storage
  or a term that does not validate exactly is reported, never rewritten.
  """
  alias ModbusPlugin.Config

  @max_connections 16

  def restore do
    case NervesGateSDK.Storage.restore_config() do
      {:ok, configs} ->
        if valid?(configs), do: {:ok, configs}, else: {:error, :invalid_saved_configuration}

      :not_found ->
        {:ok, %{}}

      {:error, :invalid_configuration} ->
        {:error, :invalid_saved_configuration}

      {:error, reason} ->
        {:error, {:storage_unavailable, reason}}
    end
  end

  @doc "Validate one definition into a new map; nothing is persisted."
  def put(configs, id, params) do
    with {:ok, config} <- Config.validate(id, params),
         true <- Map.has_key?(configs, id) or map_size(configs) < @max_connections do
      {:ok, Map.put(configs, id, config)}
    else
      false -> {:error, :device_limit}
      error -> error
    end
  end

  def persist(configs), do: NervesGateSDK.Storage.save_config(configs)

  # Revalidate the exact normalized shape. Runtime paths, monitors and unknown
  # fields never acquire authority merely by appearing in a restored term.
  def valid?(configs) when is_map(configs) and map_size(configs) <= @max_connections,
    do: Enum.all?(configs, &valid_config?/1)

  def valid?(_), do: false

  defp valid_config?({id, %{mappings: mappings} = config}) when is_list(mappings),
    do:
      Enum.all?(mappings, &is_map/1) and
        Config.validate(id, Config.params(config)) == {:ok, config}

  defp valid_config?(_), do: false
end
