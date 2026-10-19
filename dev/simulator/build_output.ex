defmodule NervesGate.Simulator.BuildOutput do
  @moduledoc """
  Collects `mix firmware` output: echoes it to the terminal and reports the
  latest line, at most every 250 ms and once at the end, so the simulator site
  shows build progress and the last line of a failed build.
  """
  defstruct [:report, :reported_at, pending: nil, fragment: ""]

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
      now = System.monotonic_time(:millisecond)
      buffered = output.fragment <> chunk
      [fragment | lines] = String.split(buffered, ["\n", "\r"]) |> Enum.reverse()

      IO.write(binary_part(buffered, 0, byte_size(buffered) - byte_size(fragment)))

      output = %{
        output
        | fragment: fragment,
          pending: Enum.find_value(lines, &@for.line/1) || output.pending
      }

      due = output.reported_at == nil or now - output.reported_at >= 250

      if output.pending && due,
        do: report(%{output | reported_at: now}),
        else: output
    end

    defp collect(output, :done) do
      IO.write(output.fragment)
      report(%{output | pending: @for.line(output.fragment) || output.pending})
    end

    defp collect(_, :halt), do: :ok

    defp report(%{pending: nil} = output), do: output

    defp report(output) do
      output.report.(output.pending)
      %{output | pending: nil}
    end
  end
end
