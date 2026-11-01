defmodule NervesGate.Network.Settings do
  @moduledoc "Network's single durable settings record. Unsupported saved state is preserved, never migrated."
  alias NervesGate.Config

  @limit 16_384

  def load do
    with :ok <- independent_store() do
      case File.read(path()) do
        {:error, :enoent} -> validated(Config.defaults()["network"])
        {:ok, bytes} when byte_size(bytes) <= @limit -> decode(bytes)
        {:ok, _} -> unsupported()
        error -> error
      end
    end
  end

  def save(network) do
    with :ok <- independent_store(),
         {:ok, network} <- Config.validate_network(network) do
      bytes = Jason.encode!(%{schema: 1, network: network})
      if byte_size(bytes) <= @limit, do: commit(bytes), else: unsupported()
    end
  end

  defp decode(bytes) do
    with {:ok, %{"schema" => 1, "network" => network} = record} <- Jason.decode(bytes),
         true <- map_size(record) == 2 do
      validated(network)
    else
      _ -> unsupported()
    end
  end

  defp validated(network) do
    case Config.validate_network(network) do
      {:ok, network} -> {:ok, Config.from_network(network)}
      _ -> unsupported()
    end
  end

  # Check even when the new record exists: never silently ignore a second source
  # of saved network intent. Null persistence prevents VintageNet applying it.
  defp independent_store do
    directory = Application.fetch_env!(:vintage_net, :persistence_dir)

    case File.ls(directory) do
      {:ok, []} -> :ok
      {:error, :enoent} -> :ok
      {:ok, _} -> unsupported()
      error -> error
    end
  end

  defp commit(bytes) do
    file = path()
    directory = Path.dirname(file)
    temp = file <> ".#{Base.encode16(:crypto.strong_rand_bytes(12))}.tmp"

    try do
      with :ok <- File.mkdir_p(directory),
           :ok <- File.write(temp, bytes, [:binary, :exclusive, :sync]),
           :ok <- File.chmod(temp, 0o600),
           :ok <- File.rename(temp, file) do
        sync_directory(directory)
      end
    after
      File.rm(temp)
    end
  end

  defp sync_directory(path) do
    case :prim_file.open(String.to_charlist(path), [:read, :directory]) do
      {:ok, directory} ->
        try do
          case :prim_file.sync(directory) do
            :ok -> :ok
            _ -> {:error, :network_commit_unknown}
          end
        after
          :prim_file.close(directory)
        end

      _ ->
        {:error, :network_commit_unknown}
    end
  end

  defp path,
    do: Application.get_env(:nerves_gate, :network_settings, "/data/nerves_gate/network.json")

  defp unsupported do
    {:error,
     "Saved network settings are unsupported by this firmware or board. Settings were not changed. Use recovery access and an explicitly authorized external reprovisioning procedure."}
  end
end
