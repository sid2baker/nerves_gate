defmodule NervesGate.Connectivity.Actions.Reconcile do
  @moduledoc "Recover an interrupted read-only attempt when the input runtime is replaced."
  use Jido.Action, name: "connectivity_reconcile", schema: Zoi.object(%{active: Zoi.boolean()})
  alias Jido.Plugin.Scheduler
  alias NervesGate.Connectivity.{Actions.Completed, Signals}

  @impl true
  def run(%{active: false}, %{agent_state: %{phase: :checking} = state} = context),
    do: Completed.run(%{outage: state.outage, attempt: state.attempts}, context)

  def run(%{active: false}, %{agent_state: %{phase: :waiting} = state}) do
    signal =
      Signals.new("connectivity.recheck", %{outage: state.outage, attempt: state.attempts + 1})

    {:ok, state, [Scheduler.schedule(state.monitoring.retry_ms, signal)]}
  end

  def run(_, %{agent_state: state}), do: {:ok, state}
end
