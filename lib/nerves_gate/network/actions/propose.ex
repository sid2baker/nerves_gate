defmodule NervesGate.Network.Actions.Propose do
  @moduledoc "Admit a validated configuration trial and request a journaled apply."
  use Jido.Action,
    name: "network_propose",
    schema: Zoi.object(%{network: Zoi.any(), id: Zoi.string()})

  alias NervesGate.Config
  alias NervesGate.Network.{Effect, Plugin, Policy}

  @impl true
  def run(%{network: network, id: id}, context) do
    state = context.agent_state
    safety = context.plugin_inputs[Plugin].runtime

    with :ok <- NervesGate.Command.check_revision(Map.get(context, :expected_revision), safety),
         :ok <- Policy.available(safety),
         {:ok, network} <- Config.validate_network(network) do
      {:ok, %{state | phase: :applying, trial_id: id, outcome: :pending},
       [%Effect{operation: :propose, id: id, network: network}]}
    else
      error -> {:ok, %{state | outcome: error}}
    end
  end
end
