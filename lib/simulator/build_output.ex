defmodule Simulator.BuildOutput do
  @moduledoc """
  Runs `mix firmware` under MuonTrap, streams its output to the terminal and
  forwards the latest complete line in each chunk to the simulator. Flushes the
  final fragment on completion.
  """
  defstruct [:report, fragment: ""]

  # Acknowledging output races with the wrapper's exit: a late acknowledgement
  # fails with EPIPE, kills the caller and loses the exit status. A 1 GiB window
  # avoids acknowledgements for real builds; larger output is acknowledged in
  # rare batches so the wrapper never stalls.
  @window 1_073_741_824
  @ack_batch div(@window, 2)

  @doc "Run a command, reporting progress lines. Returns its exit status."
  def run(command, args, options, report) do
    executable = System.find_executable(command) || raise "#{command} not found"

    # MuonTrap's wrapper kills the build if the simulator exits.
    port =
      Port.open({:spawn_executable, MuonTrap.muontrap_path()}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [
          "--capture-output",
          "--capture-stderr",
          "--stdio-window",
          "#{@window}",
          "--",
          executable | args
        ],
        cd: Keyword.fetch!(options, :cd),
        env: for({key, value} <- Keyword.get(options, :env, []), do: env(key, value))
      ])

    try do
      collect_port(port, new(report), 0)
    after
      if Port.info(port), do: Port.close(port)
    end
  end

  # A nil value unsets the variable for the child.
  defp env(key, nil), do: {String.to_charlist(key), false}
  defp env(key, value), do: {String.to_charlist(key), String.to_charlist(value)}

  defp collect_port(port, output, unacknowledged) do
    receive do
      {^port, {:data, chunk}} ->
        unacknowledged = acknowledge(port, unacknowledged + byte_size(chunk))
        collect_port(port, collect(output, chunk), unacknowledged)

      {^port, {:exit_status, status}} ->
        done(output)
        status
    end
  end

  defp acknowledge(port, bytes) when bytes >= @ack_batch do
    MuonTrap.Port.report_bytes_handled(port, bytes)
    0
  end

  defp acknowledge(_port, bytes), do: bytes

  def new(report), do: %__MODULE__{report: report}

  def collect(output, chunk) do
    buffered = output.fragment <> chunk
    [fragment | lines] = String.split(buffered, ["\n", "\r"]) |> Enum.reverse()
    IO.write(binary_part(buffered, 0, byte_size(buffered) - byte_size(fragment)))
    report(%{output | fragment: fragment}, Enum.find_value(lines, &line/1))
  end

  def done(output) do
    IO.write(output.fragment)
    report(%{output | fragment: ""}, line(output.fragment))
  end

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

  defp report(output, nil), do: output

  defp report(output, line) do
    output.report.(line)
    output
  end
end
