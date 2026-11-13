defmodule Workbench.FirmwareCommand do
  @moduledoc """
  Bounded workstation firmware commands, contained by MuonTrap.

  A linked task bounds execution and closes the command's port on cancellation.
  Output is capped at 64 MiB. Commands are never retried, including after timeout
  or output overflow.
  """
  @output_limit 64 * 1024 * 1024

  def run(command, args, opts \\ []) do
    {timeout, opts} = Keyword.pop(opts, :timeout, 30_000)

    task =
      Task.async(fn ->
        try do
          capture(command, args, opts)
        rescue
          error -> {:error, error}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:error, error}} -> raise error
      {:ok, result} -> result
      {:exit, reason} -> exit(reason)
      nil -> {"", :timeout}
    end
  end

  defp capture(command, args, opts) do
    options =
      MuonTrap.Options.validate(:cmd, command, args, Keyword.put(opts, :stderr_to_stdout, true))

    port =
      Port.open(
        {:spawn_executable, MuonTrap.muontrap_path()},
        MuonTrap.Port.port_options(options, ["--capture-output"])
      )

    try do
      collect(port, [], 0)
    after
      if Port.info(port), do: Port.close(port)
    end
  end

  defp collect(port, chunks, bytes) do
    receive do
      {^port, {:data, chunk}} ->
        MuonTrap.Port.report_bytes_handled(port, byte_size(chunk))
        size = bytes + byte_size(chunk)

        if size >= @output_limit,
          do: {"", :output_limit},
          else: collect(port, [chunk | chunks], size)

      {^port, {:exit_status, status}} ->
        {chunks |> Enum.reverse() |> IO.iodata_to_binary(), status}
    end
  end
end
