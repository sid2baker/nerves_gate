defmodule ModbusPlugin.Profiles do
  @moduledoc """
  Optional read-only mapping drafts, never automatic device identification or
  endpoint registration. Loading a template only replaces the editor's draft;
  the operator must check the register map for the exact equipment and save it.
  SunSpec discovery yields model IDs and addresses, not guessed point meanings.
  """

  @doc "Solis hybrid telemetry, using zero-based protocol addresses."
  def solis do
    [
      point("pv1_voltage", 33049, "u16", 0.1, "V"),
      point("pv1_current", 33050, "u16", 0.1, "A"),
      point("pv2_voltage", 33051, "u16", 0.1, "V"),
      point("pv2_current", 33052, "u16", 0.1, "A"),
      point("pv_power", 33057, "u32", 1, "W"),
      point("temperature", 33093, "s16", 0.1, "°C"),
      point("battery_soc", 33139, "u16", 1, "%"),
      point("battery_power", 33149, "s32", 1, "W")
    ]
  end

  @doc "SunSpec common-model strings, only when discovery actually found model 1."
  def sunspec(%{id: 1, address: header, length: length}) when length >= 50 do
    [
      text("manufacturer", header + 2, 16),
      text("model", header + 18, 16),
      text("firmware", header + 42, 8)
    ]
  end

  def sunspec(_), do: []

  defp point(id, address, type, scale, unit) do
    %{
      "id" => id,
      "table" => "input",
      "address" => address,
      "access" => "read",
      "type" => type,
      "scale" => scale,
      "unit" => unit
    }
  end

  defp text(id, address, length) do
    %{
      "id" => id,
      "table" => "holding",
      "address" => address,
      "access" => "read",
      "type" => "ascii",
      "length" => length
    }
  end
end
