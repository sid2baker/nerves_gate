defmodule NervesGate.Firmware.Command do
  @moduledoc """
  Contains an external command runner and converts abnormal port exits to data.

  A port is linked to the process that opens it. Resource pressure or a failed
  `erl_child_setup` can therefore kill that process before `MuonTrap.cmd/3`
  returns. The coordinator traps only its command child's exit while also
  monitoring the caller, so cancellation still tears down the whole command
  epoch and no OS process can outlive its firmware effect owner.
  """

  @type runner :: (String.t(), [String.t()], keyword() -> {term(), term()})

  @spec run(runner(), String.t(), [String.t()], keyword()) ::
          {:ok, {term(), term()}} | {:error, :command_crashed | :command_timeout}
  def run(runner, executable, arguments, options)
      when is_function(runner, 3) and is_binary(executable) and is_list(arguments) and
             is_list(options) do
    caller = self()
    timeout = command_timeout(options)

    {coordinator, monitor} =
      spawn_monitor(fn -> coordinate(caller, runner, executable, arguments, options, timeout) end)

    receive do
      {:command_finished, ^coordinator, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^coordinator, _reason} ->
        {:error, :command_crashed}
    after
      timeout + 1_000 ->
        Process.exit(coordinator, :kill)
        receive do: ({:DOWN, ^monitor, :process, ^coordinator, _reason} -> :ok)
        {:error, :command_timeout}
    end
  end

  defp coordinate(caller, runner, executable, arguments, options, timeout) do
    Process.flag(:trap_exit, true)
    caller_monitor = Process.monitor(caller)
    coordinator = self()

    command =
      spawn_link(fn ->
        result = execute(runner, executable, arguments, options)
        send(coordinator, {:runner_finished, self(), result})
      end)

    receive do
      {:runner_finished, ^command, result} ->
        send(caller, {:command_finished, self(), result})

      {:EXIT, ^command, _reason} ->
        receive do
          {:runner_finished, ^command, result} ->
            send(caller, {:command_finished, self(), result})
        after
          100 -> send(caller, {:command_finished, self(), {:error, :command_crashed}})
        end

      {:DOWN, ^caller_monitor, :process, ^caller, _reason} ->
        Process.exit(command, :kill)
    after
      timeout ->
        Process.exit(command, :kill)
        send(caller, {:command_finished, self(), {:error, :command_timeout}})
    end
  end

  defp execute(runner, executable, arguments, options) do
    {:ok, runner.(executable, arguments, options)}
  catch
    _kind, _reason -> {:error, :command_crashed}
  end

  defp command_timeout(options) do
    case Keyword.get(options, :timeout, 30_000) do
      timeout when is_integer(timeout) and timeout > 0 -> timeout
      _other -> 30_000
    end
  end
end
