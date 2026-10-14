defmodule NervesGate.Scenarios.CableCycles do
  @moduledoc false
  import NervesGate.ScenarioHelpers

  def name, do: "three consecutive cable failures recover"

  def run(vm) do
    for _ <- 1..3, do: cable_cycle(vm)
  end
end
