defmodule NervesGate.Connectivity.Actions.Recheck do
  @moduledoc "Admit exactly one read-only attempt for the current outage."
  use Jido.Action,
    name: "connectivity_recheck",
    schema: NervesGate.Connectivity.Signals.recheck_schema()

  alias NervesGate.Connectivity.Effect

  @impl true
  def run(%{outage: outage, attempt: attempt}, %{agent_state: state}) do
    if state.outage == outage and state.phase == :waiting and attempt == state.attempts + 1 do
      {:ok, %{state | phase: :checking, attempts: attempt},
       [%Effect{operation: :recheck, outage: outage, attempt: attempt}]}
    else
      {:ok, state}
    end
  end
end
