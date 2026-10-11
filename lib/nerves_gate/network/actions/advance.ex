defmodule NervesGate.Network.Actions.Advance do
  @moduledoc """
  Normal-path trial policy. Reconcile current admission, not queued snapshots:
  manual trials await confirmation; verified USB trials wait, commit or reject
  conflicts. Runtime effects retain an independent safety veto and watchdog.
  """
  use Jido.Action, name: "network_advance", schema: NervesGate.Network.Signals.schema()
  alias NervesGate.Network.{Effect, Plugin, Policy, Signals}

  @impl true
  def run(fact, context) do
    safety = context.plugin_inputs[Plugin].runtime
    state = context.agent_state
    workflow = safety.workflow

    if current?(fact, context.signal, state, workflow) do
      next = %{
        state
        | incarnation: workflow.incarnation,
          sequence: workflow.sequence,
          trial_id: workflow.trial_id,
          phase: workflow.phase
      }

      advance(next, safety)
    else
      {:ok, state}
    end
  end

  defp current?(fact, signal, state, workflow) do
    source_matches = signal.source == Signals.source(workflow.incarnation)
    trial_matches = fact.trial_id == workflow.trial_id
    fresh = state.incarnation != workflow.incarnation or fact.sequence > state.sequence
    reconcile = signal.type == "network.workflow.reconcile"
    source_matches and trial_matches and (fresh or reconcile)
  end

  defp advance(state, %{workflow: %{phase: :pending}, trial: %{auto_save: false}}),
    do: {:ok, %{state | phase: :awaiting_confirmation}}

  defp advance(state, %{workflow: %{phase: :pending}, trial: trial} = safety) do
    cond do
      safety.ready ->
        effect(state, :confirming, :auto_confirm)

      Policy.conflicts(safety.observed, trial.network) != [] ->
        effect(state, :rolling_back, :auto_cancel)

      safety.workflow.proposal_reply_pending ->
        effect(state, :awaiting_readiness, :await)

      true ->
        {:ok, %{state | phase: :awaiting_readiness}}
    end
  end

  defp advance(state, %{trial: nil}), do: {:ok, %{state | trial_id: nil}}
  defp advance(state, _), do: {:ok, state}

  defp effect(state, phase, operation),
    do: {:ok, %{state | phase: phase}, [%Effect{operation: operation, id: state.trial_id}]}
end
