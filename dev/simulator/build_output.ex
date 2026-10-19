defmodule NervesGate.Simulator.BuildOutput do
  @moduledoc """
  Collects `mix firmware` output: echoes it to the terminal and reports the
  latest line, at most every 250 ms and once at the end, so the simulator site
  shows build progress and the last line of a failed build.
  """
  defstruct [:report, :reported_at, pending: nil]

  def new(report), do: %__MODULE__{report: report}

  def line(chunk) do
    chunk
    |> String.replace_invalid()
    |> String.replace(~r/\e\[[0-9;]*[A-Za-z]/, "")
    |> String.split(["\n", "\r"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> List.last()
    |> then(&(&1 && String.slice(&1, 0, 200)))
  end

  defimpl Collectable do
    def into(output), do: {output, &collect/2}

    defp collect(output, {:cont, chunk}) do
      IO.write(chunk)
      now = System.monotonic_time(:millisecond)
      output = %{output | pending: @for.line(chunk) || output.pending}

      due = output.reported_at == nil or now - output.reported_at >= 250

      if output.pending && due,
        do: report(%{output | reported_at: now}),
        else: output
    end

    defp collect(output, :done), do: report(output)
    defp collect(_, :halt), do: :ok

    defp report(%{pending: nil} = output), do: output

    defp report(output) do
      output.report.(output.pending)
      %{output | pending: nil}
    end
  end
end
