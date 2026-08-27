defmodule NervesGate.Firmware.Persistence do
  @moduledoc "Durable, secret-free firmware transaction journal."

  alias NervesGate.Firmware.Release
  alias NervesGate.Storage

  @schema "nerves_gate.firmware-transaction.v1"
  @phases ["ready", "installing", "rebooting", "trial", "rolling_back"]

  @spec load(Path.t()) :: {:ok, map() | nil} | {:error, term()}
  def load(root) do
    path = path(root)

    case Storage.read_json(path, &validate/1, nil) do
      {:ok, journal} ->
        {:ok, journal}

      {:error, reason} ->
        Storage.quarantine(path)
        {:error, {:invalid_firmware_journal, reason}}
    end
  end

  @spec save(Path.t(), map()) :: :ok | {:error, term()}
  def save(root, journal) do
    encoded = %{
      "schema" => @schema,
      "phase" => Atom.to_string(Map.fetch!(journal, :phase)),
      "release" => journal |> Map.fetch!(:release) |> Release.to_map(),
      "previous_uuid" => Map.get(journal, :previous_uuid),
      "source_connection" => Map.get(journal, :source_connection),
      "source_boot_id" => Map.get(journal, :source_boot_id)
    }

    Storage.write_json(path(root), encoded)
  end

  @spec clear(Path.t()) :: :ok | {:error, term()}
  def clear(root) do
    case File.rm(path(root)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec path(Path.t()) :: Path.t()
  def path(root), do: Path.join([root, "firmware", "transaction.json"])

  defp validate(%{
         "schema" => @schema,
         "phase" => phase,
         "release" => release,
         "previous_uuid" => previous_uuid,
         "source_connection" => source_connection,
         "source_boot_id" => source_boot_id
       })
       when phase in @phases and (is_binary(previous_uuid) or is_nil(previous_uuid)) and
              (is_binary(source_connection) or is_nil(source_connection)) and
              (is_binary(source_boot_id) or is_nil(source_boot_id)) do
    with {:ok, release} <- Release.from_map(release) do
      {:ok,
       %{
         phase: String.to_existing_atom(phase),
         release: release,
         previous_uuid: previous_uuid,
         source_connection: source_connection,
         source_boot_id: source_boot_id
       }}
    end
  end

  defp validate(_value), do: {:error, :invalid_journal}
end
