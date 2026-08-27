defmodule NervesGate.Firmware.Manifest do
  @moduledoc "Detached Ed25519 verification for exact release-manifest bytes."

  @maximum_size 64 * 1024

  @spec verify(binary(), binary(), [String.t()]) :: {:ok, map()} | {:error, atom()}
  def verify(contents, encoded_signature, public_keys)
      when is_binary(contents) and is_binary(encoded_signature) and is_list(public_keys) do
    with :ok <- validate_size(contents),
         {:ok, signature} <- decode(encoded_signature),
         true <- byte_size(signature) == 64,
         {:ok, keys} <- decode_keys(public_keys),
         true <- Enum.any?(keys, &valid_signature?(contents, signature, &1)),
         {:ok, manifest} <- decode_manifest(contents) do
      {:ok, manifest}
    else
      false -> {:error, :invalid_manifest_signature}
      {:error, _reason} = error -> error
    end
  end

  def verify(_contents, _signature, _keys), do: {:error, :invalid_manifest}

  defp validate_size(contents) when byte_size(contents) in 1..@maximum_size, do: :ok
  defp validate_size(_contents), do: {:error, :invalid_manifest_size}

  defp decode(value) do
    case Base.decode64(String.trim(value)) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :invalid_manifest_signature}
    end
  end

  defp decode_keys([]), do: {:error, :no_trusted_manifest_keys}

  defp decode_keys(keys) do
    decoded =
      Enum.flat_map(keys, fn key ->
        case decode(key) do
          {:ok, value} when byte_size(value) == 32 -> [value]
          _invalid -> []
        end
      end)

    if decoded == [], do: {:error, :no_trusted_manifest_keys}, else: {:ok, decoded}
  end

  defp decode_manifest(contents) do
    case Jason.decode(contents) do
      {:ok, manifest} when is_map(manifest) -> {:ok, manifest}
      {:ok, _invalid} -> {:error, :invalid_manifest}
      {:error, _reason} -> {:error, :invalid_manifest}
    end
  end

  defp valid_signature?(contents, signature, public_key) do
    :crypto.verify(:eddsa, :none, contents, signature, [public_key, :ed25519])
  rescue
    _error -> false
  end
end
