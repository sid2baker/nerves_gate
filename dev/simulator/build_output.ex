defmodule NervesGate.Simulator.BuildOutput do
  @moduledoc """
  Streams `mix firmware` output to the terminal and forwards the latest complete
  line in each chunk to the simulator. Flushes the final fragment on completion.
  """
  defstruct [:report, fragment: ""]

  def new(report), do: %__MODULE__{report: report}

  def line(line) do
    line
    |> String.replace_invalid()
    |> String.replace(~r/\e\[[0-9;]*[A-Za-z]/, "")
    |> String.trim()
    |> case do
      "" -> nil
      line -> String.slice(line, 0, 200)
    end
  end

  defimpl Collectable do
    def into(output), do: {output, &collect/2}

    defp collect(output, {:cont, chunk}) do
      buffered = output.fragment <> chunk
      [fragment | lines] = String.split(buffered, ["\n", "\r"]) |> Enum.reverse()

      IO.write(binary_part(buffered, 0, byte_size(buffered) - byte_size(fragment)))

      report(%{output | fragment: fragment}, Enum.find_value(lines, &@for.line/1))
    end

    defp collect(output, :done) do
      IO.write(output.fragment)
      report(output, @for.line(output.fragment))
    end

    defp collect(_, :halt), do: :ok

    defp report(output, nil), do: output

    defp report(output, line) do
      output.report.(line)
      output
    end
  end
end
