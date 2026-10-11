defmodule NervesGate.Remote.Actions.Observe do
  @moduledoc "Apply ordered operation facts without retaining daemon preferences or secret URLs."
  use Jido.Action,
    name: "remote_observe",
    schema:
      Zoi.object(%{
        operation_id: Zoi.any(),
        phase: Zoi.enum([:idle, :running]),
        sequence: Zoi.integer()
      })

  @impl true
  def run(fact, %{agent_state: state}) do
    stale = fact.sequence <= state.sequence
    unrelated = state.operation_id != nil and fact.operation_id != state.operation_id

    if stale or unrelated do
      {:ok, state}
    else
      id = if fact.phase == :running, do: fact.operation_id
      {:ok, %{state | phase: fact.phase, operation_id: id, sequence: fact.sequence}}
    end
  end
end
