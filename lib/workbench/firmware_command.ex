defmodule Workbench.FirmwareCommand do
  @moduledoc """
  Bounded workstation firmware commands, contained by MuonTrap.

  MuonTrap 1.x's output acknowledgements can hit EPIPE after a short command
  exits and kill the caller. Use its OS containment wrapper with a finite output
  window and System.cmd's reader instead: no writes to the command's stdin.
  A linked task bounds execution and closes the wrapper's port on cancellation.
  Commands are never retried, including after timeout or output overflow.
  """

  @output_limit 64 * 1024 * 1024

  def run(command, args, opts \\ []) do
    {timeout, opts} = Keyword.pop(opts, :timeout, 30_000)

    task =
      Task.async(fn ->
        try do
          System.cmd(
            MuonTrap.muontrap_path(),
            [
              "--capture-output",
              "--capture-stderr",
              "--stdio-window",
              "#{@output_limit}",
              "--",
              command | args
            ],
            opts
          )
        rescue
          error -> {:error, error}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:error, error}} -> raise error
      {:ok, {output, _}} when byte_size(output) >= @output_limit -> {"", :output_limit}
      {:ok, result} -> result
      {:exit, reason} -> exit(reason)
      nil -> {"", :timeout}
    end
  end
end
