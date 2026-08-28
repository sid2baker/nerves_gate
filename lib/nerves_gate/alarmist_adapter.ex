defmodule NervesGate.AlarmistAdapter do
  @moduledoc """
  Small runtime boundary for truthful Alarmist signals and bounded remedies.

  Subsystem alarm policies depend on this adapter, while `NervesGate.Alarms`
  independently aggregates their declarations and public projection.
  """

  require Logger

  @spec set(Alarmist.alarm_id(), String.t()) :: :ok
  def set(id, description) when is_binary(description) do
    :alarm_handler.set_alarm({id, description})
  end

  @spec clear(Alarmist.alarm_id()) :: :ok
  def clear(id), do: :alarm_handler.clear_alarm(id)

  @spec report(Alarmist.alarm_id(), boolean(), String.t()) :: :ok
  def report(id, true, description), do: set(id, description)
  def report(id, false, _description), do: clear(id)

  @spec report_sync(Alarmist.alarm_id(), boolean(), String.t()) :: :ok
  def report_sync(id, active, description) do
    expected = if active, do: :set, else: :clear
    :ok = report(id, active, description)

    # A newer ordered projection may supersede this signal while Alarmist is
    # processing it. That is convergence rather than an invariant failure.
    case await_state(id, expected) do
      :ok -> :ok
      {:error, :alarm_state_timeout} -> :ok
    end
  end

  @spec await_state(Alarmist.alarm_id(), :set | :clear, non_neg_integer()) ::
          :ok | {:error, :alarm_state_timeout}
  def await_state(id, expected, attempts \\ 100)

  def await_state(id, expected, attempts) do
    if Alarmist.alarm_state(id) == expected do
      :ok
    else
      await_state_retry(id, expected, attempts)
    end
  end

  @spec heal(module(), (-> term())) :: term()
  def heal(alarm, function) when is_atom(alarm) and is_function(function, 0) do
    started = System.monotonic_time(:millisecond)
    result = function.()
    duration = System.monotonic_time(:millisecond) - started
    public_id = alarm.public_id()
    outcome = heal_outcome(result)

    Logger.info("alarm heal: #{public_id} #{outcome}",
      heal: true,
      alarm_id: public_id,
      heal_result: outcome,
      heal_duration_ms: duration
    )

    result
  end

  defp await_state_retry(_id, _expected, 0), do: {:error, :alarm_state_timeout}

  defp await_state_retry(id, expected, attempts) do
    Process.sleep(1)
    await_state(id, expected, attempts - 1)
  end

  defp heal_outcome(:ok), do: :ok
  defp heal_outcome({:ok, _value}), do: :ok
  defp heal_outcome({:error, reason}) when is_atom(reason), do: reason
  defp heal_outcome({:error, _reason}), do: :failed
  defp heal_outcome(_result), do: :invalid_result
end
