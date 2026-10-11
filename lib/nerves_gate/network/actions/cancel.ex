defmodule NervesGate.Network.Actions.Cancel do
  @moduledoc "Request restoration of the current trial's previous configuration."
  use Jido.Action, name: "network_cancel", schema: Zoi.object(%{id: Zoi.string()})
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
        {:ok, %{state | phase: :rolling_back, trial_id: id, outcome: :pending},
         [%Effect{operation: :cancel, id: id}]}

      error ->
        {:ok, %{state | outcome: error}}
    end
  end
end
