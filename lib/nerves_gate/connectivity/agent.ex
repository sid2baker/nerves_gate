defmodule NervesGate.Connectivity.Agent do
  @moduledoc """
  Conservative recovery coordinator. Consumes Alarmist transitions and performs
  at most three bounded, read-only rechecks per outage per agent lifetime. No
  NIC, DHCP, VPN or enrollment mutation is in this agent's directive vocabulary.
  Native Plugin and Scheduler runtimes die with the agent. On restart the input
  runtime subscribes before reading the current condition, not a replay log.
  """
  use Jido.Agent, name: "connectivity_agent"
  alias NervesGate.Connectivity.{Actions, Plugin}

  agent do
    schema(
      Zoi.object(%{
        revision: Zoi.integer() |> Zoi.nullable() |> Zoi.default(nil),
        outage: Zoi.integer() |> Zoi.nullable() |> Zoi.default(nil),
        phase: Zoi.enum([:idle, :waiting, :checking, :exhausted]) |> Zoi.default(:idle),
        attempts: Zoi.integer() |> Zoi.min(0) |> Zoi.max(3) |> Zoi.default(0)
      })
    )

    plugin(Plugin)
    plugin(Jido.Plugin.Scheduler)
  end

  routes do
    route("connectivity.lost", Actions.Condition)
    route("connectivity.restored", Actions.Condition)
    route("connectivity.recheck", Actions.Recheck)
    route("connectivity.recheck.completed", Actions.Completed)
    route("connectivity.reconcile", Actions.Reconcile)
  end
end
