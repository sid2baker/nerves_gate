defmodule Workbench.DeviceInspection.Logs do
  @moduledoc false

  def format(entries, level) do
    {rows, _} =
      entries
      |> Enum.filter(&(Logger.compare_levels(&1.level, level) != :lt))
      |> Enum.map_reduce(16_000, fn entry, budget ->
        message = clean_message(entry.message) |> clip(min(2_000, budget))

        row = %{
          index: Keyword.get(entry.metadata, :index),
          timestamp: entry.timestamp,
          level: entry.level,
          message: message
        }

        {row, budget - byte_size(message)}
      end)

    Enum.reject(rows, &(&1.message == ""))
  end

  defp clean_message(message) do
    message
    |> IO.iodata_to_binary()
    |> String.split(~r/\n(?:Last message|State:|Client |\s*Session:)/, parts: 2)
    |> hd()
    |> String.split("\n")
    |> Enum.reject(
      &Regex.match?(~r/Parameters:|Session:|cookie|token|password|authorization|secret/i, &1)
    )
    |> Enum.join("\n")
    |> String.replace(~r/https?:\/\/[^\s"<>]+/, "[url]")
  end

  defp clip(text, bytes) do
    text |> binary_part(0, min(byte_size(text), bytes)) |> String.replace_invalid("")
  end
end
