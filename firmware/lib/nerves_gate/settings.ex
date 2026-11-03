defmodule NervesGate.Settings do
  @moduledoc """
  Persistent device-local configuration, one PropertyTable under
  `/data/nerves_gate/settings`.

  Each domain owns its keys and validates its own values; this module only
  stores them. A write is durable once `put/2` or `delete/1` returns `:ok`.
  On `{:error, :commit_unknown}` the previous value is restored in memory, so a
  later unrelated flush cannot commit it; the disk may hold either value.
  """

  @path "/data/nerves_gate/settings"

  def child_spec(opts) do
    path = Keyword.get(opts, :path, @path)
    :persistent_term.put({__MODULE__, :path}, path)
    PropertyTable.child_spec(name: __MODULE__, persist_data_path: path)
  end

  @doc "PropertyTable's committed data file, for fault-injection tests and scenarios."
  def file(path \\ @path), do: Path.join([path, Atom.to_string(__MODULE__), "data.ptable"])

  def get(key, default \\ nil), do: PropertyTable.get(__MODULE__, key, default)

  def put(key, value), do: write(key, fn -> PropertyTable.put(__MODULE__, key, value) end)
  def delete(key), do: write(key, fn -> PropertyTable.delete(__MODULE__, key) end)

  defp write(key, change) do
    previous = PropertyTable.fetch_with_timestamp(__MODULE__, key)
    change.()

    # PropertyTable renames the new file into place but does not sync the
    # directory, so without this a power cut can bring back the old file.
    with :ok <- PropertyTable.flush_to_disk(__MODULE__),
         :ok <- sync_directory() do
      :ok
    else
      _ ->
        case previous do
          {:ok, value, _} -> PropertyTable.put(__MODULE__, key, value)
          :error -> PropertyTable.delete(__MODULE__, key)
        end

        {:error, :commit_unknown}
    end
  end

  defp sync_directory do
    path = :persistent_term.get({__MODULE__, :path})
    NervesGate.Plugins.Metadata.sync_directory(Path.dirname(file(path)))
  end
end
