defmodule NervesGate.Device.Workflow do
  @moduledoc """
  Pure device decision graph: prepare actions, then produce a projection and
  (for commands) a decision. Effects are data, never hardware calls in Runic.
  Each evaluation uses a pristine graph, with no accumulated command history.
  """
  require Runic
  alias NervesGate.Device.{Actions, Projection}
  alias Runic.Workflow

  def new do
    Runic.workflow(
      name: :device,
      steps: [
        {Runic.step(&Actions.prepare/1, name: :actions),
         [
           Runic.step(&Projection.build/1, name: :projection),
           Runic.rule(fn context when not is_nil(context.command) -> Actions.decide(context) end,
             name: :decision
           )
         ]}
      ]
    )
  end

  def evaluate(workflow, status, command \\ nil, remote \\ nil) do
    workflow
    |> Workflow.react_until_satisfied(%{status: status, command: command, remote: remote})
    |> Workflow.results([:projection, :decision])
  end
end
