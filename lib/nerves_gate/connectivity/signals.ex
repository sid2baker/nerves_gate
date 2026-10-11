defmodule NervesGate.Connectivity.Signals do
  @moduledoc """
  Non-durable facts: lost/restored carry an Alarmist revision; recheck completions
  carry the outage revision and attempt. Re-read Alarmist after subscribing.
  Stale timers and duplicate completions cannot extend an outage's retry budget.
  """
  def new(type, data, scope \\ "gateway"),
    do: Jido.Signal.new!(type, data, source: source(scope))

  def source(scope), do: "/nerves_gate/connectivity/#{scope}"

  def condition_schema do
    Zoi.object(%{revision: Zoi.integer()})
  end

  def recheck_schema do
    Zoi.object(%{outage: Zoi.integer(), attempt: Zoi.integer() |> Zoi.min(1) |> Zoi.max(3)})
  end
end
