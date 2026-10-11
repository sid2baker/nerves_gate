defmodule NervesGate.Network.Actions.Validate do
  @moduledoc "Validate a draft without creating a trial or touching hardware."
  use Jido.Action, name: "network_validate", schema: Zoi.object(%{network: Zoi.any()})
  alias NervesGate.Config

  @impl true
  def run(%{network: network}, %{agent_state: state}) do
    {:ok, %{state | outcome: Config.validate_network(network)}}
  end
end
