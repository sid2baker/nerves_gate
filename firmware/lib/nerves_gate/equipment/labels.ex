defmodule NervesGate.Equipment.Labels do
  @moduledoc "Bounded, local labels keyed by confirmed equipment scope and MAC, not a guessed identity."
  @path "/data/nerves_gate/equipment_labels.json"
  @limit 256

  def normalize(value) when is_binary(value) and byte_size(value) <= 256 do
    if String.valid?(value) and String.length(value) <= 64 and
         not Regex.match?(~r/[\x00-\x1F\x7F]/u, value),
       do: {:ok, String.trim(value)},
       else: {:error, :invalid_label}
  end

  def normalize(_), do: {:error, :invalid_label}

  def put(labels, key, value) do
    with {:ok, label} <- normalize(value) do
      updated = if label == "", do: Map.delete(labels, key), else: Map.put(labels, key, label)
      if map_size(updated) <= @limit, do: {:ok, updated}, else: {:error, :label_limit}
    end
  end

  def load(path \\ @path) do
    case File.stat(path) do
      {:error, :enoent} -> {:ok, %{}}
      {:ok, %{size: size}} when size <= 131_072 -> read(path)
      _ -> {:error, :labels_unavailable}
    end
  end

  def save(labels, path \\ @path) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path <> ".new", Jason.encode!(labels), [:sync]),
         :ok <- File.rename(path <> ".new", path) do
      :ok
    else
      _ -> {:error, :labels_unavailable}
    end
  end

  defp read(path) do
    with {:ok, json} <- File.read(path),
         {:ok, labels} when is_map(labels) and map_size(labels) <= @limit <- Jason.decode(json),
         true <- Enum.all?(labels, &valid?/1) do
      {:ok, labels}
    else
      _ -> {:error, :labels_unavailable}
    end
  end

  defp valid?({key, value}),
    do: Regex.match?(~r/\A[0-9a-f]{64}\z/, key) and normalize(value) == {:ok, value}
end
