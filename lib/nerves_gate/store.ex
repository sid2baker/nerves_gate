defmodule NervesGate.Store do
  @moduledoc "Atomic JSON persistence under `/data`."

  alias NervesGate.AtomicFile

  @spec root() :: Path.t()
  def root, do: Application.fetch_env!(:nerves_gate, :data_dir)

  @spec initialize(Path.t()) :: :ok | {:error, term()}
  def initialize(root \\ root()) do
    probe = Path.join(root, ".write-probe")

    with :ok <- File.mkdir_p(root),
         :ok <- File.chmod(root, 0o700),
         :ok <- AtomicFile.write(probe, "ok") do
      File.rm(probe)
    end
  end

  @spec settings_path(String.t(), Path.t()) :: Path.t()
  def settings_path(slot, root \\ root()) when slot in ["a", "b"] do
    Path.join(root, "settings-#{slot}.json")
  end

  @spec candidate_path(Path.t()) :: Path.t()
  def candidate_path(root \\ root()), do: Path.join(root, "settings-candidate.json")

  @spec clear_legacy_settings(Path.t()) :: :ok | {:error, term()}
  def clear_legacy_settings(root \\ root()) do
    ~w(setup.json network.json cluster.json device.json settings-change.json)
    |> Enum.reduce_while(:ok, fn name, :ok ->
      case File.rm(Path.join(root, name)) do
        :ok -> {:cont, :ok}
        {:error, :enoent} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {name, reason}}}
      end
    end)
  end

  @spec promote_candidate(String.t(), Path.t()) :: :ok | {:error, term()}
  def promote_candidate(slot, root \\ root()) when slot in ["a", "b"] do
    AtomicFile.replace(candidate_path(root), settings_path(slot, root))
  end

  @spec clear_candidate(Path.t()) :: :ok | {:error, term()}
  def clear_candidate(root \\ root()) do
    case File.rm(candidate_path(root)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec read_json(Path.t(), (map() -> {:ok, term()}), term()) :: {:ok, term()} | {:error, term()}
  def read_json(path, validator, missing) do
    case File.read(path) do
      {:ok, contents} ->
        with {:ok, decoded} <- Jason.decode(contents),
             {:ok, valid} <- validator.(decoded) do
          {:ok, valid}
        else
          {:error, reason} ->
            mark_corrupt(path)
            {:error, {:corrupt, Path.basename(path), reason}}
        end

      {:error, :enoent} ->
        {:ok, missing}

      {:error, reason} ->
        {:error, {:read_failed, Path.basename(path), reason}}
    end
  end

  @spec write_json(Path.t(), map(), keyword()) :: :ok | {:error, term()}
  def write_json(path, value, options \\ []) do
    with {:ok, json} <- Jason.encode(value, pretty: true) do
      AtomicFile.write(path, json <> "\n", options)
    end
  end

  @spec mark_corrupt(Path.t()) :: :ok | {:error, term()}
  def mark_corrupt(path) do
    case File.rename(path, "#{path}.corrupt-#{System.system_time(:millisecond)}") do
      :ok -> :ok
      {:error, :enoent} -> :ok
      error -> error
    end
  end
end
