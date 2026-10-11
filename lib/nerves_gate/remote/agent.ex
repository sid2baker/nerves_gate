defmodule NervesGate.Remote.Agent do
  @moduledoc """
  Coordinates enrollment and daemon commands through validated Jido turns.
  State is ephemeral workflow metadata, never Tailscale preferences or identity.
  The supervised runtime rechecks admission, owns asynchronous work and observes
  the daemon after interruption. Restart never retries a mutation.
  """
  use Jido.Agent, name: "remote"
  alias NervesGate.Remote.{Actions, Plugin}

  agent do
    schema(
      Zoi.object(%{
        phase: Zoi.atom() |> Zoi.default(:idle),
        operation_id: Zoi.any() |> Zoi.default(nil),
        outcome: Zoi.any() |> Zoi.default(nil),
        sequence: Zoi.integer() |> Zoi.default(0)
      })
    )

    plugin(Plugin)
  end

  routes do
    route("remote.connect", Actions.Connect)
    route("remote.configure", Actions.Configure)
    route("remote.disconnect", Actions.Disconnect)
    route("remote.login_url", Actions.LoginURL)
    route("remote.connection.requested", Actions.Observe)
    route("remote.operation.started", Actions.Observe)
    route("remote.operation.completed", Actions.Observe)
    route("remote.operation.failed", Actions.Observe)
    route("remote.enrollment.failed", Actions.Observe)
    route("remote.connection.established", Actions.Observe)
    route("remote.connection.lost", Actions.Observe)
    route("remote.daemon.available", Actions.Observe)
    route("remote.daemon.unavailable", Actions.Observe)
  end
end
