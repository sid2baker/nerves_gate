defmodule NervesGate.Connectivity.Actions.Completed do
  @moduledoc "Bound retries to three per outage; only Alarmist can declare restoration."
  use Jido.Action,
    name: "connectivity_recheck_completed",
    schema: NervesGate.Connectivity.Signals.recheck_schema()

  alias Jido.Plugin.Scheduler
  alias NervesGate.Connectivity.Signals

  @impl true
  def run(%{outage: outage, attempt: attempt}, %{agent_state: state}) do
    if state.outage == outage and state.phase == :checking and attempt == state.attempts do
      advance(state)
    else
      {:ok, state}
    end
  end

  defp advance(%{attempts: 3} = state), do: {:ok, %{state | phase: :exhausted}}

  defp advance(state) do
    signal =
      Signals.new("connectivity.recheck", %{outage: state.outage, attempt: state.attempts + 1})

    {:ok, %{state | phase: :waiting}, [Scheduler.schedule(state.monitoring.retry_ms, signal)]}
  end
end
