defmodule NervesGate.Cluster.Group do
  @moduledoc "Validates the shared public cluster-group identifier."

  @pattern ~r/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/

  @spec validate(term()) :: {:ok, String.t() | nil} | {:error, :invalid_cluster_group}
  def validate(value) when value in [nil, ""], do: {:ok, nil}

  def validate(value) when is_binary(value) and byte_size(value) in 1..128 do
    value = String.trim(value)

    if byte_size(value) in 1..128 and String.match?(value, @pattern),
      do: {:ok, value},
      else: {:error, :invalid_cluster_group}
  end

  def validate(_value), do: {:error, :invalid_cluster_group}
end
