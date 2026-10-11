defmodule NervesGate.Network.Actions.Confirm do
  @moduledoc "Request the durable commit decision for the current trial."
  use Jido.Action, name: "network_confirm", schema: Zoi.object(%{id: Zoi.string()})
  alias NervesGate.Network.Effect

  @impl true
  def run(%{id: id}, context) do
    state = context.agent_state

    case NervesGate.Network.Policy.admit_trial(
           context.plugin_inputs[NervesGate.Network.Plugin].runtime,
           id,
           Map.get(context, :expected_revision)
         ) do
      :ok ->
        {:ok, %{state | phase: :confirming, trial_id: id, outcome: :pending},
         [%Effect{operation: :confirm, id: id}]}

      error ->
        {:ok, %{state | outcome: error}}
    end
  end
end
