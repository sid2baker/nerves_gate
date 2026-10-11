defmodule NervesGate.Connectivity.Actions.Condition do
  @moduledoc "Start a bounded recheck cycle on a new Alarmist outage; clear on restoration."
  use Jido.Action,
    name: "connectivity_condition",
    schema: NervesGate.Connectivity.Signals.condition_schema()

  alias Jido.Plugin.Scheduler
  alias NervesGate.Connectivity.{Effect, Signals}

  @impl true
  def run(%{revision: revision}, context) do
    state = context.agent_state

    if state.revision != nil and revision <= state.revision do
      {:ok, state}
    else
      transition(context.signal.type, revision, state)
    end
  end

  defp transition("connectivity.lost", revision, state) do
    next = %{state | revision: revision, outage: revision, phase: :waiting, attempts: 0}
    signal = Signals.new("connectivity.recheck", %{outage: revision, attempt: 1})
    {:ok, next, [%Effect{operation: :cancel}, Scheduler.schedule(0, signal)]}
  end

  defp transition("connectivity.restored", revision, state) do
    {:ok, %{state | revision: revision, outage: nil, phase: :idle, attempts: 0},
     [%Effect{operation: :cancel}]}
  end
end
