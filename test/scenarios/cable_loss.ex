defmodule NervesGate.Scenarios.CableLoss do
  @moduledoc false
  import NervesGate.ScenarioHelpers

  def name, do: "Ethernet cable loss and recovery"

  def run(vm) do
    cable_cycle(vm)
  end
end
