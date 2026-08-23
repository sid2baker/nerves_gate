defmodule NervesGate.Tailnet.Address do
  @moduledoc "Validates concrete IPv4 addresses from Tailscale's 100.64.0.0/10 range."

  @spec parse_ipv4(String.t()) :: {:ok, :inet.ip4_address()} | :error
  def parse_ipv4(address) when is_binary(address) do
    case :inet.parse_ipv4_address(String.to_charlist(address)) do
      {:ok, parsed} -> if(ipv4?(parsed), do: {:ok, parsed}, else: :error)
      {:error, _reason} -> :error
    end
  end

  @spec ipv4?(term()) :: boolean()
  def ipv4?({100, second, third, fourth}) do
    second in 64..127 and third in 0..255 and fourth in 0..255
  end

  def ipv4?(_address), do: false
end
