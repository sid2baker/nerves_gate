defmodule NervesGate.Device.Workflow do
  @moduledoc """
  Pure device decision graph. Both clients' action catalogue and command admission
  use the same network policy. Effects are data, never hardware calls in Runic.

  Each evaluation starts from the pristine graph: no accumulated observation or
  command history, no replayed effects, and no growing fact store on the device.
  """
  require Runic
  alias NervesGate.Device.{NetworkPolicy, Projection}
  alias Runic.Workflow

  def new do
    Runic.workflow(
      name: :device,
      steps: [
        {Runic.step(&NetworkPolicy.prepare/1, name: :network_actions),
         [
           Runic.step(&Projection.build/1, name: :projection),
           Runic.rule(
             fn context when not is_nil(context.command) ->
               NetworkPolicy.decide(context)
             end,
             name: :decision
           )
         ]}
      ]
    )
  end

  def evaluate(workflow, status, command \\ nil) do
    workflow
    |> Workflow.react_until_satisfied(%{status: status, command: command})
    |> Workflow.results([:projection, :decision])
  end
end
