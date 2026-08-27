defmodule NervesGate.ShoehornHandler do
  @moduledoc """
  Gives essential OTP applications bounded restarts during boot.

  Shoehorn otherwise continues after an application start failure. A transient
  target command/port failure can therefore prevent all dependent applications
  from starting until the hardware watchdog reboots the device. A small retry
  budget keeps transient failures recoverable without masking a deterministic
  bad boot, which is still left to the platform fallback contract.
  """

  @behaviour Shoehorn.Handler

  require Logger

  @impl Shoehorn.Handler
  def init(options) do
    retry_applications = Keyword.get(options, :retry_applications, [:nerves_runtime])
    restart = Keyword.get(options, :restart_application, &Application.ensure_all_started/1)

    {:ok,
     %{
       attempts: %{},
       max_attempts: Keyword.get(options, :retry_attempts, 1),
       restart: restart,
       resume_application: Keyword.get(options, :resume_application),
       retry_applications: MapSet.new(retry_applications)
     }}
  end

  @impl Shoehorn.Handler
  def application_started(_application, state), do: {:continue, state}

  @impl Shoehorn.Handler
  def application_exited(application, reason, state) do
    attempts = Map.get(state.attempts, application, 0)

    if MapSet.member?(state.retry_applications, application) and attempts < state.max_attempts do
      attempt = attempts + 1

      Logger.error(
        "Essential application #{application} exited during boot: #{inspect(reason)}; " <>
          "retrying (#{attempt}/#{state.max_attempts})"
      )

      Process.sleep(attempt * 250)
      state = put_in(state.attempts[application], attempt)
      result = state.restart.(application)
      log_restart(application, result)
      maybe_resume_boot(result, state)
      {:continue, state}
    else
      {:continue, state}
    end
  end

  defp log_restart(application, {:ok, _applications}) do
    Logger.info("Essential application #{application} recovered after a bounded boot retry")
  end

  defp log_restart(application, {:error, reason}) do
    Logger.error("Essential application #{application} boot retry failed: #{inspect(reason)}")
  end

  defp maybe_resume_boot({:ok, _applications}, %{resume_application: application} = state)
       when is_atom(application) and not is_nil(application) do
    case state.restart.(application) do
      {:ok, _applications} ->
        Logger.info("Resumed the release boot sequence at #{application}")

      {:error, reason} ->
        Logger.error(
          "Failed to resume the release boot sequence at #{application}: #{inspect(reason)}"
        )
    end
  end

  defp maybe_resume_boot(_result, _state), do: :ok
end
