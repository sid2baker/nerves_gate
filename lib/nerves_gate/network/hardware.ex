defmodule NervesGate.Network.Hardware do
  @moduledoc "Discovers local interfaces without assuming Wi-Fi is present."

  @spec interfaces() :: [map()]
  def interfaces do
    case File.ls("/sys/class/net") do
      {:ok, names} ->
        names
        |> Enum.reject(&(&1 in ["lo", "tailscale0"]))
        |> Enum.sort()
        |> Enum.map(&describe/1)

      {:error, _reason} ->
        []
    end
  end

  @spec describe(String.t()) :: map()
  def describe(name) do
    %{
      name: name,
      kind: if(File.dir?("/sys/class/net/#{name}/wireless"), do: :wifi, else: :ethernet),
      carrier: read_carrier(name),
      mac: read_trimmed("/sys/class/net/#{name}/address")
    }
  end

  defp read_carrier(name) do
    case read_trimmed("/sys/class/net/#{name}/carrier") do
      "1" -> true
      "0" -> false
      _unknown -> nil
    end
  end

  defp read_trimmed(path) do
    case File.read(path) do
      {:ok, value} -> String.trim(value)
      {:error, _reason} -> nil
    end
  end
end
