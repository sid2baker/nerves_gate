defmodule NervesGate.Network.Agent do
  @moduledoc """
  Long-lived network trial coordinator. Commands validate and admit transitions;
  Advance chooses manual confirmation, readiness waiting, USB auto-save or conflict
  rejection. Typed directives request effects, never bypass the runtime's veto.

  Agent memory contains only workflow metadata. Every live command is admitted
  against the runtime and rechecked at the effect boundary. Restarting this
  agent cannot extend a deadline or resurrect a trial.
  """
  use Jido.Agent, name: "network"
  alias NervesGate.Network.{Actions, Plugin}

  agent do
    schema(
      Zoi.object(%{
        phase: Zoi.atom() |> Zoi.default(:idle),
        trial_id: Zoi.any() |> Zoi.default(nil),
        outcome: Zoi.any() |> Zoi.default(nil),
        sequence: Zoi.integer() |> Zoi.default(0),
        incarnation: Zoi.string() |> Zoi.nullable() |> Zoi.default(nil)
      })
    )

    plugin(Plugin)
  end

  routes do
    route("network.validate", Actions.Validate)
    route("network.propose", Actions.Propose)
    route("network.confirm", Actions.Confirm)
    route("network.cancel", Actions.Cancel)
    route("network.configuration.proposed", Actions.Advance)
    route("network.configuration.applied", Actions.Advance)
    route("network.configuration.failed", Actions.Advance)
    route("network.trial.confirmed", Actions.Advance)
    route("network.trial.expired", Actions.Advance)
    route("network.trial.rolled_back", Actions.Advance)
    route("network.runtime.reconciled", Actions.Advance)
    route("network.workflow.reconcile", Actions.Advance)
  end
end
