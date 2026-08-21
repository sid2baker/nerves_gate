defmodule NervesGate.Identity do
  @moduledoc """
  Derives the stable device identity from Nerves provisioning data.
  """

  @max_machine_id_length 48

  @type t :: %{machine_id: String.t(), hostname: String.t(), setup_ssid: String.t()}

  @spec get() :: t()
  def get do
    machine_id =
      Nerves.Runtime.serial_number()
      |> normalize_machine_id()
      |> fallback_machine_id()

    %{
      machine_id: machine_id,
      hostname: "nervesgate-#{machine_id}",
      setup_ssid: "NervesGate-#{machine_id}"
    }
  end

  @spec normalize_machine_id(term()) :: String.t()
  def normalize_machine_id(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9-]+/u, "-")
    |> String.trim("-")
    |> String.slice(0, @max_machine_id_length)
  end

  def normalize_machine_id(_value), do: ""

  defp fallback_machine_id(value) when value not in ["", "unconfigured"], do: value

  defp fallback_machine_id(_value) do
    seed = read_first(["/sys/class/dmi/id/product_uuid", "/etc/machine-id"])
    digest = :crypto.hash(:sha256, seed) |> Base.encode16(case: :lower)
    String.slice(digest, 0, 16)
  end

  defp read_first(paths) do
    Enum.find_value(paths, "nervesgate-unprovisioned", fn path ->
      case File.read(path) do
        {:ok, value} -> String.trim(value)
        {:error, _reason} -> nil
      end
    end)
  end
end
