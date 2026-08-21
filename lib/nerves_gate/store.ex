defmodule NervesGate.Store do
  @moduledoc "Human-readable, atomic persistence under `/data`."

  alias NervesGate.AtomicFile
  alias NervesGate.Network.Config

  @phases ~w(internet tailscale cluster ready recovery)
  @default_setup %{"version" => 1, "phase" => "internet"}

  @spec root() :: Path.t()
  def root, do: Application.fetch_env!(:nerves_gate, :data_dir)

  @spec initialize(Path.t()) :: :ok | {:error, term()}
  def initialize(root \\ root()) do
    with :ok <- File.mkdir_p(root),
         :ok <- File.chmod(root, 0o700),
         :ok <- AtomicFile.write(Path.join(root, ".write-probe"), "ok") do
      File.rm(Path.join(root, ".write-probe"))
      :ok
    end
  end

  @spec read_setup(Path.t()) :: {:ok, map()} | {:error, term()}
  def read_setup(root \\ root()) do
    read_json(Path.join(root, "setup.json"), &validate_setup/1, @default_setup)
  end

  @spec write_phase(atom(), Path.t()) :: :ok | {:error, term()}
  def write_phase(phase, root \\ root())
      when phase in [:internet, :tailscale, :cluster, :ready, :recovery] do
    write_json(Path.join(root, "setup.json"), %{"version" => 1, "phase" => Atom.to_string(phase)})
  end

  @spec read_network(Path.t()) :: {:ok, Config.t() | nil} | {:error, term()}
  def read_network(root \\ root()) do
    read_json(Path.join(root, "network.json"), &Config.from_persisted/1, nil)
  end

  @spec write_network(Config.t(), Path.t()) :: :ok | {:error, term()}
  def write_network(%Config{} = config, root \\ root()) do
    write_json(Path.join(root, "network.json"), Config.to_persisted(config))
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

  @spec write_json(Path.t(), map()) :: :ok | {:error, term()}
  def write_json(path, value) do
    with {:ok, json} <- Jason.encode(value, pretty: true) do
      AtomicFile.write(path, json <> "\n")
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

  defp validate_setup(%{"version" => 1, "phase" => phase}) when phase in @phases,
    do: {:ok, %{"version" => 1, "phase" => phase}}

  defp validate_setup(_setup), do: {:error, :invalid_setup}
end
