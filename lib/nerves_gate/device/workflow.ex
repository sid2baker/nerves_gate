defmodule NervesGate.Device.Workflow do
  @moduledoc """
  Pure device decision graph. Clients share action policy; effects are data, never
  hardware calls in Runic. Each evaluation uses a pristine graph, with no command
  history, replayed effects or growing fact store on the device.
  """
  require Runic
  alias NervesGate.Device.{NetworkPolicy, RemotePolicy, Projection}
  alias Runic.Workflow

  def new do
    Runic.workflow(
      name: :device,
      steps: [
        {Runic.step(&NetworkPolicy.prepare/1, name: :network_actions),
         [
           {Runic.step(&RemotePolicy.prepare/1, name: :remote_actions),
            [
              Runic.step(&Projection.build/1, name: :projection),
              Runic.rule(
                fn context when not is_nil(context.command) -> RemotePolicy.decide(context) end,
                name: :decision
              )
            ]}
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
